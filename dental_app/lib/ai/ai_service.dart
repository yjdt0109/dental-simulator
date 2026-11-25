import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Offset;

import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'align_fix.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../simulator/sim_models.dart' show GuideLine, MaskStroke;

/// 나노바나나 2.1 (Gemini 이미지 모델) 로 After 시뮬레이션 만들기.
///
/// - Firebase AI Logic + Vertex AI(Agent Platform) 백엔드 → Google Cloud 크레딧 사용
/// - API 키를 앱에 넣지 않음. 대신 App Check(앱 인증)로 "우리 앱" 요청만 허용
/// - 얼굴이 바뀌지 않도록 입 주변만 잘라 보내고, 결과를 원본 사진에 자연스럽게 합성
class AiService {
  AiService._();
  static final AiService instance = AiService._();

  static const modelId = 'gemini-nano-banana-2.1';
  static const _prefToken = 'ai.appCheckDebugToken';

  bool ready = false;

  /// 이 태블릿의 App Check 테스트용 토큰 (Firebase 콘솔에 한 번 등록)
  String? debugToken;

  /// 앱 시작 시 (Firebase 초기화 직후) 한 번
  Future<void> init() async {
    if (Firebase.apps.isEmpty ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      debugToken = prefs.getString(_prefToken);
      if (debugToken == null) {
        debugToken = _uuidV4();
        await prefs.setString(_prefToken, debugToken!);
      }
      // 스토어 출시 전 테스트 단계: 기기별 디버그 토큰 사용
      // (Play 스토어 출시 때 AndroidPlayIntegrityProvider 로 바꾸면 됨)
      await FirebaseAppCheck.instance.activate(
        providerAndroid: AndroidDebugProvider(debugToken: debugToken),
      );
      ready = true;
      await loadRequest();
    } catch (e) {
      debugPrint('AiService.init: $e');
    }
  }

  /// [추가 요청] 칸 기본값: 비어 있음 (치료 항목별 임상 지시는 prompt_engine.dart 가 자동으로 넣음)
  static const defaultRequest = '';

  /// 예전 버전의 자동 문장 (저장돼 있으면 지움)
  static const _oldDefaults = [
    '상악 6전치(13~23)를 가지런하게 배열해 주세요. 치아 크기·모양과 잇몸은 자연스럽게 유지하고, 나머지 치아는 바꾸지 마세요.',
    '상악 6전치(13~23)를 가지런하게 배열해 주세요. 잇몸선(치경부 라인)과 하악 치아, 나머지 치아는 절대 바꾸지 마세요.',
    '상악·하악 치아의 서비컬 라인(치경부 잇몸선)을 기준선으로 삼아 변환해 주세요. 서비컬 라인의 위치·모양과 잇몸은 그대로 두고, 그 기준선에서 시작하는 치관만 가지런하고 자연스럽게 다듬어 주세요. 하악 치아는 최소한으로만 바꿔 주세요.',
  ];
  static const _prefRequest = 'ai.request';

  /// 현재 요청 내용 (앱을 껐다 켜도 유지)
  String request = defaultRequest;

