package com.dental.simulator.dental_app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var helper: DentalAlignmentHelper? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 😊 미소 ↔ 보철 사진 정밀 매칭 (Dart: lib/ai/smile_match.dart)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bna/dental_align")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "align" -> {
                        val smile = call.argument<ByteArray>("smile")
                        val prosth = call.argument<ByteArray>("prosth")
                        if (smile == null || prosth == null) {
                            result.error("args", "사진이 없습니다", null)
                            return@setMethodCallHandler
                        }
                        scope.launch {
                            try {
                                val out = withContext(Dispatchers.Default) {
                                    val h = helper ?: DentalAlignmentHelper(applicationContext).also { helper = it }
                                    val a = BitmapFactory.decodeByteArray(smile, 0, smile.size)
                                        ?: throw IllegalStateException("1번(미소) 사진을 읽지 못했습니다")
                                    val b = BitmapFactory.decodeByteArray(prosth, 0, prosth.size)
                                        ?: throw IllegalStateException("2번(보철) 사진을 읽지 못했습니다")
                                    val r = h.align(a, b)
                                    val v = FloatArray(9).also { r.sim.matrix.getValues(it) }
                                    fun norm(pts: List<android.graphics.PointF>, w: Int, hh: Int) =
                                        pts.flatMap { listOf((it.x / w).toDouble(), (it.y / hh).toDouble()) }
                                    mapOf(
                                        "alignedTeeth" to png(r.alignedTeeth),
                                        "mask" to png(r.innerLipMask),
                                        "crop" to png(r.teethCrop),
                                        "cropRect" to listOf(
                                            r.cropRect.left.toDouble() / b.width, r.cropRect.top.toDouble() / b.height,
                                            r.cropRect.right.toDouble() / b.width, r.cropRect.bottom.toDouble() / b.height,
                                        ),
                                        "matrix" to v.map { it.toDouble() },
                                        "scale" to r.sim.scale.toDouble(),
                                        "degrees" to r.sim.degrees.toDouble(),
                                        "residual" to (r.sim.residualPx / a.width).toDouble(), // 사진 너비 대비
                                        "mouthDegrees" to r.mouthDegrees.toDouble(),
                                        "eyes" to r.eyes,
                                        "anchorsSmile" to norm(r.anchorsSmile, a.width, a.height),
                                        "anchorsProsth" to norm(r.anchorsProsth, b.width, b.height),
                                        "width" to a.width,
                                        "height" to a.height,
                                    )
                                }
                                result.success(out)
                            } catch (e: Throwable) {
                                result.error("align", e.message ?: e.toString(), null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun png(b: Bitmap): ByteArray =
        ByteArrayOutputStream().use { b.compress(Bitmap.CompressFormat.PNG, 100, it); it.toByteArray() }

    override fun onDestroy() {
        scope.cancel()
        helper?.close()
        helper = null
        super.onDestroy()
    }
}
