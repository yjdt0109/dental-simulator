import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'ai_service.dart';
import 'pipeline.dart';
import 'smile.dart' show dilate, maskBounds, mouthCrop;
import 'tooth_select.dart' show protectOutside;

// =============================================================================
// 🦷😊 보철 사진 정밀 매칭: 2번(개구기 보철 사진)의 치아를 1번(자연 미소)의 입 안쪽에 이식
//   ① 기기 안(안드로이드 Kotlin · MediaPipe FaceLandmarker): 눈 중심·코끝으로 정렬 Matrix,
//      1번 입술 안쪽 마스크, 2번 보철 치아만 자른 사진 → 1번 캔버스에 정렬
//   ② 정렬 합성 (입술 안쪽에만 보철 치아 붙이기)
//   ③ Fal FLUX Fill: 보철 치아가 덮지 못한 입 안쪽 빈 곳·경계만 자연스럽게 채움 (치아 모양은 그대로)
//   ④ 나노바나나(Vertex Gemini Image): 1번 원본의 입술 그림자·조명 톤에 맞게 최종 리터칭
//   ⑤ 입술 안쪽 바깥(입술·얼굴·배경)은 1번 원본 픽셀로 100% 되돌림
// =============================================================================

/// 기기 안 정렬 결과
class AlignOut {
  const AlignOut({
    required this.alignedTeeth,
    required this.mask,
    required this.crop,
    required this.residual,
    required this.eyes,
    this.degrees = 0,
    this.scale = 1,
    this.mouthDegrees = 0,
    this.anchorsSmile = const [],
    this.anchorsProsth = const [],
  });
  final Uint8List alignedTeeth; // PNG · 1번 크기 · 보철 치아만 (밖은 투명)
  final Uint8List mask; // PNG · 1번 입술 안쪽 = 흰색
  final Uint8List crop; // PNG · 2번에서 잘라낸 보철 치아
  final double residual; // 정렬 후 기준점 평균 오차 (사진 너비 대비)
  final bool eyes; // 눈동자+코끝 기준(true) / 코 기준(false, 눈 가린 사진)
  final double degrees, scale, mouthDegrees;
  final List<Offset> anchorsSmile, anchorsProsth;

  /// 사용자에게 보여 줄 한 줄
  String get summary =>
      '기준: ${eyes ? '양쪽 눈동자 + 코끝' : '콧대·콧볼·코끝 (눈 가린 사진)'} · '
      '크기 ×${scale.toStringAsFixed(2)} · 회전 ${degrees.toStringAsFixed(1)}° · '
      '정렬 오차 ${(residual * 100).toStringAsFixed(1)}%'
      '${mouthDegrees > 3 ? ' · ⚠ 입 기울기 차이 ${mouthDegrees.toStringAsFixed(0)}°' : ''}';
}

/// 안드로이드 기기 안 MediaPipe 정렬 (MainActivity 의 bna/dental_align)
class DentalAligner {
  static const _ch = MethodChannel('bna/dental_align');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<AlignOut> align(
    Uint8List smileJpeg,
    Uint8List prosthJpeg,
  ) async {
    final Map<Object?, Object?>? r;
    try {
      r = await _ch.invokeMapMethod<Object?, Object?>('align', {
        'smile': smileJpeg,
        'prosth': prosthJpeg,
      });
    } on PlatformException catch (e) {
      throw PipelineError(e.message ?? '사진 정렬에 실패했습니다.');
    } on MissingPluginException {
      throw const PipelineError(
        '이 기기에서는 정밀 매칭(얼굴 특징점)을 쓸 수 없습니다. 안드로이드 태블릿에서 해 주세요.',
      );
    }
    if (r == null) throw const PipelineError('사진 정렬 결과가 없습니다.');
    List<Offset> pts(Object? v) {
      final l = [
        for (final x in (v as List? ?? const [])) (x as num).toDouble(),
      ];
      return [for (var i = 0; i + 1 < l.length; i += 2) Offset(l[i], l[i + 1])];
    }

    return AlignOut(
      alignedTeeth: r['alignedTeeth'] as Uint8List,
      mask: r['mask'] as Uint8List,
      crop: r['crop'] as Uint8List,
      residual: (r['residual'] as num).toDouble(),
      eyes: r['eyes'] == true,
      degrees: (r['degrees'] as num?)?.toDouble() ?? 0,
      scale: (r['scale'] as num?)?.toDouble() ?? 1,
      mouthDegrees: (r['mouthDegrees'] as num?)?.toDouble() ?? 0,
      anchorsSmile: pts(r['anchorsSmile']),
      anchorsProsth: pts(r['anchorsProsth']),
    );
  }
}

