import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../simulator/sim_models.dart' show GuideLine;
import 'ai_service.dart';
import 'final_smile.dart' show FalNanoBananaEdit;

// =============================================================================
// 2단계(Two-Pass) 하이브리드 파이프라인
//   1단계: FLUX.1 Fill (Fal.ai) — 서비컬 라인 사이 치아 영역만 채워서 마진·잇몸·치아 골격 고정
//   2단계: 선택한 엔진으로 리얼리즘 마무리 (형태 변경 없이 질감·색조·광택만)
// =============================================================================

/// 변환 엔진
enum Engine {
  a('옵션 A', 'FLUX + 나노바나나 2.1', '가성비 마무리', '나노바나나 2.1', 'A'),
  b('옵션 B', 'FLUX + 나노바나나 Pro', '최고 화질 마무리', '나노바나나 Pro', 'B'),
  c('옵션 C', 'FLUX + Vertex AI', '무료 크레딧 활용 마무리', 'Vertex AI Imagen', 'C'),
  solo('교정·단독', '나노바나나 단독', '1단계 없이 기존 방식 (교정은 자동으로 이것)', '나노바나나 2.1', '단독');

  const Engine(this.tag, this.label, this.desc, this.finisher, this.short);
  final String tag, label, desc, finisher;

  /// 결과 이름 뒤에 붙는 짧은 표시 (예: 김민수 2번 (B))
  final String short;
}

/// 1단계(FLUX 마스크 채우기)를 쓰는 치료
const kPass1Treatments = {'라미네이트', '무삭제 라미네이트', '미백', '올세라믹 크라운', '임플란트'};

/// 2단계 전용 마무리 지시 (형태 변경 지시는 넣지 않음)
const kFinishPrompt =
    '입력된 이미지의 치아 외곽선, 서비컬 마진 경계선, 가로 폭과 길이, 잇몸 높이는 100% 그대로 고정할 것. '
    '형태는 절대 바꾸지 말고, 치아 표면의 자연스러운 세라믹·법랑질 광택, 절단연의 은은한 투명감, '
    '주변 자연 치아와의 이질감 없는 색조 조화 및 구강 플래시 반사광만 실제 임상 사진처럼 사실적으로 다듬을 것.';

/// Imagen 은 영어를 가장 잘 이해해서 같은 뜻의 영어를 함께 붙임
const kFinishPromptEn =
    'Keep the tooth outlines, cervical margin lines, tooth width and length, and gum height 100% unchanged. '
    'Never change the shape; only refine realistic ceramic/enamel surface gloss, subtle incisal translucency, '
    'natural color harmony with the neighboring natural teeth, and intraoral flash reflections, like a real clinical photo.';

/// 실제로 쓸 엔진과 그 이유. 교정이 있거나, 1단계 대상 치료가 없거나, 서비컬 라인이 없으면 단독으로.
({Engine engine, String? note}) effectiveEngine(
  Engine picked,
  Iterable<String> treatments,
  bool hasLines,
) {
  if (picked == Engine.solo) return (engine: Engine.solo, note: null);
  final tx = treatments.toSet();
  if (tx.contains('교정')) {
    return (
      engine: Engine.solo,
      note: '교정은 치아 위치를 옮겨야 해서 1단계(FLUX) 없이 나노바나나 단독으로 자동 전환',
    );
  }
  if (!tx.any(kPass1Treatments.contains)) {
    return (
      engine: Engine.solo,
      note: '1단계 대상 치료(라미네이트·무삭제·미백·크라운·임플란트)가 없어 나노바나나 단독으로 진행',
    );
  }
  if (!hasLines) {
    return (
      engine: Engine.solo,
      note: '서비컬 라인을 그려야 1단계 마스크를 만들 수 있어요 → 지금은 나노바나나 단독',
    );
  }
  return (engine: picked, note: null);
}

/// 진행 단계 문구
String stepMessage(Engine e, int step) {
  if (e == Engine.solo) return 'AI(나노바나나)가 After를 만드는 중… 10~30초 걸립니다';
  return step == 1
      ? '1단계: FLUX 마진·형태 설계 중... ➡️ 2단계: ${e.finisher} 리얼리즘 마무리 대기'
      : '✓ 1단계: FLUX 마진·형태 설계 완료 ➡️ 2단계: ${e.finisher} 리얼리즘 마무리 중...';
}

