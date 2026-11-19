import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../simulator/sim_models.dart' show MaskStroke;
import 'ai_service.dart';
import 'pipeline.dart' show PipelineError, PipelineSettings;
import 'tooth_select.dart';

// =============================================================================
// 😊 미소 미리보기: 변환된 After(개구기 사진)의 치아를 환자의 자연스러운 미소 사진에 입힘
//   ① 입술 사이 영역 (얼굴 인식 자동 + 🪄 탭 · 붓 보정)
//   ② 입 주변만 잘라 나노바나나에 [미소 사진 + After] 2장 → "치아만 After 처럼"
//   ③ 결과를 원래 자리에 붙이고, 입술 사이 영역 바깥(입술·얼굴·배경)은 원본 픽셀로 100% 되돌림
// =============================================================================

const kSmilePrompt =
    'Image 1 is a close-up of a patient\'s natural smile (lips, no cheek retractor). '
    'Image 2 is an intraoral clinical photo of the SAME patient taken with a cheek retractor, '
    'showing the PLANNED dental treatment result. '
    'Edit Image 1: replace ONLY the visible teeth between the lips with the teeth from Image 2 '
    '(same tooth shapes, length and width proportions, alignment, midline, gaps or no gaps, color, shade and translucency), '
    'adapted naturally to Image 1\'s viewing angle, perspective, lighting, lip position and how much of the teeth the lips show. '
    'Keep the lips, lip shape, skin, face, gums outside the teeth, framing and image size exactly the same. '
    'Do not open the mouth wider and do not change the smile. Photorealistic clinical photo, no text.';

/// 다각형(0~1) 안을 흰색으로 채운 마스크
img.Image polygonMask(int w, int h, List<Offset> poly) {
  final m = img.Image(width: w, height: h, numChannels: 1);
  if (poly.length < 3) return m;
  img.fillPolygon(
    m,
    vertices: [for (final p in poly) img.Point(p.dx * w, p.dy * h)],
    color: img.ColorRgb8(255, 255, 255),
  );
  return m;
}

/// 마스크를 [r] 픽셀 넓힘
img.Image dilate(img.Image m, int r) {
  if (r <= 0) return m;
  final out = m.clone();
  for (var y = 0; y < m.height; y++) {
    for (var x = 0; x < m.width; x++) {
      if (m.getPixel(x, y).r <= 127) continue;
      // 가장자리 점만 넓힘
      final edge =
          x == 0 ||
          y == 0 ||
          x == m.width - 1 ||
          y == m.height - 1 ||
          m.getPixel(x - 1, y).r <= 127 ||
          m.getPixel(x + 1, y).r <= 127 ||
          m.getPixel(x, y - 1).r <= 127 ||
          m.getPixel(x, y + 1).r <= 127;
      if (!edge) continue;
      for (var dy = -r; dy <= r; dy++) {
        for (var dx = -r; dx <= r; dx++) {
          if (dx * dx + dy * dy > r * r) continue;
          final xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= m.width || yy >= m.height) continue;
          out.setPixelR(xx, yy, 255);
        }
      }
    }
  }
  return out;
}