  Future<void> loadRequest() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefRequest);
      if (v != null &&
          v.trim().isNotEmpty &&
          !_oldDefaults.contains(v.trim())) {
        request = v;
      }
    } catch (_) {}
  }

  Future<void> saveRequest(String v) async {
    request = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefRequest, v);
    } catch (_) {}
  }

  /// [before] 원본 사진, [roi] 치아 영역(0~1 비율). 실패하면 예외(AiError).
  Future<Uint8List> generateAfter({
    required Uint8List before,
    ui.Rect? roi, // null: 사진 전체를 보내고 결과 전체를 사용 (순수 프롬프트 방식)
    required String prompt,
    List<MaskStroke> mask = const [],
    List<GuideLine> guide = const [], // 서비컬 라인 (있으면 두 번째 사진으로 함께 보냄)
    List<GuideLine> lock = const [], // 이 선 바깥쪽 잇몸은 원본 픽셀로 고정
    List<({String label, Uint8List jpeg})> refs =
        const [], // 참고 사진 (예: 같은 환자 미소 사진)
  }) async {
    if (!ready) throw const AiError('AI 연결이 준비되지 않았습니다. 앱을 다시 실행해 주세요.');
    // 1) 원본 디코드 (긴 변 2000px 이하)
    final src = await _decode(before, 2000);
    // 2) 치아 영역 + 여유 25% 를 잘라서 보냄 (얼굴 전체를 보내지 않음)
    final crop = roi == null
        ? (x: 0, y: 0, w: src.width, h: src.height)
        : _cropRect(roi, src.width, src.height, margin: 0.25);
    final cropBytes = await compute(_cropJpeg, (src, crop));
    final guideBytes = roi == null && guide.isNotEmpty
        ? await compute(_guideJpeg, (src, guide))
        : null;
    // 3) 나노바나나 호출
    final aiBytes = await geminiImage(
      model: modelId,
      prompt: prompt,
      jpeg: cropBytes,
      guideJpeg: guideBytes,
      extra: refs,
    );
    if (roi == null) {
      return compute(_fullResult, (src, aiBytes, lock));
    }
    // 4) 결과를 원본의 같은 자리에 부드럽게 합성
    return compute(_composite, (src, crop, aiBytes, mask));
  }

  /// Gemini 이미지 모델(나노바나나 2.1 / Pro 등) 한 번 호출 → AI 가 만든 사진 그대로 (합성 전)
  Future<Uint8List> geminiImage({
    required String model,
    required String prompt,
    required Uint8List jpeg,
    Uint8List? guideJpeg,
    List<({String label, Uint8List jpeg})> extra = const [],
  }) async {
    if (!ready) throw const AiError('AI 연결이 준비되지 않았습니다. 앱을 다시 실행해 주세요.');
    final m = FirebaseAI.agentPlatform(useLimitedUseAppCheckTokens: false)
        .generativeModel(
          model: model,
          generationConfig: GenerationConfig(
            responseModalities: [ResponseModalities.image],
          ),
        );
    GenerateContentResponse res;
    try {
      res = await m
          .generateContent([
            Content.multi([
              TextPart(prompt),
              InlineDataPart('image/jpeg', jpeg),
              if (guideJpeg != null) ...[
                TextPart(
                  'Second image: the same photo with the cervical guide lines (reference only).',
                ),
                InlineDataPart('image/jpeg', guideJpeg),
              ],
              for (final e in extra) ...[
                TextPart(e.label),
                InlineDataPart('image/jpeg', e.jpeg),
              ],
            ]),
          ])
          .timeout(const Duration(seconds: 120));
    } on TimeoutException {
      throw const AiError('AI 응답이 너무 늦습니다. 인터넷 연결을 확인하고 다시 시도해 주세요.');
    } catch (e) {
      throw AiError.from(e);
    }
    final parts = res.inlineDataParts
        .where((p) => p.mimeType.startsWith('image/'))
        .toList();
    if (parts.isEmpty) {
      throw const AiError('AI가 이미지를 만들지 못했습니다. 요청 내용을 바꿔 다시 시도해 주세요.');
    }
    return parts.first.bytes;
  }

  /// 비전 AI 텍스트 답변 (자동 QA 채점용): 여러 장의 사진 + 지시 → JSON 문자열
  Future<String> geminiText({
    required String model,
    required String prompt,
    required List<({String label, Uint8List jpeg})> images,
  }) async {
    if (!ready) throw const AiError('AI 연결이 준비되지 않았습니다. 앱을 다시 실행해 주세요.');
    final m = FirebaseAI.agentPlatform(useLimitedUseAppCheckTokens: false)
        .generativeModel(
          model: model,
          generationConfig: GenerationConfig(
            responseMimeType: 'application/json',
            temperature: 0.2,
          ),
        );
    try {
      final res = await m
          .generateContent([
            Content.multi([
              TextPart(prompt),
              for (final im in images) ...[
                TextPart(im.label),
                InlineDataPart('image/jpeg', im.jpeg),
              ],
            ]),
          ])
          .timeout(const Duration(seconds: 120));
      final t = res.text;
      if (t == null || t.trim().isEmpty) {
        throw const AiError('채점 AI가 답을 주지 않았습니다.');
      }
      return t;
    } on TimeoutException {
      throw const AiError('채점 AI 응답이 너무 늦습니다.');
    } on AiError {
      rethrow;
    } catch (e) {
      final t = '$e';
      if (t.contains('Publisher model') ||
          t.contains('not found') ||
          t.contains('NOT_FOUND') ||
          t.contains('does not have access')) {
        throw AiError(
          '이 AI 모델을 쓸 수 없습니다 ($model: 종료되었거나 이 프로젝트·지역에서 열려 있지 않음)',
        );
      }
      throw AiError.from(e);
    }
  }

  // ---- 2단계 파이프라인에서 쓰는 도우미 ----
  /// 원본을 긴 변 [maxSide] 이하로 풀기 (화면에 보이는 방향 그대로)
  static Future<img.Image> decodePhoto(Uint8List bytes, {int maxSide = 2000}) =>
      _decode(bytes, maxSide);

  /// AI 에 보낼 JPEG (긴 변 1536px 이하)
  static Future<Uint8List> photoJpeg(img.Image src) =>
      compute(_cropJpeg, (src, (x: 0, y: 0, w: src.width, h: src.height)));

  /// 서비컬 라인을 그린 참고 사진
  static Future<Uint8List> guideJpeg(img.Image src, List<GuideLine> lines) =>
      compute(_guideJpeg, (src, lines));

  /// AI 결과를 원본 크기로 맞추고 잇몸 잠금(원본 픽셀) 적용 → 최종 JPEG
  static Future<Uint8List> finish(
    img.Image src,
    Uint8List aiBytes,
    List<GuideLine> lock,
  ) => compute(_fullResult, (src, aiBytes, lock));

  static String _uuidV4() {
    final r = math.Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    final s = List.generate(16, h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
}

class AiError implements Exception {
  const AiError(this.message);
  final String message;

  factory AiError.from(Object e) {
    final t = e.toString();
    if (t.contains('App Check') ||
        t.contains('app-check') ||
        t.contains('appCheck') ||
        t.contains('UNAUTHENTICATED')) {
      return const AiError(
        'AI 연결 인증(App Check)이 필요합니다. [AI 연결 설정]의 인증 토큰을 Firebase 콘솔에 등록해 주세요.',
      );
    }
    if (t.contains('BILLING') || t.contains('billing')) {
      return const AiError(
        '결제(크레딧) 설정을 확인해 주세요. Firebase 프로젝트가 Blaze 요금제인지 확인이 필요합니다.',
      );
    }
    if (t.contains('PERMISSION_DENIED') ||
        t.contains('not been used') ||
        t.contains('disabled')) {
      return const AiError(
        'Firebase AI Logic(Vertex AI) 사용 설정이 필요합니다. 콘솔에서 AI Logic을 켜 주세요.',
      );
    }
    if (t.contains('SAFETY') || t.contains('blocked')) {
      return const AiError('AI가 이 사진을 처리하지 않았습니다. 입 주변만 나온 사진으로 다시 시도해 주세요.');
    }
    if (t.contains('RESOURCE_EXHAUSTED') || t.contains('429')) {
      return const AiError('잠시 요청이 많습니다. 1분 뒤 다시 시도해 주세요.');
    }
    return AiError('AI 변환에 실패했습니다. ($t)');
  }

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// 이미지 처리 (isolate 에서 실행)
// ---------------------------------------------------------------------------
Future<img.Image> _decode(Uint8List bytes, int maxSide) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  final scale = math.min(1.0, maxSide / math.max(desc.width, desc.height));
  final w = (desc.width * scale).round(), h = (desc.height * scale).round();
  final codec = await desc.instantiateCodec(targetWidth: w, targetHeight: h);
  final frame = await codec.getNextFrame();
  final raw = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  return img.Image.fromBytes(
    width: w,
    height: h,
    bytes: raw!.buffer,
    numChannels: 4,
  );
}

/// roi(0~1) 를 여유를 두고 픽셀 사각형으로
({int x, int y, int w, int h}) _cropRect(
  ui.Rect roi,
  int w,
  int h, {
  double margin = 0.25,
}) {
  final mx = roi.width * margin, my = roi.height * margin;
  final l = ((roi.left - mx).clamp(0.0, 1.0) * w).floor();
  final t = ((roi.top - my).clamp(0.0, 1.0) * h).floor();
  final r = ((roi.right + mx).clamp(0.0, 1.0) * w).ceil();
  final b = ((roi.bottom + my).clamp(0.0, 1.0) * h).ceil();
  return (x: l, y: t, w: math.max(16, r - l), h: math.max(16, b - t));
}

Uint8List _cropJpeg((img.Image, ({int x, int y, int w, int h})) a) {
  final (src, c) = a;
  var crop = img.copyCrop(src, x: c.x, y: c.y, width: c.w, height: c.h);
  const maxSide = 1536;
  if (math.max(crop.width, crop.height) > maxSide) {
    crop = crop.width >= crop.height
        ? img.copyResize(crop, width: maxSide)
        : img.copyResize(crop, height: maxSide);
  }
  return img.encodeJpg(crop, quality: 92);
}

/// 서비컬 라인을 그린 참고 사진 (상악 초록, 하악 분홍) — 보내는 사진과 같은 크기
Uint8List _guideJpeg((img.Image, List<GuideLine>) a) {
  final (src, lines) = a;
  var out = img.Image.from(src);
  final th = math.max(2, (math.max(src.width, src.height) / 600).round());
  for (final l in lines) {
    final col = l.upper
        ? img.ColorRgb8(0, 230, 80)
        : img.ColorRgb8(255, 0, 170);
    for (var i = 1; i < l.pts.length; i++) {
      final p0 = l.pts[i - 1], p1 = l.pts[i];
      img.drawLine(
        out,
        x1: (p0.dx * src.width).round(),
        y1: (p0.dy * src.height).round(),
        x2: (p1.dx * src.width).round(),
        y2: (p1.dy * src.height).round(),
        color: col,
        thickness: th,
      );
    }
  }
  const maxSide = 1536;
  if (math.max(out.width, out.height) > maxSide) {
    out = out.width >= out.height
        ? img.copyResize(out, width: maxSide)
        : img.copyResize(out, height: maxSide);
  }
  return img.encodeJpg(out, quality: 90);
}

@visibleForTesting
Uint8List guideForTest(img.Image src, List<GuideLine> lines) =>
    _guideJpeg((src, lines));

/// 칠한 부분(마스크) → 잘라낸 영역 크기의 가중치(0~1). 가장자리는 살짝 흐리게.
List<double>? _maskWeights(
  List<MaskStroke> mask,
  int srcW,
  int srcH,
  ({int x, int y, int w, int h}) c,
) {
  if (mask.isEmpty) return null;
  final m = img.Image(width: c.w, height: c.h, numChannels: 1);
  for (final st in mask) {
    final col = img.ColorUint8.rgb(st.erase ? 0 : 255, 0, 0);
    final r = math.max(1.0, st.r * srcW);
    Offset? prev;
    for (final p in st.pts) {
      final q = Offset(p.dx * srcW - c.x, p.dy * srcH - c.y);
      final from = prev ?? q;
      final dist = (q - from).distance;
      final steps = math.max(1, (dist / (r * 0.4)).ceil());
      for (var i = 0; i <= steps; i++) {
        final pt = Offset.lerp(from, q, i / steps)!;
        img.fillCircle(
          m,
          x: pt.dx.round(),
          y: pt.dy.round(),
          radius: r.round(),
          color: col,
        );
      }
      prev = q;
    }
  }
  final blur = math.max(2, (math.max(c.w, c.h) / 160).round());
  final b = img.gaussianBlur(m, radius: blur);
  return [
    for (var y = 0; y < c.h; y++)
      for (var x = 0; x < c.w; x++) b.getPixel(x, y).r / 255.0,
  ];
}

/// 순수 프롬프트 방식: AI 결과 전체를 원본 크기로 (비율이 다르면 가운데 기준으로 맞춤)
Uint8List _fullResult((img.Image, Uint8List, List<GuideLine>) a) {
  final (src, aiBytes, lock) = a;
  var ai = img.decodeImage(aiBytes);
  if (ai == null) throw const AiError('AI 결과 이미지를 읽지 못했습니다.');
  final want = src.width / src.height, got = ai.width / ai.height;
  if ((want - got).abs() / want > 0.02) {
    if (got > want) {
      final w = (ai.height * want).round();
      ai = img.copyCrop(
        ai,
        x: (ai.width - w) ~/ 2,
        y: 0,
        width: w,
        height: ai.height,
      );
    } else {
      final h = (ai.width / want).round();
      ai = img.copyCrop(
        ai,
        x: 0,
        y: (ai.height - h) ~/ 2,
        width: ai.width,
        height: h,
      );
    }
  }
  var out = img.copyResize(
    ai,
    width: src.width,
    height: src.height,
    interpolation: img.Interpolation.cubic,
  );
  // ② AI 가 사진을 밀거나 키웠으면 원본에 맞게 되돌림 (잇몸선·경계가 어긋나지 않게)
  out = alignAiToSource(src, out).image;
  for (final l in lock) {
    _lockGum(src, out, l);
  }
  return img.encodeJpg(out, quality: 92);
}

@visibleForTesting
Uint8List fullResultForTest(
  img.Image src,
  Uint8List ai, {
  List<GuideLine> lock = const [],
}) => _fullResult((src, ai, lock));

/// 잇몸 마스크 잠금: 상악선 위쪽 / 하악선 아래쪽은 AI 결과 대신 원본 픽셀을 그대로 씀.
/// 선 바로 근처(몇 px)와 선의 양 끝은 부드럽게 섞어서 경계가 티 나지 않게.
void _lockGum(img.Image src, img.Image out, GuideLine line) {
  final w = src.width, h = src.height;
  if (line.pts.length < 2) return;
  // 가로 위치별로 선의 높이 (여러 번 지나가면 상악은 가장 위, 하악은 가장 아래 → 치아는 잠그지 않음)
  final ys = List<double?>.filled(w, null);
  for (var i = 1; i < line.pts.length; i++) {
    final a = line.pts[i - 1], b = line.pts[i];
    final ax = a.dx * (w - 1),
        ay = a.dy * (h - 1),
        bx = b.dx * (w - 1),
        by = b.dy * (h - 1);
    final x0 = math.min(ax, bx).round(), x1 = math.max(ax, bx).round();
    for (var x = math.max(0, x0); x <= math.min(w - 1, x1); x++) {
      final t = (bx - ax).abs() < 1e-6
          ? 0.0
          : ((x - ax) / (bx - ax)).clamp(0.0, 1.0);
      final y = ay + (by - ay) * t;
      final cur = ys[x];
      ys[x] = cur == null
          ? y
          : (line.upper ? math.min(cur, y) : math.max(cur, y));
    }
  }
  final xs = [
    for (var x = 0; x < w; x++)
      if (ys[x] != null) x,
  ];
  if (xs.isEmpty) return;
  final first = xs.first, last = xs.last;
  final fadeX = math.max(4.0, w * 0.015); // 선 양 끝 부드럽게
  const fadeY = 4.0; // 선 근처 부드럽게
  for (final x in xs) {
    final yl = ys[x]!;
    final ex = math.min(1.0, math.min(x - first, last - x) / fadeX);
    if (ex <= 0) continue;
    final yFrom = line.upper ? 0 : math.max(0, (yl - 1).floor());
    final yTo = line.upper ? math.min(h - 1, (yl + 1).ceil()) : h - 1;
    for (var y = yFrom; y <= yTo; y++) {
      // 잇몸 쪽으로 fadeY 만큼 들어가면 완전히 원본
      final inside = line.upper ? (yl + 1 - y) : (y - (yl - 1));
      final wy = (inside / fadeY).clamp(0.0, 1.0);
      final k = wy * ex;
      if (k <= 0) continue;
      final o = src.getPixel(x, y), p = out.getPixel(x, y);
      out.setPixelRgb(
        x,
        y,
        (p.r + (o.r - p.r) * k).round(),
        (p.g + (o.g - p.g) * k).round(),
        (p.b + (o.b - p.b) * k).round(),
      );
    }
  }
}

/// 테스트용: 원본 + AI 결과 + 칠한 범위 → 합성 결과
@visibleForTesting
Uint8List compositeForTest(
  img.Image src,
  ({int x, int y, int w, int h}) crop,
  Uint8List ai,
  List<MaskStroke> mask,
) => _composite((src, crop, ai, mask));

/// AI 결과를 잘라낸 자리 크기로 맞춰, 가장자리는 서서히 섞이게(타원형 페더) 원본에 합성 → JPEG
Uint8List _composite(
  (img.Image, ({int x, int y, int w, int h}), Uint8List, List<MaskStroke>) a,
) {
  final (src, c, aiBytes, mask) = a;
  final mw = _maskWeights(mask, src.width, src.height, c);
  final ai0 = img.decodeImage(aiBytes);
  if (ai0 == null) throw const AiError('AI 결과 이미지를 읽지 못했습니다.');
  final ai = img.copyResize(
    ai0,
    width: c.w,
    height: c.h,
    interpolation: img.Interpolation.cubic,
  );
  final out = img.Image.from(src);
  for (var y = 0; y < c.h; y++) {
    final ny = (y + 0.5) / c.h * 2 - 1;
    for (var x = 0; x < c.w; x++) {
      final nx = (x + 0.5) / c.w * 2 - 1;
      // 둥근 사각형 거리 → 가장자리 18% 구간에서 0→1 로 섞임
      final d = math.pow(nx.abs(), 4) + math.pow(ny.abs(), 4);
      final t = (1 - ((d - 0.55) / 0.45)).clamp(0.0, 1.0);
      final wgt = mw != null ? mw[y * c.w + x] : t * t * (3 - 2 * t);
      if (wgt <= 0) continue;
      final o = out.getPixel(c.x + x, c.y + y), p = ai.getPixel(x, y);
      out.setPixelRgb(
        c.x + x,
        c.y + y,
        (o.r + (p.r - o.r) * wgt).round(),
        (o.g + (p.g - o.g) * wgt).round(),
        (o.b + (p.b - o.b) * wgt).round(),
      );
    }
  }
  return img.encodeJpg(out, quality: 92);
}