class PipelineError implements Exception {
  const PipelineError(this.message);
  final String message;
  @override
  String toString() => message;
}

// -----------------------------------------------------------------------------
// 설정 (키는 안드로이드 보안 저장소에, 나머지는 일반 설정에)
// -----------------------------------------------------------------------------
class PipelineSettings {
  PipelineSettings._();
  static final PipelineSettings instance = PipelineSettings._();

  static const _secure = FlutterSecureStorage();
  static const _kFal = 'pipe.falKey',
      _kVertexJson = 'pipe.vertexJson',
      _kVertexKey = 'pipe.vertexApiKey';
  static const _kEngine = 'pipe.engine',
      _kProject = 'pipe.vertexProject',
      _kLocation = 'pipe.vertexLocation',
      _kImagen = 'pipe.imagenModel',
      _kNano = 'pipe.nanoModel',
      _kNanoPro = 'pipe.nanoProModel';

  static const defaultProject = 'ai-yejundetallab';
  static const defaultLocation = 'us-central1';
  static const defaultImagen = 'imagen-3.0-capability-001';
  static const defaultNanoPro = 'gemini-3-pro-image-preview';

  Engine engine = Engine.a;
  String? falKey;
  String? vertexJson; // (고급) 서비스 계정 JSON
  String? vertexApiKey; // Vertex AI API 키 (AIzaSy…) — 기본 방식
  String vertexProject = defaultProject;
  String vertexLocation = defaultLocation;
  String imagenModel = defaultImagen;
  String nanoModel = AiService.modelId;
  String nanoProModel = defaultNanoPro;