const kMatchFillPrompt =
    'Inside the open mouth of this natural smile photo, fill ONLY the masked gaps: '
    'the dark oral cavity, natural shadows between the teeth and lips, and the seams around the existing new teeth. '
    'Keep every visible tooth exactly as it is (shape, size, position, color). '
    'Do not add gums that are hidden by the lips, do not change the lips. Photorealistic, no text.';

const kMatchRetouchPrompt =
    'Image 1 is a composite: new prosthetic teeth were placed inside the lips of a natural smile. '
    'Image 2 is the ORIGINAL smile photo (reference for lighting). '
    'Retouch Image 1 so the teeth match Image 2\'s lighting, color temperature, lip shadows on the upper teeth, '
    'depth of the mouth corners and photo grain, so it looks like one real photo. '
    'Do NOT change the shape, size, length, width or position of any tooth, do not change the lips, face or framing. '
    'Output the edited Image 1 only.';

/// 결과 (중간 단계도 같이 → 화면에서 비교·문제 확인)
class MatchResult {
  const MatchResult({
    required this.align,
    required this.composite,
    required this.stage1,
    required this.finalImage,
    this.notes = const [],
  });
  final AlignOut align;
  final Uint8List composite; // ② 정렬 합성 (AI 전)
  final Uint8List stage1; // ③ FLUX Fill 1차
  final Uint8List finalImage; // ④⑤ 최종
  final List<String> notes; // 건너뛴 단계 등 안내
}

/// ② 정렬 합성: 입술 안쪽(mask)과 정렬된 보철 치아가 겹치는 곳만 치아를 붙임.
/// 돌려줌: (합성 JPEG, FLUX 가 채울 마스크 PNG = 입술 안쪽 중 치아가 못 덮은 곳 + 치아 경계 띠)
(Uint8List, Uint8List) composeAligned((Uint8List, Uint8List, Uint8List) a) {
  final (smileJpeg, teethPng, maskPng) = a;
  final base = img.decodeImage(smileJpeg)!;
  var teeth = img.decodePng(teethPng)!;
  var mask = img.decodePng(maskPng)!;
  if (teeth.width != base.width || teeth.height != base.height) {
    teeth = img.copyResize(teeth, width: base.width, height: base.height);
  }
  if (mask.width != base.width || mask.height != base.height) {
    mask = img.copyResize(mask, width: base.width, height: base.height);
  }
  final out = base.clone();
  final fill = img.Image(
    width: base.width,
    height: base.height,
    numChannels: 1,
  );
  final core = img.Image(
    width: base.width,
    height: base.height,
    numChannels: 1,
  );
  for (var y = 0; y < base.height; y++) {
    for (var x = 0; x < base.width; x++) {
      final m = mask.getPixel(x, y).r / 255.0;
      if (m <= 0.01) continue;
      final t = teeth.getPixel(x, y);
      final ta = (t.a / 255.0) * m;
      if (ta > 0.01) {
        final o = out.getPixel(x, y);
        out.setPixelRgb(
          x,
          y,
          (o.r * (1 - ta) + t.r * ta).round(),
          (o.g * (1 - ta) + t.g * ta).round(),
          (o.b * (1 - ta) + t.b * ta).round(),
        );
      }
      if (ta > 0.9) {
        core.setPixelR(x, y, 255);
      } else {
        fill.setPixelR(x, y, 255); // 입술 안쪽인데 보철 치아가 못 덮은 곳 (예전 치아가 남은 곳)
      }
    }
  }
  // 치아 경계 2px 도 FLUX 가 자연스럽게 잇도록
  final grownCore = dilate(core, 2);
  for (var y = 0; y < base.height; y++) {
    for (var x = 0; x < base.width; x++) {
      if (grownCore.getPixel(x, y).r > 127 &&
          core.getPixel(x, y).r <= 127 &&
          mask.getPixel(x, y).r > 127) {
        fill.setPixelR(x, y, 255);
      }
    }
  }
  return (img.encodeJpg(out, quality: 95), img.encodePng(fill));
}

