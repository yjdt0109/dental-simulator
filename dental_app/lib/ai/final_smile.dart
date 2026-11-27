import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../privacy/mouth_finder.dart';
import 'ai_service.dart';
import 'pipeline.dart';
import 'smile.dart' show dilate, polygonMask;
import 'align_fix.dart' show alignAiToSource;

// -----------------------------------------------------------------------------
// 2단계: Final Smile Simulation
//   원본 1(자연스러운 미소) + 1단계 After(치열 레퍼런스) → fal.ai Nano Banana 편집
//   image_urls 순서: [원본 1, After]
// -----------------------------------------------------------------------------

/// 2단계 매칭 치환 지시문 (요청받은 문구 그대로)
const kFinalSmilePrompt =
    'Strictly preserve the first image (natural smile) as the base: keep the entire face, eyes, skin texture, background, '
    'and especially the exact shape, thickness, and outline of the upper and lower lips 100% unchanged without any distortion. '
    'Replace only the crooked teeth visible inside the mouth opening with the straight, evenly aligned, natural white upper teeth '
    'from the second reference image (After simulation). Completely remove any green attachment dots, white alignment grid lines, '
    'and text overlays from the teeth. Apply realistic tooth enamel texture and a natural soft shadow cast by the upper lip onto '
    'the top portion of the teeth so it blends seamlessly. Photorealistic clinical portrait.';

/// 원래 미소의 치아 길이 유지 (2026.11.27-g): After 는 개구기 사진이라 치아가 끝까지 다 보여서,
/// 그대로 옮기면 입술 사이를 꽉 채워 치아가 길어 보였음 → 보이는 길이·절단끝 높이는 첫 사진 그대로
const kFinalSmileKeepLength =
    'IMPORTANT - keep the tooth display of the first image: the incisal edges of the upper teeth must stay at the same height '
    'as in the first image and every tooth must show the same visible length as in the first image. Do NOT make the teeth '
    'longer or larger and do NOT fill the whole mouth opening with teeth. Keep the lower teeth, the dark space between the '
    'upper and lower teeth and the dark corners of the mouth (buccal corridors) as they are in the first image. '
    'Use the second image only as a reference for tooth shape, alignment, the proportions between the teeth and color.';

/// 📐 6전치 라이브러리 합성 → AI 로 자연스럽게 (모양·위치·길이 유지, 조명·질감만)
const kLibraryBlendPrompt =
    'This is a dental smile-design mock-up: idealized upper front teeth from a tooth library were placed on the patient photo. '
    'Make it look like one real clinical photograph. Keep the exact shape, outline, size, length, width, position and '
    'arrangement of every placed tooth (do not redesign the teeth, do NOT make any tooth longer or shorter, keep the incisal edges exactly where they are), '
    'keep the lips, gums, face, background and framing unchanged. '
    'Only add realistic enamel texture, translucency at the incisal edges, natural surface reflections, the soft shadows '
    'of the lips and the mouth interior, and match the lighting, color temperature and photo grain of the photo. '
    'Blend the tooth edges naturally with the gums. Photorealistic, no text.';

/// 2단계 지시문 만들기: 기본 문구 + (길이 유지) + (추가 요청, 한글 가능)
String finalSmilePrompt({bool keepLength = true, String extra = ''}) {
  final b = StringBuffer(kFinalSmilePrompt);
  if (keepLength) b.write(' $kFinalSmileKeepLength');
  final x = extra.trim();
  if (x.isNotEmpty) {
    b.write(
      ' Additional request from the dentist (may be written in Korean, follow it): $x',
    );
  }
  return b.toString();
}

/// fal.ai Nano Banana 편집 (여러 장 입력 → 1장)
class FalNanoBananaEdit {
  FalNanoBananaEdit(this.key, {http.Client? client, this.pro = false})
    : _client = client ?? http.Client();
  final String key;
  final bool pro; // true: nano-banana-pro (더 정교, 더 비쌈)
  final http.Client _client;

  Uri get endpoint => Uri.parse(
    pro
        ? 'https://fal.run/fal-ai/nano-banana-pro/edit'
        : 'https://fal.run/fal-ai/nano-banana/edit',
  );

  /// 요청 본문 (시험에서 확인하려고 따로 둠)
  static Map<String, Object?> body(List<Uint8List> jpegs, String prompt) => {
    'prompt': prompt,
    'image_urls': [
      for (final j in jpegs) 'data:image/jpeg;base64,${base64Encode(j)}',
    ],
    'num_images': 1,
    'output_format': 'jpeg',
    // 결과를 응답에 바로 담아 받음 → 환자 사진이 fal 저장소 주소로 남지 않게
    'sync_mode': true,
  };