  bool get hasFal => (falKey ?? '').trim().isNotEmpty;
  bool get hasVertexKey => (vertexApiKey ?? '').trim().isNotEmpty;
  bool get hasVertexJson => (vertexJson ?? '').trim().isNotEmpty;
  bool get hasVertex => hasVertexKey || hasVertexJson;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      engine = Engine.values.firstWhere(
        (e) => e.name == p.getString(_kEngine),
        orElse: () => Engine.a,
      );
      vertexProject = p.getString(_kProject) ?? defaultProject;
      vertexLocation = p.getString(_kLocation) ?? defaultLocation;
      imagenModel = p.getString(_kImagen) ?? defaultImagen;
      nanoModel = p.getString(_kNano) ?? AiService.modelId;
      nanoProModel = p.getString(_kNanoPro) ?? defaultNanoPro;
    } catch (_) {}
    falKey = await _get(_kFal);
    vertexJson = await _get(_kVertexJson);
    vertexApiKey = await _get(_kVertexKey);
  }

  /// 마지막 저장이 보안 저장소 대신 일반 앱 저장소로 됐는지 (보안 저장소가 고장 난 기기)
  bool savedInFallback = false;

  /// 저장: 안드로이드 보안 저장소 → 실패하거나 다시 읽어 보니 다르면 일반 앱 저장소 (그래도 이 태블릿 안에만)
  Future<void> _put(String k, String? v) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {}
    if (v == null) {
      try {
        await _secure.delete(key: k).timeout(const Duration(seconds: 5));
      } catch (_) {}
      await prefs?.remove('fb.$k');
      return;
    }
    try {
      await _secure.write(key: k, value: v).timeout(const Duration(seconds: 5));
      final back = await _secure
          .read(key: k)
          .timeout(const Duration(seconds: 5));
      if (back != v) throw StateError('read-back mismatch');
      await prefs?.remove('fb.$k');
      savedInFallback = false;
    } catch (e) {
      debugPrint('secure write failed → app storage: $e');
      if (prefs == null) {
        throw const PipelineError('키를 저장하지 못했습니다. 앱을 다시 실행해 주세요.');
      }
      await prefs.setString('fb.$k', v);
      savedInFallback = true;
    }
  }

  Future<String?> _get(String k) async {
    try {
      final v = await _secure.read(key: k).timeout(const Duration(seconds: 5));
      if (v != null && v.isNotEmpty) return v;
    } catch (e) {
      debugPrint('secure read: $e');
    }
    try {
      return (await SharedPreferences.getInstance()).getString('fb.$k');
    } catch (_) {
      return null;
    }
  }

  /// 엔진 선택: 바로 적용하고 저장은 뒤에서 (저장을 기다리지 않음)
  Future<void> setEngine(Engine e) async {
    engine = e;
    SharedPreferences.getInstance()
        .then((p) => p.setString(_kEngine, e.name))
        .catchError((_) => false)
        .ignore();
  }

  Future<void> saveFalKey(String? v) async {
    falKey = (v ?? '').trim().isEmpty ? null : v!.trim();
    await _put(_kFal, falKey);
  }

  /// Vertex AI API 키 저장 (형식 확인). 잘못되면 PipelineError.
  Future<void> saveVertexApiKey(String? v) async {
    final t = (v ?? '').trim();
    if (t.isEmpty) {
      vertexApiKey = null;
      await _put(_kVertexKey, null);
      return;
    }
    if (!RegExp(r'^AIza[0-9A-Za-z_\-]{30,}$').hasMatch(t)) {
      throw const PipelineError(
        'Google API 키 형식이 아닙니다. "AIzaSy…" 로 시작하는 키 전체를 붙여넣어 주세요.',
      );
    }
    vertexApiKey = t;
    await _put(_kVertexKey, t);
  }

  /// 서비스 계정 JSON 저장 (형식 확인 후). 잘못되면 PipelineError.
  Future<void> saveVertexJson(String? v) async {
    final t = (v ?? '').trim();
    if (t.isEmpty) {
      vertexJson = null;
      await _put(_kVertexJson, null);
      return;
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(t) as Map<String, dynamic>;
    } catch (_) {
      throw const PipelineError('JSON 형식이 아닙니다. 서비스 계정 키 파일 내용을 그대로 붙여넣어 주세요.');
    }
    if (j['type'] != 'service_account' ||
        j['private_key'] == null ||
        j['client_email'] == null) {
      throw const PipelineError(
        '서비스 계정 키(JSON)가 아닙니다. "type": "service_account" 인 키를 넣어 주세요.',
      );
    }
    vertexJson = t;
    if (j['project_id'] is String && vertexProject == defaultProject) {
      vertexProject = j['project_id'] as String;
    }
    await _put(_kVertexJson, t);
    await saveProject(
      vertexProject,
      vertexLocation,
      imagenModel,
      nanoModel,
      nanoProModel,
    );
  }

  Future<void> saveProject(
    String project,
    String location,
    String imagen,
    String nano,
    String nanoPro,
  ) async {
    vertexProject = project.trim().isEmpty ? defaultProject : project.trim();
    vertexLocation = location.trim().isEmpty
        ? defaultLocation
        : location.trim();
    imagenModel = imagen.trim().isEmpty ? defaultImagen : imagen.trim();
    nanoModel = nano.trim().isEmpty ? AiService.modelId : nano.trim();
    nanoProModel = nanoPro.trim().isEmpty ? defaultNanoPro : nanoPro.trim();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kProject, vertexProject);
      await p.setString(_kLocation, vertexLocation);
      await p.setString(_kImagen, imagenModel);
      await p.setString(_kNano, nanoModel);
      await p.setString(_kNanoPro, nanoProModel);
    } catch (_) {}
  }

  /// 화면에 보여 줄 때는 끝 4자리만
  static String masked(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return '저장 안 됨';
    return '저장됨 ●●●●${t.length > 4 ? t.substring(t.length - 4) : ''}';
  }
}

