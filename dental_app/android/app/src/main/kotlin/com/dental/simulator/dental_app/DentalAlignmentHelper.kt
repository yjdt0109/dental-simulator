package com.dental.simulator.dental_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.Rect
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.Closeable
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * 😊 미소 사진(1번) ↔ 개구기 보철 사진(2번) 정밀 매칭 전처리 — 기기 안에서만 처리 (사진을 밖으로 보내지 않음)
 *
 * 1) MediaPipe FaceLandmarker 로 두 사진의 얼굴 특징점(478개)을 찾고
 * 2) 개구기로 변형되는 입술·볼은 빼고 고정 부위(양쪽 눈 중심 + 코끝)로 2번 → 1번 정렬 Matrix(크기·회전·이동)
 * 3) 1번의 입술 안쪽(Inner Lip) 윤곽만 흰색인 흑백 마스크
 * 4) 2번에서 개구기·입술을 빼고 보철 치아 영역만 잘라낸 사진 (치아 밖은 투명)
 */
class DentalAlignmentHelper(private val context: Context) : Closeable {

    private var landmarker: FaceLandmarker? = null

    private fun lm(): FaceLandmarker {
        landmarker?.let { return it }
        val options = FaceLandmarker.FaceLandmarkerOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath(MODEL).build())
            .setRunningMode(RunningMode.IMAGE)
            .setNumFaces(1)
            .setMinFaceDetectionConfidence(0.4f)
            .setMinFacePresenceConfidence(0.4f)
            .build()
        return FaceLandmarker.createFromOptions(context, options).also { landmarker = it }
    }

    /** 얼굴 특징점 (픽셀 좌표). 얼굴을 못 찾으면 null */
    fun detect(bmp: Bitmap): List<PointF>? {
        val result = lm().detect(BitmapImageBuilder(bmp).build())
        val face = result.faceLandmarks().firstOrNull() ?: return null
        return face.map { PointF(it.x() * bmp.width, it.y() * bmp.height) }
    }

    data class Anchors(val points: List<PointF>, val eyes: Boolean)

    /**
     * 정렬 기준점: 양쪽 눈 중심 + 코끝.
     * 눈을 검은 띠로 가린 사진이면 눈 대신 미간(콧대 시작) + 양쪽 콧볼 + 코끝으로 바꿈.
     */
    fun anchors(bmp: Bitmap, p: List<PointF>): Anchors {
        val left = eyeCenter(p, true)
        val right = eyeCenter(p, false)
        val masked = isDark(bmp, left) && isDark(bmp, right)
        return if (!masked) {
            Anchors(listOf(left, right, p[NOSE_TIP]), true)
        } else {
            Anchors(listOf(p[NASION], p[ALAR_L], p[ALAR_R], p[NOSE_TIP]), false)
        }
    }

    private fun eyeCenter(p: List<PointF>, left: Boolean): PointF {
        // 홍채(눈동자) 점이 있으면 그 중심, 없으면 눈꼬리·눈머리 가운데
        if (p.size >= 478) return p[if (left) IRIS_L else IRIS_R]
        val (a, b) = if (left) EYE_L else EYE_R
        return PointF((p[a].x + p[b].x) / 2f, (p[a].y + p[b].y) / 2f)
    }

    private fun isDark(bmp: Bitmap, at: PointF): Boolean {
        var sum = 0.0
        var n = 0
        val r = max(3, bmp.width / 200)
        for (dy in -r..r step 2) for (dx in -r..r step 2) {
            val x = (at.x + dx).toInt().coerceIn(0, bmp.width - 1)
            val y = (at.y + dy).toInt().coerceIn(0, bmp.height - 1)
            val c = bmp.getPixel(x, y)
            sum += 0.299 * Color.red(c) + 0.587 * Color.green(c) + 0.114 * Color.blue(c)
            n++
        }
        return sum / n < 22 // 눈 가리기 띠 (거의 검정)
    }

    data class Similarity(val matrix: Matrix, val scale: Float, val degrees: Float, val residualPx: Float)

    /** [src] 점들을 [dst] 점들에 최소제곱으로 맞추는 닮음 변환 (크기·회전·이동만, 찌그러뜨리지 않음) */
    fun similarity(src: List<PointF>, dst: List<PointF>): Similarity {
        val n = min(src.size, dst.size)
        var sx = 0f; var sy = 0f; var dx = 0f; var dy = 0f
        for (i in 0 until n) { sx += src[i].x; sy += src[i].y; dx += dst[i].x; dy += dst[i].y }
        sx /= n; sy /= n; dx /= n; dy /= n
        var a = 0.0; var b = 0.0; var norm = 0.0
        for (i in 0 until n) {
            val px = (src[i].x - sx).toDouble(); val py = (src[i].y - sy).toDouble()
            val qx = (dst[i].x - dx).toDouble(); val qy = (dst[i].y - dy).toDouble()
            a += px * qx + py * qy
            b += px * qy - py * qx
            norm += px * px + py * py
        }
        val ca = if (norm > 0) a / norm else 1.0 // s·cosθ
        val sb = if (norm > 0) b / norm else 0.0 // s·sinθ
        val scale = sqrt(ca * ca + sb * sb).toFloat()
        val deg = Math.toDegrees(atan2(sb, ca)).toFloat()
        val m = Matrix()
        m.setValues(
            floatArrayOf(
                ca.toFloat(), (-sb).toFloat(), (dx - (ca * sx - sb * sy)).toFloat(),
                sb.toFloat(), ca.toFloat(), (dy - (sb * sx + ca * sy)).toFloat(),
                0f, 0f, 1f,
            ),
        )
        // 맞춘 뒤 남는 오차 (평균 픽셀)
        val pts = FloatArray(n * 2)
        for (i in 0 until n) { pts[2 * i] = src[i].x; pts[2 * i + 1] = src[i].y }
        m.mapPoints(pts)
        var err = 0.0
        for (i in 0 until n) {
            val ex = pts[2 * i] - dst[i].x; val ey = pts[2 * i + 1] - dst[i].y
            err += sqrt((ex * ex + ey * ey).toDouble())
        }
        return Similarity(m, scale, deg, (err / n).toFloat())
    }

    private fun lipPath(p: List<PointF>): Path {
        val path = Path()
        INNER_LIP.forEachIndexed { i, idx ->
            if (i == 0) path.moveTo(p[idx].x, p[idx].y) else path.lineTo(p[idx].x, p[idx].y)
        }
        path.close()
        return path
    }

    /** 1번 사진: 입술 안쪽만 흰색인 흑백 마스크 (사진과 같은 크기) */
    fun innerLipMask(w: Int, h: Int, p: List<PointF>): Bitmap {
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        c.drawColor(Color.BLACK)
        c.drawPath(lipPath(p), Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; style = Paint.Style.FILL })
        return out
    }

    /**
     * 2번 사진: 입술 안쪽 다각형(개구기·입술은 밖) 안에서 치아처럼 밝고 채도가 낮은 픽셀만 남기고 자름.
     * 결과: (치아만 남은 투명 배경 사진, 원래 사진에서 잘라낸 위치)
     */
    fun teethCrop(bmp: Bitmap, p: List<PointF>): Pair<Bitmap, Rect> {
        val lip = Bitmap.createBitmap(bmp.width, bmp.height, Bitmap.Config.ALPHA_8)
        Canvas(lip).drawPath(lipPath(p), Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; style = Paint.Style.FILL })
        var x0 = bmp.width; var y0 = bmp.height; var x1 = -1; var y1 = -1
        val keep = Bitmap.createBitmap(bmp.width, bmp.height, Bitmap.Config.ARGB_8888)
        val row = IntArray(bmp.width)
        val lipRow = IntArray(bmp.width)
        val out = IntArray(bmp.width)
        for (y in 0 until bmp.height) {
            bmp.getPixels(row, 0, bmp.width, 0, y, bmp.width, 1)
            lip.getPixels(lipRow, 0, bmp.width, 0, y, bmp.width, 1)
            for (x in 0 until bmp.width) {
                out[x] = 0
                if (Color.alpha(lipRow[x]) < 128) continue
                val c = row[x]
                val r = Color.red(c); val g = Color.green(c); val b = Color.blue(c)
                val mx = max(r, max(g, b)); val mn = min(r, min(g, b))
                val lum = 0.299 * r + 0.587 * g + 0.114 * b
                // 치아: 밝고(잇몸·입안보다) 채도가 낮음. 잇몸·입술은 붉어서 빠짐
                val tooth = lum > 95 && (mx - mn) < mx * 0.42 && !(r > g + 38 && r > b + 38)
                if (!tooth) continue
                out[x] = c or (0xFF shl 24)
                if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y
            }
            keep.setPixels(out, 0, bmp.width, 0, y, bmp.width, 1)
        }
        lip.recycle()
        if (x1 < 0) return Pair(keep, Rect(0, 0, 0, 0))
        val rect = Rect(x0, y0, x1 + 1, y1 + 1)
        val crop = Bitmap.createBitmap(keep, rect.left, rect.top, rect.width(), rect.height())
        if (crop != keep) keep.recycle()
        return Pair(crop, rect)
    }

    data class AlignResult(
        val alignedTeeth: Bitmap, // 1번 크기 캔버스에 정렬해 놓은 보철 치아 (치아 밖 투명)
        val innerLipMask: Bitmap, // 1번 입술 안쪽 마스크
        val teethCrop: Bitmap, // 2번에서 잘라낸 보철 치아
        val cropRect: Rect, // 2번 사진에서 잘라낸 위치
        val sim: Similarity,
        val eyes: Boolean, // true: 눈동자+코끝 기준, false: (눈 가림) 코 기준
        val anchorsSmile: List<PointF>,
        val anchorsProsth: List<PointF>,
        val mouthDegrees: Float, // 두 사진의 입꼬리 선 기울기 차이 (정렬 후, 참고용)
    )

    /** 전체 전처리 (무거운 계산은 백그라운드) */
    suspend fun align(smile: Bitmap, prosth: Bitmap): AlignResult = withContext(Dispatchers.Default) {
        val p1 = detect(smile) ?: throw IllegalStateException("1번(미소) 사진에서 얼굴을 찾지 못했습니다")
        val p2 = detect(prosth) ?: throw IllegalStateException("2번(보철) 사진에서 얼굴을 찾지 못했습니다")
        val a1 = anchors(smile, p1)
        val a2 = anchors(prosth, p2)
        // 기준점 종류가 다르면(한쪽만 눈 가림) 둘 다 코 기준으로 맞춤
        val (s1, s2, eyes) = if (a1.eyes == a2.eyes) Triple(a1.points, a2.points, a1.eyes) else
            Triple(
                listOf(p1[NASION], p1[ALAR_L], p1[ALAR_R], p1[NOSE_TIP]),
                listOf(p2[NASION], p2[ALAR_L], p2[ALAR_R], p2[NOSE_TIP]),
                false,
            )
        val sim = similarity(s2, s1)
        val (crop, rect) = teethCrop(prosth, p2)
        if (rect.width() < 4 || rect.height() < 4) {
            throw IllegalStateException("2번(보철) 사진에서 치아를 찾지 못했습니다")
        }
        // 잘라낸 치아를 1번 캔버스로: (잘라낸 위치 이동) → 정렬 Matrix
        val m = Matrix().apply {
            setTranslate(rect.left.toFloat(), rect.top.toFloat())
            postConcat(sim.matrix)
        }
        val aligned = Bitmap.createBitmap(smile.width, smile.height, Bitmap.Config.ARGB_8888)
        Canvas(aligned).drawBitmap(crop, m, Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
        val mask = innerLipMask(smile.width, smile.height, p1)
        // 참고: 정렬 후 입꼬리 선 기울기 차이 (얼굴은 맞는데 입이 기울어진 정도)
        val m2 = floatArrayOf(p2[MOUTH_L].x, p2[MOUTH_L].y, p2[MOUTH_R].x, p2[MOUTH_R].y)
        sim.matrix.mapPoints(m2)
        val d1 = Math.toDegrees(atan2((p1[MOUTH_R].y - p1[MOUTH_L].y).toDouble(), (p1[MOUTH_R].x - p1[MOUTH_L].x).toDouble()))
        val d2 = Math.toDegrees(atan2((m2[3] - m2[1]).toDouble(), (m2[2] - m2[0]).toDouble()))
        AlignResult(aligned, mask, crop, rect, sim, eyes, s1, s2, abs((d1 - d2).toFloat()))
    }

    override fun close() {
        landmarker?.close()
        landmarker = null
    }

    companion object {
        const val MODEL = "face_landmarker.task"
        // MediaPipe Face Mesh 번호
        const val NOSE_TIP = 1
        const val NASION = 168 // 미간 아래 콧대 시작
        const val ALAR_L = 98
        const val ALAR_R = 327
        const val IRIS_L = 468 // 사진 왼쪽 눈(환자 오른쪽) 눈동자 중심
        const val IRIS_R = 473
        val EYE_L = Pair(33, 133)
        val EYE_R = Pair(362, 263)
        const val MOUTH_L = 61
        const val MOUTH_R = 291

        /** 입술 안쪽 윤곽 (윗입술 아래선 → 아랫입술 윗선) */
        val INNER_LIP = intArrayOf(
            78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308,
            324, 318, 402, 317, 14, 87, 178, 88, 95,
        )
    }
}