  Future<Uint8List> edit({
    required List<Uint8List> jpegs,
    required String prompt,
  }) async {
    final http.Response r;
    try {
      r = await _client
          .post(
            endpoint,
            headers: {
              'Authorization': 'Key $key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body(jpegs, prompt)),
          )
          .timeout(const Duration(seconds: 180));
    } on TimeoutException {
      throw const PipelineError(
        '나노바나나(fal.ai) 응답이 너무 늦습니다. 인터넷을 확인하고 다시 시도해 주세요.',
      );
    } catch (e) {
      throw PipelineError('나노바나나(fal.ai)에 연결하지 못했습니다. 인터넷을 확인해 주세요. ($e)');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw const PipelineError('Fal.ai API 키가 맞지 않습니다. [API 키 설정]에서 확인해 주세요.');
    }
    if (r.statusCode == 402 || r.statusCode == 429) {
      throw const PipelineError(
        'Fal.ai 크레딧이 부족하거나 요청이 많습니다. Fal.ai 결제·사용량을 확인해 주세요.',
      );
    }
    if (r.statusCode != 200) {
      final b = r.body;
      throw PipelineError(
        '나노바나나(fal.ai) 실패 (${r.statusCode}): ${b.length > 160 ? '${b.substring(0, 160)}…' : b}',
      );
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw const PipelineError('나노바나나(fal.ai) 응답을 읽지 못했습니다.');
    }
    final images = j['images'];
    final url = images is List && images.isNotEmpty && images.first is Map
        ? (images.first as Map)['url']
        : null;
    if (url is! String) {
      throw const PipelineError(
        '나노바나나(fal.ai)가 이미지를 돌려주지 않았습니다 (안전 필터일 수 있어요).',
      );
    }
    if (url.startsWith('data:')) {
      return base64Decode(url.substring(url.indexOf(',') + 1));
    }
    final g = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 60));
    if (g.statusCode != 200) {
      throw const PipelineError('나노바나나(fal.ai) 결과 이미지를 내려받지 못했습니다.');
    }
    return g.bodyBytes;
  }
}

/// 테스트용: 메인 화면 2단계를 가짜로 바꿈 (평소엔 null)
Future<({Uint8List image, bool lipsLocked})> Function({
  required Uint8List orig1,
  required Uint8List after,
  Uint8List? base,
  String prompt,
})?
debugFinalSmile;

typedef FinalEditFn = Future<Uint8List> Function(
  List<Uint8List> jpegs,
  String prompt,
);
typedef LipsFn = Future<List<Offset>?> Function(Uint8List smile);

/// 2단계 실행: 원본 1 + After → 최종 미소.
/// 입술 사이를 찾으면 그 바깥(입술·얼굴)은 원본 1 픽셀로 한 번 더 고정 (AI 가 입술을 바꿨을 때 대비)
/// [base]: 첫 번째로 보낼 사진 (없으면 원본 1). 지난 Final Smile 을 넣으면 그걸 이어서 다듬음.
///   입술·얼굴 고정은 항상 원본 1 기준
Future<({Uint8List image, bool lipsLocked})> makeFinalSmile({
  required Uint8List orig1,
  required Uint8List after,
  Uint8List? base,
  String prompt = kFinalSmilePrompt,
  FinalEditFn? edit,
  LipsFn? lips,
  bool pro = false,
}) async {
  final s = PipelineSettings.instance;
  final run =
      edit ??
      (List<Uint8List> jpegs, String prompt) {
        if (!s.hasFal) {
          throw const PipelineError(
            '2단계(나노바나나)를 쓰려면 [API 키 설정]에 Fal.ai API 키를 넣어 주세요.',
          );
        }
        return FalNanoBananaEdit(
          s.falKey!,
          pro: pro,
        ).edit(jpegs: jpegs, prompt: prompt);
      };
  final src = await AiService.decodePhoto(orig1, maxSide: 2000);
  final a = await AiService.decodePhoto(after, maxSide: 1536);
  var first = src;
  if (base != null) {
    final bi = await AiService.decodePhoto(base, maxSide: 2000);
    first = (bi.width == src.width && bi.height == src.height)
        ? bi
        : img.copyResize(bi, width: src.width, height: src.height);
  }
  final j1 = await AiService.photoJpeg(first);
  final j2 = await AiService.photoJpeg(a);
  final out = await run([j1, j2], prompt); // 순서: 원본 1(또는 지난 Final Smile), After
  List<Offset>? poly;
  try {
    poly = await (lips ?? MouthFinder.lips)(orig1);
  } catch (_) {
    poly = null;
  }
  final o = img.decodeImage(out);
  if (o == null) throw const PipelineError('2단계 결과 이미지를 읽지 못했습니다.');
  // AI 결과를 원본 1 에 정확히 맞춤 (비율이 다르면 늘이지 않고 잘라 맞춘 뒤, 밀림·확대 되돌림)
  final fitted = await compute((a) => fitAiToSource(a.$1, a.$2), (src, o));
  if (poly == null || poly.length < 3) {
    // 입술을 못 찾으면 위치만 맞춤
    return (image: img.encodeJpg(fitted, quality: 92), lipsLocked: false);
  }
  final fixed = await compute(composeFinalSmile, (src, fitted, poly));
  return (image: fixed, lipsLocked: true);
}