// -----------------------------------------------------------------------------
// 1단계 마스크: 서비컬 라인 사이(치아) = 흰색(새로 그림), 나머지(잇몸·입술·얼굴) = 검정(그대로)
// -----------------------------------------------------------------------------
/// 상악선만 있으면 그 아래로, 하악선만 있으면 그 위로 [band](사진 세로 비율)만큼을 치아 영역으로 봄.
img.Image? buildToothMask(
  int w,
  int h,
  List<GuideLine> lines, {
  double band = 0.2,
}) {
  List<double?> heights(bool upper) {
    final ys = List<double?>.filled(w, null);
    for (final l in lines.where((l) => l.upper == upper)) {
      for (var i = 1; i < l.pts.length; i++) {
        final a = l.pts[i - 1], b = l.pts[i];
        final ax = a.dx * (w - 1),
            ay = a.dy * (h - 1),
            bx = b.dx * (w - 1),
            by = b.dy * (h - 1);
        for (
          var x = math.max(0, math.min(ax, bx).round());
          x <= math.min(w - 1, math.max(ax, bx).round());
          x++
        ) {
          final t = (bx - ax).abs() < 1e-6
              ? 0.0
              : ((x - ax) / (bx - ax)).clamp(0.0, 1.0);
          final y = ay + (by - ay) * t;
          final cur = ys[x];
          // 상악은 가장 아래(치아 쪽), 하악은 가장 위(치아 쪽) → 잇몸을 칠하지 않게
          ys[x] = cur == null
              ? y
              : (upper ? math.max(cur, y) : math.min(cur, y));
        }
      }
    }
    return ys;
  }

  final up = heights(true), lo = heights(false);
  if (up.every((e) => e == null) && lo.every((e) => e == null)) return null;
  final m = img.Image(width: w, height: h, numChannels: 1);
  final bandPx = h * band;
  for (var x = 0; x < w; x++) {
    final u = up[x], d = lo[x];
    if (u == null && d == null) continue;
    final top = u ?? (d! - bandPx * 0.75);
    final bottom = d ?? (u! + bandPx);
    for (
      var y = math.max(0, top.ceil());
      y <= math.min(h - 1, bottom.floor());
      y++
    ) {
      m.setPixelR(x, y, 255);
    }
  }
  return m;
}

// -----------------------------------------------------------------------------
// 1단계: Fal.ai FLUX.1 Fill (fal-ai/flux-pro/v1/fill)
// -----------------------------------------------------------------------------
class FalFluxFill {
  FalFluxFill(this.key, {http.Client? client})
    : _client = client ?? http.Client();
  final String key;
  final http.Client _client;
  static final endpoint = Uri.parse('https://fal.run/fal-ai/flux-pro/v1/fill');

  /// 사진 + 마스크(흰색 = 새로 그릴 곳) + 지시 → 1차 이미지
  Future<Uint8List> fill({
    required Uint8List jpeg,
    required Uint8List maskPng,
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
            body: jsonEncode({
              'prompt': prompt,
              'image_url': 'data:image/jpeg;base64,${base64Encode(jpeg)}',
              'mask_url': 'data:image/png;base64,${base64Encode(maskPng)}',
              'num_images': 1,
              'output_format': 'jpeg',
              'safety_tolerance': '2',
              'sync_mode': true, // 결과를 바로 받음 (따로 내려받기 없음)
            }),
          )
          .timeout(const Duration(seconds: 150));
    } on TimeoutException {
      throw const PipelineError('1단계(FLUX) 응답이 너무 늦습니다. 인터넷을 확인하고 다시 시도해 주세요.');
    } catch (e) {
      throw PipelineError('1단계(FLUX)에 연결하지 못했습니다. 인터넷을 확인해 주세요. ($e)');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw const PipelineError('Fal.ai API 키가 맞지 않습니다. [AI 설정]에서 키를 확인해 주세요.');
    }
    if (r.statusCode == 402 || r.statusCode == 429) {
      throw const PipelineError(
        'Fal.ai 크레딧이 부족하거나 요청이 많습니다. Fal.ai 결제·사용량을 확인해 주세요.',
      );
    }
    if (r.statusCode != 200) {
      throw PipelineError('1단계(FLUX) 실패 (${r.statusCode}): ${_short(r.body)}');
    }
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw const PipelineError('1단계(FLUX) 응답을 읽지 못했습니다.');
    }
    if (j['has_nsfw_concepts'] is List &&
        (j['has_nsfw_concepts'] as List).contains(true)) {
      throw const PipelineError(
        '1단계(FLUX)가 사진을 처리하지 않았습니다(안전 필터). 입 주변이 잘 보이는 사진으로 다시 시도해 주세요.',
      );
    }
    final images = j['images'];
    final url = images is List && images.isNotEmpty && images.first is Map
        ? (images.first as Map)['url']
        : null;
    if (url is! String) {
      throw const PipelineError('1단계(FLUX)가 이미지를 돌려주지 않았습니다.');
    }
    if (url.startsWith('data:')) {
      return base64Decode(url.substring(url.indexOf(',') + 1));
    }
    final g = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 60));
    if (g.statusCode != 200) {
      throw const PipelineError('1단계(FLUX) 결과 이미지를 내려받지 못했습니다.');
    }
    return g.bodyBytes;
  }
}

String _short(String s) => s.length > 160 ? '${s.substring(0, 160)}…' : s;