/// 마스크에서 흰 부분 바운딩 박스 (0~1). 없으면 null
Rect? maskBounds(img.Image m) {
  var x0 = m.width, y0 = m.height, x1 = -1, y1 = -1;
  for (var y = 0; y < m.height; y++) {
    for (var x = 0; x < m.width; x++) {
      if (m.getPixel(x, y).r > 127) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (x1 < 0) return null;
  return Rect.fromLTRB(
    x0 / m.width,
    y0 / m.height,
    (x1 + 1) / m.width,
    (y1 + 1) / m.height,
  );
}

/// 입 주변 잘라낼 영역 (0~1): 치아 영역의 2.4배, 사진 밖은 자름
Rect mouthCrop(Rect teeth) {
  final c = teeth.center;
  final w = math.max(teeth.width * 2.4, 0.18),
      h = math.max(teeth.height * 3.2, w * 0.6);
  return Rect.fromCenter(
    center: c,
    width: w,
    height: h,
  ).intersect(const Rect.fromLTRB(0, 0, 1, 1));
}

/// 치아 영역 고르기 (자동 입술 영역 + 🪄 탭 + 붓) — 미소 사진용
class ToothMaskSet {
  ToothMaskSet(this.photo);
  final Uint8List photo;
  img.Image? small; // AI·SAM 에 쓰는 크기
  Uint8List? jpeg;
  img.Image? auto; // 얼굴 인식으로 찾은 입술 사이
  List<ToothSel> sels = [];
  List<MaskStroke> edits = [];
  final List<(img.Image?, List<ToothSel>, List<MaskStroke>)> history = [];
  img.Image? union;
  Uint8List? overlay;
  bool busy = false;

  bool get has => auto != null || sels.isNotEmpty || edits.any((e) => !e.erase);

  Future<void> prep() async {
    if (small != null) return;
    final src = await AiService.decodePhoto(photo);
    jpeg = await AiService.photoJpeg(src);
    small = img.decodeJpg(jpeg!);
  }

  void _remember() {
    history.add((auto, [...sels], [...edits]));
    if (history.length > 40) history.removeAt(0);
  }

  Future<void> refresh() async {
    final sm = small;
    if (sm == null || !has) {
      union = null;
      overlay = null;
      return;
    }
    final masks = [?auto, for (final s in sels) s.mask];
    union = await compute((a) => unionMask(a.$1, a.$2, a.$3, a.$4), (
      sm.width,
      sm.height,
      masks,
      edits,
    ));
    overlay = await compute((m) => overlayPng(m), union!);
  }

  /// 입술 사이 다각형으로 자동 영역
  Future<void> setAuto(List<Offset> poly) async {
    await prep();
    _remember();
    final sm = small!;
    auto = await compute((a) => polygonMask(a.$1, a.$2, a.$3), (
      sm.width,
      sm.height,
      poly,
    ));
    await refresh();
  }

  /// 🪄 탭: 이미 고른 치아면 빼기, 아니면 SAM 으로 추가. 오류 문구 또는 null
  Future<String?> tap(Offset p) async {
    for (final s in sels.reversed) {
      if (maskAt(
            s.mask,
            (p.dx * s.mask.width).floor(),
            (p.dy * s.mask.height).floor(),
          ) >
          127) {
        _remember();
        sels = [...sels]..remove(s);
        await refresh();
        return null;
      }
    }
    final key = PipelineSettings.instance.falKey;
    if (key == null) return '자동 선택(SAM)에는 Fal.ai API 키가 필요합니다.';
    busy = true;
    try {
      await prep();
      final sm = small!;
      final raw = await segmentAround(FalSam(key), sm, p);
      final s = await compute((a) => analyzeSel(a.$1, a.$2, a.$3), (
        sm,
        raw,
        p,
      ));
      if (s == null) return '치아가 아닌 곳 같아요. 치아 한가운데를 다시 탭해 주세요.';
      _remember();
      sels = [...sels, s];
      await refresh();
      return null;
    } on PipelineError catch (e) {
      return e.message;
    } finally {
      busy = false;
    }
  }

  Future<void> brush(MaskStroke s) async {
    await prep();
    _remember();
    edits = [...edits, s];
    await refresh();
  }

  Future<void> undo() async {
    if (history.isEmpty) return;
    final (a, s, e) = history.removeLast();
    auto = a;
    sels = s;
    edits = e;
    await refresh();
  }

  Future<void> clear() async {
    if (!has && edits.isEmpty) return;
    _remember();
    auto = null;
    sels = [];
    edits = [];
    await refresh();
  }
}

/// 잘라낸 결과를 원래 미소 사진에 붙이고, [region] 바깥은 원본으로 (경계 부드럽게)
Uint8List pasteSmile((img.Image, Uint8List, Rect, img.Image) a) {
  final (src, aiBytes, crop, region) = a;
  var ai = img.decodeImage(aiBytes)!;
  final cx = (crop.left * src.width).round(),
      cy = (crop.top * src.height).round();
  final cw = (crop.width * src.width).round(),
      ch = (crop.height * src.height).round();
  ai = img.copyResize(
    ai,
    width: cw,
    height: ch,
    interpolation: img.Interpolation.cubic,
  );
  final full = src.clone();
  img.compositeImage(full, ai, dstX: cx, dstY: cy);
  return protectOutside((src, img.encodeJpg(full, quality: 95), region));
}

/// 😊 미소에 입히기 → 결과 JPEG (원래 미소 사진 크기)
Future<Uint8List> makeSmile({
  required Uint8List smile,
  required Uint8List after,
  required img.Image region, // 미소 사진(AI 크기)의 치아 영역
  String? model,
}) async {
  final b = await compute(maskBounds, region);
  if (b == null) throw const PipelineError('미소 사진에서 치아 영역을 먼저 정해 주세요.');
  final src = await AiService.decodePhoto(smile, maxSide: 2400);
  final crop = mouthCrop(b);
  final cropped = img.copyCrop(
    src,
    x: (crop.left * src.width).round(),
    y: (crop.top * src.height).round(),
    width: (crop.width * src.width).round(),
    height: (crop.height * src.height).round(),
  );
  final cropJpeg = await AiService.photoJpeg(cropped);
  final afterJpeg = await AiService.photoJpeg(
    await AiService.decodePhoto(after),
  );
  final s = PipelineSettings.instance;
  Uint8List out;
  try {
    out = await AiService.instance.geminiImage(
      model: model ?? s.nanoProModel,
      prompt: kSmilePrompt,
      jpeg: cropJpeg,
      extra: [
        (
          label: 'Image 2 (planned treatment result, reference for the teeth):',
          jpeg: afterJpeg,
        ),
      ],
    );
  } on AiError {
    if (model != null) rethrow;
    out = await AiService.instance.geminiImage(
      model: s.nanoModel,
      prompt: kSmilePrompt,
      jpeg: cropJpeg,
      extra: [
        (
          label: 'Image 2 (planned treatment result, reference for the teeth):',
          jpeg: afterJpeg,
        ),
      ],
    );
  }
  // 경계가 입술 안쪽 끝까지 자연스럽게 바뀌도록 영역을 살짝(2px) 넓혀서 보호
  final grown = await compute((m) => dilate(m, 2), region);
  return compute(pasteSmile, (src, out, crop, grown));
}
