import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

/// 사진 등록 시 환자 눈 자동 가리기 (휴대폰 안에서만 처리, 사진을 밖으로 보내지 않음)
///
/// 결과: 눈을 가린 JPEG. 얼굴(눈)을 못 찾으면 null.
class EyeMasker {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<Uint8List?> mask(Uint8List bytes) async {
    if (!supported) return null;
    // 1) 사진을 바로 세운 상태(EXIF 회전 반영)로 풀어서 다시 저장 → 얼굴 좌표와 픽셀이 정확히 일치
    final src = await _decodeUpright(bytes);
    final upright = await compute(_encode, src);
    final tmp = File(
      '${Directory.systemTemp.path}/eyemask_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await tmp.writeAsBytes(upright, flush: true);
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        enableContours: true,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.08,
      ),
    );
    try {
      final faces = await detector.processImage(
        InputImage.fromFilePath(tmp.path),
      );
      final bars = <List<(double, double)>>[];
      for (final f in faces) {
        final bar = _barFor(f);
        if (bar != null) bars.add(bar);
      }
      if (bars.isEmpty) return null;
      return await compute(_drawBars, (src, bars));
    } finally {
      await detector.close();
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }

  /// 두 눈을 덮는 기울어진 검은 띠 (꼭짓점 4개)
  static List<(double, double)>? _barFor(Face f) {
    ui.Offset? center(FaceContourType c, FaceLandmarkType l) {
      final pts = f.contours[c]?.points;
      if (pts != null && pts.isNotEmpty) {
        var x = 0.0, y = 0.0;
        for (final p in pts) {
          x += p.x;
          y += p.y;
        }
        return ui.Offset(x / pts.length, y / pts.length);
      }
      final p = f.landmarks[l]?.position;
      return p == null ? null : ui.Offset(p.x.toDouble(), p.y.toDouble());
    }

    final a = center(FaceContourType.leftEye, FaceLandmarkType.leftEye);
    final b = center(FaceContourType.rightEye, FaceLandmarkType.rightEye);
    final box = f.boundingBox;
    late ui.Offset mid;
    late double len, thick, ang;
    if (a != null && b != null && (a - b).distance > 4) {
      final d = (a - b).distance;
      mid = (a + b) / 2;
      ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
      len = d * 2.3;
      thick = d * 0.62;
      // 눈 윤곽 높이가 크면 띠를 더 두껍게
      for (final c in [FaceContourType.leftEye, FaceContourType.rightEye]) {
        final pts = f.contours[c]?.points ?? const [];
        if (pts.isEmpty) continue;
        final ys = pts.map((p) => p.y.toDouble());
        thick = math.max(
          thick,
          (ys.reduce(math.max) - ys.reduce(math.min)) * 2.6,
        );
      }
    } else {
      // 눈 위치를 못 찾으면 얼굴 상자 기준 (눈 높이 ≈ 위에서 38%)
      mid = ui.Offset(box.center.dx, box.top + box.height * 0.38);
      ang = 0;
      len = box.width * 0.95;
      thick = box.height * 0.2;
    }
    final ux = math.cos(ang), uy = math.sin(ang);
    final vx = -uy, vy = ux;
    final hl = len / 2, ht = thick / 2;
    return [
      (mid.dx - ux * hl - vx * ht, mid.dy - uy * hl - vy * ht),
      (mid.dx + ux * hl - vx * ht, mid.dy + uy * hl - vy * ht),
      (mid.dx + ux * hl + vx * ht, mid.dy + uy * hl + vy * ht),
      (mid.dx - ux * hl + vx * ht, mid.dy - uy * hl + vy * ht),
    ];
  }
}

Future<img.Image> _decodeUpright(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final raw = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = frame.image.width, h = frame.image.height;
  frame.image.dispose();
  return img.Image.fromBytes(
    width: w,
    height: h,
    bytes: raw!.buffer,
    numChannels: 4,
  );
}

Uint8List _encode(img.Image src) => img.encodeJpg(src, quality: 92);

@visibleForTesting
Uint8List drawBarsForTest(img.Image src, List<List<(double, double)>> bars) =>
    _drawBars((src, bars));

Uint8List _drawBars((img.Image, List<List<(double, double)>>) a) {
  final (src, bars) = a;
  final out = img.Image.from(src);
  for (final bar in bars) {
    img.fillPolygon(
      out,
      vertices: [for (final (x, y) in bar) img.Point(x, y)],
      color: img.ColorRgb8(8, 10, 14),
    );
  }
  return img.encodeJpg(out, quality: 92);
}