// -----------------------------------------------------------------------------
// 2단계 옵션 C: Vertex AI Imagen 편집 (서비스 계정으로 인증 → REST 호출)
// -----------------------------------------------------------------------------
/// 인증: [apiKey](AIzaSy…, 기본) 또는 [serviceAccountJson](고급) 중 하나
class VertexImagen {
  VertexImagen({
    this.apiKey,
    this.serviceAccountJson,
    required this.project,
    required this.location,
    required this.model,
    http.Client? client,
    this.tokenOverride,
  }) : _client = client ?? http.Client();
  final String? apiKey, serviceAccountJson;
  final String project, location, model;
  final http.Client _client;
  @visibleForTesting
  final String? tokenOverride;

  /// 프로젝트 주소 (크레딧이 연결된 프로젝트로 청구)
  Uri get endpoint => Uri.parse(
    'https://$location-aiplatform.googleapis.com/v1/projects/$project/locations/$location/publishers/google/models/$model:predict',
  );

  /// API 키 간편(Express) 주소 — 프로젝트 주소가 API 키를 받지 않을 때 한 번 더 시도
  Uri get expressEndpoint => Uri.parse(
    'https://aiplatform.googleapis.com/v1/publishers/google/models/$model:predict',
  );

  Future<String> _token() async {
    if (tokenOverride != null) return tokenOverride!;
    try {
      final creds = gauth.ServiceAccountCredentials.fromJson(
        serviceAccountJson!,
      );
      final ac = await gauth.obtainAccessCredentialsViaServiceAccount(creds, [
        'https://www.googleapis.com/auth/cloud-platform',
      ], _client);
      return ac.accessToken.data;
    } catch (e) {
      throw PipelineError(
        'Vertex AI 인증에 실패했습니다. 서비스 계정 JSON과 권한(Vertex AI 사용자)을 확인해 주세요. ($e)',
      );
    }
  }

  /// 마스크(흰색) 안의 치아만 사실감 마무리 → 결과 이미지
  Future<Uint8List> refine({
    required Uint8List jpeg,
    required Uint8List maskPng,
    required String prompt,
  }) async {
    final useKey = (apiKey ?? '').trim().isNotEmpty;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (useKey)
        'x-goog-api-key': apiKey!.trim()
      else
        'Authorization': 'Bearer ${await _token()}',
    };
    final body = jsonEncode({
      'instances': [
        {
          'prompt': prompt,
          'referenceImages': [
            {
              'referenceType': 'REFERENCE_TYPE_RAW',
              'referenceId': 1,
              'referenceImage': {'bytesBase64Encoded': base64Encode(jpeg)},
            },
            {
              'referenceType': 'REFERENCE_TYPE_MASK',
              'referenceId': 2,
              'referenceImage': {'bytesBase64Encoded': base64Encode(maskPng)},
              'maskImageConfig': {
                'maskMode': 'MASK_MODE_USER_PROVIDED',
                'dilation': 0.0,
              },
            },
          ],
        },
      ],
      'parameters': {
        'editMode': 'EDIT_MODE_INPAINT_INSERTION',
        'sampleCount': 1,
      },
    });
    Future<http.Response> post(Uri u) async {
      try {
        return await _client
            .post(u, headers: headers, body: body)
            .timeout(const Duration(seconds: 120));
      } on TimeoutException {
        throw const PipelineError('2단계(Vertex AI) 응답이 너무 늦습니다.');
      } catch (e) {
        throw PipelineError('2단계(Vertex AI)에 연결하지 못했습니다. ($e)');
      }
    }

    var r = await post(endpoint);
    // API 키가 프로젝트 주소에서 거절되면(401/403/404) 간편(Express) 주소로 한 번 더
    if (useKey &&
        (r.statusCode == 401 || r.statusCode == 403 || r.statusCode == 404)) {
      final r2 = await post(expressEndpoint);
      if (r2.statusCode == 200 || r.statusCode == 404) r = r2;
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw PipelineError(
        useKey
            ? 'Vertex AI가 API 키를 받지 않았습니다. Google Cloud 콘솔에서 ① "Vertex AI API" 사용 설정, '
                  '② API 키 제한에 "Vertex AI API" 허용, ③ 프로젝트 ID($project)를 확인해 주세요. (${_short(r.body)})'
            : 'Vertex AI 권한이 없습니다. 서비스 계정에 "Vertex AI 사용자" 역할과 프로젝트 ID를 확인해 주세요.',
      );
    }
    if (r.statusCode != 200) {
      throw PipelineError(
        '2단계(Vertex AI) 실패 (${r.statusCode}): ${_short(r.body)}',
      );
    }
    final j = jsonDecode(r.body);
    final preds = j is Map ? j['predictions'] : null;
    final b64 = preds is List && preds.isNotEmpty && preds.first is Map
        ? (preds.first as Map)['bytesBase64Encoded']
        : null;
    if (b64 is! String) {
      throw const PipelineError(
        '2단계(Vertex AI)가 이미지를 돌려주지 않았습니다 (안전 필터일 수 있음).',
      );
    }
    return base64Decode(b64);
  }
}