/// AI 결과 → 원본 크기·위치에 맞춤. 비율이 다르면(정사각형 등) 늘이지 않고 가득 채워 가운데를 자름(cover),
/// 그다음 얼굴·입술·배경 기준으로 밀림·확대를 되돌림 ([alignAiToSource])
img.Image fitAiToSource(img.Image src, img.Image ai) {
  var a = ai;
  if (a.width != src.width || a.height != src.height) {
    final k = math.max(src.width / a.width, src.height / a.height);
    final w = (a.width * k).round(), h = (a.height * k).round();
    a = img.copyResize(
      a,
      width: w,
      height: h,
      interpolation: img.Interpolation.cubic,
    );
    a = img.copyCrop(
      a,
      x: ((w - src.width) / 2).round(),
      y: ((h - src.height) / 2).round(),
      width: src.width,
      height: src.height,
    );
  }
  return alignAiToSource(src, a).image;
}

/// 📐 라이브러리 + AI: AI 결과를 합성 사진에 맞춘 뒤 [mask](흰색 = 라이브러리 치아) 안에서만 씀.
/// 윤곽 가장자리 2px 만 부드럽게 섞음 → 치아 길이·모양은 라이브러리 그대로
Uint8List blendInsideMask((img.Image, img.Image, img.Image) a) {
  final (comp, ai0, mask0) = a;
  final ai = fitAiToSource(comp, ai0);
  var mask = mask0;
  if (mask.width != comp.width || mask.height != comp.height) {
    mask = img.copyResize(mask, width: comp.width, height: comp.height);
  }
  // 바깥으로는 넓히지 않고 안쪽으로만 부드럽게 (윤곽 밖으로 AI 가 새어 나가지 않게)
  final soft = img.gaussianBlur(mask.clone(), radius: 2);
  final out = comp.clone();
  for (var y = 0; y < comp.height; y++) {
    for (var x = 0; x < comp.width; x++) {
      if (mask.getPixel(x, y).r < 128) continue;
      final m = math.min(1.0, soft.getPixel(x, y).r / 255.0 * 1.6);
      final c = comp.getPixel(x, y), r = ai.getPixel(x, y);
      out.setPixelRgb(
        x,
        y,
        (c.r * (1 - m) + r.r * m).round(),
        (c.g * (1 - m) + r.g * m).round(),
        (c.b * (1 - m) + r.b * m).round(),
      );
    }
  }
  return img.encodeJpg(out, quality: 92);
}

/// 입술·잇몸처럼 붉은 색인지 (치아=밝고 무채색, 입 안=어두움)
bool _lipLike(num r, num g, num b) => r >= 90 && r - g >= 35 && r - b >= 20;

/// Final Smile 합성: 입술 사이(입 벌어진 곳)만 AI, 바깥은 원본 1.
/// 입 벌어진 곳 가장자리 띠(폭 8%·높이 30% 중 작은 쪽)에서 AI 가 입술 색을 그렸는데 원본은 입술이 아니면
/// (= AI 가 입을 더 다물게 그림) 원본 픽셀을 씀 → 입술 모양·두께는 원본 그대로 (2026.11.27-j)
Uint8List composeFinalSmile((img.Image, img.Image, List<Offset>) a) {
  final (src, ai, poly) = a;
  final w = src.width, h = src.height;
  final region = dilate(polygonMask(w, h, poly), (w * 0.004).ceil() + 1);
  var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0;
  for (final p in poly) {
    minX = math.min(minX, p.dx);
    maxX = math.max(maxX, p.dx);
    minY = math.min(minY, p.dy);
    maxY = math.max(maxY, p.dy);
  }
  // 띠 두께: 입 벌어진 폭의 8% · 높이의 30% 중 작은 쪽 (AI 가 입술을 두껍게 그린 만큼을 덮음)
  final band = math.max(
    3,
    math.min((maxX - minX) * w * 0.08, (maxY - minY) * h * 0.3).round(),
  );
  // 안쪽(띠 제외) = 반전 마스크를 띠만큼 넓혀 다시 반전
  final inv = img.Image(width: w, height: h, numChannels: 1);
  for (final px in region) {
    inv.setPixelR(px.x, px.y, px.r > 127 ? 0 : 255);
  }
  final grownOut = dilate(inv, band);
  final soft = img.gaussianBlur(region.clone(), radius: 2);
  final out = ai.clone();
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final m = soft.getPixel(x, y).r / 255.0;
      final s = src.getPixel(x, y);
      if (m <= 0.001) {
        out.setPixelRgb(x, y, s.r, s.g, s.b);
        continue;
      }
      var r = ai.getPixel(x, y);
      num rr = r.r, rg = r.g, rb = r.b;
      final inBand = grownOut.getPixel(x, y).r > 127; // 가장자리 띠
      if (inBand && _lipLike(rr, rg, rb) && !_lipLike(s.r, s.g, s.b)) {
        rr = s.r;
        rg = s.g;
        rb = s.b;
      }
      out.setPixelRgb(
        x,
        y,
        (s.r * (1 - m) + rr * m).round(),
        (s.g * (1 - m) + rg * m).round(),
        (s.b * (1 - m) + rb * m).round(),
      );
    }
  }
  return img.encodeJpg(out, quality: 92);
}