/// 크롭 영역 잘라 JPEG / PNG
Uint8List _cropJpeg((Uint8List, Rect) a) {
  final s = img.decodeImage(a.$1)!;
  final r = a.$2;
  return img.encodeJpg(
    img.copyCrop(
      s,
      x: (r.left * s.width).round(),
      y: (r.top * s.height).round(),
      width: (r.width * s.width).round(),
      height: (r.height * s.height).round(),
    ),
    quality: 95,
  );
}

Uint8List _cropPng((Uint8List, Rect) a) {
  final s = img.decodePng(a.$1)!;
  final r = a.$2;
  return img.encodePng(
    img.copyCrop(
      s,
      x: (r.left * s.width).round(),
      y: (r.top * s.height).round(),
      width: (r.width * s.width).round(),
      height: (r.height * s.height).round(),
    ),
  );
}

/// 잘라서 처리한 결과를 원래 사진 자리에 다시 붙임
Uint8List _pasteBack((Uint8List, Uint8List, Rect) a) {
  final full = img.decodeImage(a.$1)!;
  var part = img.decodeImage(a.$2)!;
  final r = a.$3;
  final x = (r.left * full.width).round(), y = (r.top * full.height).round();
  final w = (r.width * full.width).round(),
      h = (r.height * full.height).round();
  part = img.copyResize(
    part,
    width: w,
    height: h,
    interpolation: img.Interpolation.cubic,
  );
  img.compositeImage(full, part, dstX: x, dstY: y);
  return img.encodeJpg(full, quality: 95);
}

/// 전체 정밀 매칭 함수 모양 (미소, 보철, 단계 알림) → 결과
typedef MatchFn = Future<MatchResult> Function(
  Uint8List smile,
  Uint8List prosth,
  void Function(String) onStep,
);

/// 테스트용: 메인 화면(PC 원격)의 정밀 매칭을 가짜로 바꿈 (평소엔 null)
MatchFn? debugMatchOverride;

typedef AlignFn = Future<AlignOut> Function(Uint8List smile, Uint8List prosth);
typedef FillFn = Future<Uint8List> Function(
  Uint8List jpeg,
  Uint8List maskPng,
  String prompt,
);
typedef RetouchFn = Future<Uint8List> Function(
  Uint8List composite,
  Uint8List original,
  String prompt,
);

/// 실제 연결: Fal FLUX Fill (앱 설정의 키)
Future<Uint8List> realFill(Uint8List jpeg, Uint8List maskPng, String prompt) {
  final key = PipelineSettings.instance.falKey;
  if (key == null) {
    throw const PipelineError(
      'FLUX(1단계)에는 Fal.ai API 키가 필요합니다. [🔑 API 키 설정]에서 넣어 주세요.',
    );
  }
  return FalFluxFill(key).fill(jpeg: jpeg, maskPng: maskPng, prompt: prompt);
}