// -----------------------------------------------------------------------------
// 실행
// -----------------------------------------------------------------------------
class TwoPassPipeline {
  TwoPassPipeline({this.client});
  final http.Client? client; // 테스트에서 가짜 서버를 넣을 때

  /// 나노바나나 Pro 후보 이름 (설정한 이름이 '모델 없음'이면 차례로 시험)
  static const proCandidates = [
    'gemini-3-pro-image',
    'gemini-3-pro-image-preview',
    'gemini-3.1-pro-image',
  ];

  /// Firebase 에 Pro 모델이 없으면 true → 바로 fal.ai 나노바나나 Pro 로
  static bool proViaFal = false;
  static String? proActive; // 연결 확인된 Pro 모델 이름

  /// 테스트용 바꿔 끼우기
  static Future<Uint8List> Function(
    String model,
    String prompt,
    Uint8List jpeg,
    List<({String label, Uint8List jpeg})> refs,
  )?
  debugGemini;
  static Future<Uint8List> Function(List<Uint8List> jpegs, String prompt)?
  debugFalPro;

  static bool _missing(Object e) {
    final t = '$e';
    return t.contains('not found') ||
        t.contains('NOT_FOUND') ||
        t.contains('does not have access') ||
        t.contains('Publisher model') ||
        t.contains('모델을 쓸 수 없습니다');
  }

  /// 옵션 B 마무리: Firebase 나노바나나 Pro → 모델이 없으면 다른 이름 → 그래도 없으면 fal.ai 나노바나나 Pro
  Future<Uint8List> proFinish(
    PipelineSettings s,
    Uint8List jpeg,
    String prompt,
    List<({String label, Uint8List jpeg})> refs,
  ) async {
    if (!proViaFal) {
      final names = <String>[
        if (proActive != null) proActive!,
        s.nanoProModel,
        ...proCandidates,
      ].toSet().toList();
      Object? last;
      for (final m in names) {
        try {
          final r = debugGemini != null
              ? await debugGemini!(m, prompt, jpeg, refs)
              : await AiService.instance.geminiImage(
                  model: m,
                  prompt: prompt,
                  jpeg: jpeg,
                  extra: refs,
                );
          proActive = m;
          return r;
        } catch (e) {
          if (!_missing(e)) rethrow; // 모델 문제가 아니면 그대로 알림
          last = e;
        }
      }
      debugPrint('나노바나나 Pro 모델 없음 → fal.ai 로: $last');
      proViaFal = true;
    }
    if (!s.hasFal && debugFalPro == null) {
      throw const PipelineError(
        '나노바나나 Pro 를 쓸 수 없어 Fal.ai 로 바꾸려 했지만 Fal.ai 키가 없습니다.',
      );
    }
    final jpegs = [jpeg, for (final r in refs) r.jpeg];
    final p = refs.isEmpty
        ? prompt
        : '$prompt\nThe first image is the photo to edit; the other images are reference only.';
    return debugFalPro != null
        ? debugFalPro!(jpegs, p)
        : FalNanoBananaEdit(
            s.falKey!,
            client: client,
            pro: true,
          ).edit(jpegs: jpegs, prompt: p);
  }

