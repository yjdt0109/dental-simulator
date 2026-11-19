import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

/// 😊 미소 사진에서 입술 사이(치아가 보이는 곳) 윤곽 찾기 — 휴대폰 안에서만 처리
/// 결과: 사진 기준 0~1 좌표의 다각형 (윗입술 아래선 → 아랫입술 윗선). 못 찾으면 null.
class MouthFinder {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<List<ui.Offset>?> lips(Uint8List bytes) async {
    if (!supported) return null;
    try {
      return await _lips(bytes);
    } catch (e) {
      debugPrint('mouth finder: $e');
      return null; // 못 찾으면 🪄 탭으로
    }
  }

  static Future<List<ui.Offset>?> _lips(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final w = frame.image.width, h = frame.image.height;
    final raw = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    final src = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: raw!.buffer,
      numChannels: 4,
    );
    final upright = await compute((i) => img.encodeJpg(i, quality: 92), src);
    final tmp = File(
      '${Directory.systemTemp.path}/mouth_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await tmp.writeAsBytes(upright, flush: true);
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: true,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.08,
      ),
    );
    try {
      final faces = await detector.processImage(
        InputImage.fromFilePath(tmp.path),
      );
      if (faces.isEmpty) return null;
      // 가장 큰 얼굴
      faces.sort(
        (a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(
          a.boundingBox.width * a.boundingBox.height,
        ),
      );
      final f = faces.first;
      final up = f.contours[FaceContourType.upperLipBottom]?.points ?? const [];
      final lo = f.contours[FaceContourType.lowerLipTop]?.points ?? const [];
      if (up.length < 3 || lo.length < 3) return null;
      // 위 선은 왼→오, 아래 선은 오→왼 으로 이어 닫힌 다각형 (ML Kit 점 순서와 무관하게)
      final u = [...up]..sort((a, b) => a.x.compareTo(b.x));
      final l = [...lo]..sort((a, b) => b.x.compareTo(a.x));
      return [
        for (final p in u) ui.Offset(p.x / w, p.y / h),
        for (final p in l) ui.Offset(p.x / w, p.y / h),
      ];
    } finally {
      try {
        await detector.close();
      } catch (_) {}
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }
}