/// 실제 연결: 나노바나나 Pro (실패하면 2.1)
Future<Uint8List> realRetouch(
  Uint8List composite,
  Uint8List original,
  String prompt,
) async {
  final s = PipelineSettings.instance;
  final extra = [
    (label: 'Image 2 (original smile, lighting reference):', jpeg: original),
  ];
  try {
    return await AiService.instance.geminiImage(
      model: s.nanoProModel,
      prompt: prompt,
      jpeg: composite,
      extra: extra,
    );
  } on AiError {
    return AiService.instance.geminiImage(
      model: s.nanoModel,
      prompt: prompt,
      jpeg: composite,
      extra: extra,
    );
  }
}

/// 🦷😊 전체 체이닝: 정렬(기기 안) → 합성 → FLUX Fill → 나노바나나 → 입술 밖 원본 고정
Future<MatchResult> matchProsthesis({
  required Uint8List smile,
  required Uint8List prosth,
  required void Function(String msg) onStep,
  AlignFn? align,
  FillFn? fill,
  RetouchFn? retouch,
}) async {
  final notes = <String>[];
  // 0) 두 사진을 똑바로 세운 JPEG (EXIF 회전 반영, 긴 변 2000px)
  onStep('사진 준비 중…');
  final smileJpeg = img.encodeJpg(
    await AiService.decodePhoto(smile),
    quality: 95,
  );
  final prosthJpeg = img.encodeJpg(
    await AiService.decodePhoto(prosth),
    quality: 95,
  );

  // ① 기기 안 정렬
  onStep('① 📍 얼굴 특징점(눈 중심·코끝)으로 두 사진 정렬 중…');
  final a = await (align ?? DentalAligner.align)(smileJpeg, prosthJpeg);

  // ② 정렬 합성
  onStep('② 입술 안쪽에 보철 치아 붙이는 중…');
  final (composite, fillMask) = await compute(composeAligned, (
    smileJpeg,
    a.alignedTeeth,
    a.mask,
  ));
  final lip = img.decodePng(a.mask)!;
  final bounds = maskBounds(lip);
  if (bounds == null) throw const PipelineError('1번(미소) 사진에서 입술 안쪽을 찾지 못했습니다.');
  final crop = mouthCrop(bounds);

  // ③ FLUX Fill: 입 주변만 잘라 빈 곳·경계 채우기
  var stage1 = composite;
  onStep('③ FLUX: 입 안쪽 빈 곳·경계 자연스럽게 채우는 중…');
  try {
    final cJ = await compute(_cropJpeg, (composite, crop));
    final cM = await compute(_cropPng, (fillMask, crop));
    final f = await (fill ?? realFill)(cJ, cM, kMatchFillPrompt);
    stage1 = await compute(_pasteBack, (composite, f, crop));
  } on PipelineError catch (e) {
    notes.add('FLUX 단계를 건너뛰었습니다 (${e.message})');
  }

  // ④ 나노바나나 리터칭 (원본 미소를 조명 참고로 같이 보냄)
  var finalImg = stage1;
  onStep('④ 나노바나나: 입술 그림자·조명 톤 맞추는 중…');
  try {
    final cS = await compute(_cropJpeg, (stage1, crop));
    final cO = await compute(_cropJpeg, (smileJpeg, crop));
    final r = await (retouch ?? realRetouch)(cS, cO, kMatchRetouchPrompt);
    finalImg = await compute(_pasteBack, (stage1, r, crop));
  } on AiError catch (e) {
    notes.add('나노바나나 리터칭을 건너뛰었습니다 (${e.message})');
  } on PipelineError catch (e) {
    notes.add('나노바나나 리터칭을 건너뛰었습니다 (${e.message})');
  }

  // ⑤ 입술 안쪽 바깥은 1번 원본으로 (입술 경계 2px 만 부드럽게)
  onStep('⑤ 입술·얼굴은 원본 그대로 고정하는 중…');
  final region = await compute((m) => dilate(m, 2), lip);
  final src = img.decodeJpg(smileJpeg)!;
  final out = await compute(protectOutside, (src, finalImg, region));
  return MatchResult(
    align: a,
    composite: composite,
    stage1: stage1,
    finalImage: out,
    notes: notes,
  );
}