  /// [fluxPrompt]: 치료별 임상 지시 (1단계용), [lock]: 잇몸 원본 픽셀 고정에 쓸 선.
  /// 1단계가 실패하면 PipelineError, 2단계가 실패하면 1단계 결과 + [onNotice] 안내.
  Future<Uint8List> run({
    required Engine engine,
    required Uint8List before,
    required List<GuideLine> lines,
    required String fluxPrompt,
    required List<GuideLine> lock,
    required void Function(int step) onStep,
    required void Function(String msg) onNotice,
    img.Image? maskOverride, // 🪄 SAM 으로 고른 치아 마스크 (흰색 = 변환). 있으면 서비컬 라인 대신 사용
    List<({String label, Uint8List jpeg})> refs =
        const [], // 2단계 나노바나나에 함께 보낼 참고 사진
    String refPrompt = '', // 참고 사진 설명 (마무리 지시 뒤에 붙임)
  }) async {
    final s = PipelineSettings.instance;
    if (!s.hasFal) {
      throw const PipelineError(
        '1단계(FLUX)를 쓰려면 [AI 설정]에 Fal.ai API 키를 넣어 주세요.',
      );
    }
    final src = await AiService.decodePhoto(before);
    final jpeg = await AiService.photoJpeg(src);
    final small = img.decodeJpg(jpeg)!; // AI 에 보내는 크기 (마스크도 같은 크기)
    final mask = maskOverride != null
        ? img.copyResize(
            maskOverride,
            width: small.width,
            height: small.height,
            interpolation: img.Interpolation.nearest,
          )
        : buildToothMask(small.width, small.height, lines);
    if (mask == null) {
      throw const PipelineError('서비컬 라인이 없어 1단계 마스크를 만들 수 없습니다.');
    }
    final maskPng = img.encodePng(mask);

    // 1단계: FLUX — 치아 영역만 새로 (마스크 밖 잇몸·입술은 그대로)
    onStep(1);
    final pass1 = await FalFluxFill(
      s.falKey!,
      client: client,
    ).fill(jpeg: jpeg, maskPng: maskPng, prompt: fluxPrompt);

    // 2단계: 마무리 (전용 마무리 지시만)
    onStep(2);
    Uint8List finished;
    try {
      final p1 = img.decodeImage(pass1);
      final p1Jpeg = p1 == null ? pass1 : await AiService.photoJpeg(p1);
      finished = switch (engine) {
        Engine.a => await AiService.instance.geminiImage(
          model: s.nanoModel,
          prompt: refPrompt.isEmpty
              ? kFinishPrompt
              : '$kFinishPrompt\n$refPrompt',
          jpeg: p1Jpeg,
          extra: refs,
        ),
        Engine.b => await proFinish(
          s,
          p1Jpeg,
          refPrompt.isEmpty ? kFinishPrompt : '$kFinishPrompt\n$refPrompt',
          refs,
        ),
        Engine.c => await _vertex(
          s,
          p1Jpeg,
          maskPng,
          small.width,
          small.height,
        ),
        Engine.solo => pass1,
      };
    } catch (e) {
      onNotice(
        '2단계(${engine.finisher}) 마무리에 실패해 1단계(FLUX) 결과를 보여 드립니다. ${e is AiError ? e.message : e}',
      );
      finished = pass1;
    }
    // 원본 크기로 맞추고 잇몸 잠금(원본 픽셀) 적용
    return AiService.finish(src, finished, lock);
  }

  Future<Uint8List> _vertex(
    PipelineSettings s,
    Uint8List jpeg,
    Uint8List maskPng,
    int w,
    int h,
  ) async {
    if (!s.hasVertex) {
      throw const PipelineError(
        '옵션 C는 [API 키 설정] ②에 Vertex AI API 키(AIzaSy…)와 프로젝트 ID를 넣어야 합니다.',
      );
    }
    // 마스크 크기를 1단계 결과 크기에 맞춤
    final p = img.decodeJpg(jpeg);
    var m = img.decodePng(maskPng)!;
    if (p != null && (p.width != w || p.height != h)) {
      m = img.copyResize(
        m,
        width: p.width,
        height: p.height,
        interpolation: img.Interpolation.nearest,
      );
    }
    return VertexImagen(
      apiKey: s.hasVertexKey ? s.vertexApiKey : null, // API 키가 있으면 API 키 우선
      serviceAccountJson: s.hasVertexKey ? null : s.vertexJson,
      project: s.vertexProject,
      location: s.vertexLocation,
      model: s.imagenModel,
      client: client,
    ).refine(
      jpeg: jpeg,
      maskPng: img.encodePng(m),
      prompt: '$kFinishPrompt\n$kFinishPromptEn',
    );
  }
}
