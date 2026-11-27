import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../privacy/mouth_finder.dart';
import 'ai_service.dart';
import 'pipeline.dart';
import 'smile.dart' show dilate, polygonMask;
import 'tooth_select.dart' show protectOutside;

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
  if (poly == null || poly.length < 3) {
    // 입술을 못 찾으면 AI 결과를 원본 1 크기로만 맞춤
    final o = img.decodeImage(out);
    if (o == null) throw const PipelineError('2단계 결과 이미지를 읽지 못했습니다.');
    final r = (o.width == src.width && o.height == src.height)
        ? o
        : img.copyResize(o, width: src.width, height: src.height);
    return (image: img.encodeJpg(r, quality: 92), lipsLocked: false);
  }
  final mask = await compute((p) {
    final m = polygonMask(p.$1, p.$2, p.$3);
    return dilate(m, (p.$1 * 0.004).ceil() + 1); // 입술 안쪽 + 아주 얇은 경계
  }, (src.width, src.height, poly));
  final fixed = await compute(protectOutside, (src, out, mask));
  return (image: fixed, lipsLocked: true);
}
