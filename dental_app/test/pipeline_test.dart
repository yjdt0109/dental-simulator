// 2단계 파이프라인 시험: 실제 Fal.ai·Google 서버 대신 가짜 서버로 요청 모양과 응답 처리를 확인
// (아래 서비스 계정은 이 시험만을 위해 만든 가짜 키입니다. 어떤 계정과도 연결되어 있지 않습니다.)
import 'dart:convert';
import 'dart:typed_data';

import 'package:dental_app/ai/pipeline.dart';
import 'package:dental_app/ai/prompt_engine.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

const fakeServiceAccount =
    r'''{"type": "service_account", "project_id": "test-project", "private_key_id": "x", "private_key": "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCPYxuiV3u2fLNs\nkFtpeV/y6frTVaWNy+uSTnGznpTF6p6rXopJhiRIYSDVYT0QnW3qsBo4VXv+Lfku\n8tbV2iAZENXRjpzqoISLRi3IK7rdmgprQnmSH5P3484i25Y4LsBqa4SQ3DgwK7mH\nTJnApZL3ga//Zkx03+4SsytmWTI9kQ45YFG62QZWpwC2ggHy3jvI4awQ20LSB+qN\naWAYc+XmDzLH40Nixp/VZqjbsO0kkjai5/wrEBVn01202akdwkvZcNWTeHErcyWf\nNtPH47tGiWTkSRxu5nRek+m/dZLeTadK59oQUiY8CjSsdJKe8YClyxSPFGAlWUwt\n1v4Ur8rnAgMBAAECggEAEZQaZrAn9ArcqlIWStt89lhWDkOhPL2Dv1eLm/Q0lAD7\n+9FmzbW6y/7QWiiGJnvOZme5hy9/uH0lX+qYiPYpWjlUpVDBDwinxzVO1ov56EIC\nxfyLz+y8JLdSZbaa939Pypwsz9+XqdwqbhpnfRUva9WD4KFHfUqYssUxbGZCAQcR\nAg+bMDR2m9slzcGm+1tzvxeprAyddjkW/nf1fZqeDxnJzcLc4tVsTr/hr4apFzpQ\nmpaY7/U+hE0k4i2P49q7njlPOH0mpR9xPOHsLHdxqaZWvaSh8nPrUwZ5+3bNyB/K\nOQMyEBFuBwE1lLgcSjphraqADEm594qTvjU3WNZyNQKBgQDFlxq80C2KhzUpThsZ\n0WiAb6a1jmgg0e84BV106lUhtz2a7f8Vfx6U6tSEax6m8bsC6Hl4fYgqLYYeDZ3O\nFHUHCMYUmZa46TxNbTAKgEsdYLAuVEImAiWC9JCviAJNmr5thc6qx+rUI0+Efjr+\n6mUpahWa/sUG11YCgv15dPn1ywKBgQC5xh0Tj4GTByoIs8pPego9dUGhNOco+8Ly\nv6X1rUfEr4xoFmi0/xB3wN9lL/2lvfzSO1dhnW89+TOLqsnJDXS7RAML/LCRRBt2\nispjj9dBKKX7SGd0oTxSdBJUfTx1haf4yt48i5H3OgCPZW/Kd13XHLuV7ZxeWK92\n0tKWESG71QKBgA12MwMkJ8YlWhDbWmtS4gzGDpSWBDAgPW0SqIBbqrsmUdMpXdSo\nGXxJ13rCFY+ILpaPIh98ZfeBrH6FrPeqWyLEjUJACI3Gji40Py6n+PYibT5qzSrr\nwISAhw7+dDG3Vjv9/suR3UTgtv0u4HQXohbFPH2X1/KUXy7Cn+RTfOgrAoGBALVW\ncWN6nVzLjXhZJ45U7lH3d0zIuywCNNWHxZP+xSN0yHWCCktC/uwmVOoM4mc7AOKm\nEjGy37d63Znj6HxcqilxxheZXTEvbi9UYyK0ccWkzABxOKtcB+nka1AVv0JoaQIt\n5KjtBFpzP8C5n1nfEra70VAUVKKzpvMx72WU63zRAoGAQPPnaNGy9bJOLly7r0bN\nYCIKszUs5Bp3K3fiFHJKwQg2boj/wLvVoNkCg8t4yW/7jZFUoQFShVkcQVTw3XDQ\nU0ATwfFQZGb5uyzudB8pRu5K6cNrmIYPMh2Thv3dLmeZZ3FqsRQdxXrWOt42CAU2\nvWHJKFi7gi5T7OeMEJP20XA=\n-----END PRIVATE KEY-----\n", "client_email": "tester@test-project.iam.gserviceaccount.com", "client_id": "1", "token_uri": "https://oauth2.googleapis.com/token"}''';

final upper = GuideLine(
  upper: true,
  pts: const [Offset(0.1, 0.35), Offset(0.5, 0.38), Offset(0.9, 0.35)],
);
final lower = GuideLine(
  upper: false,
  pts: const [Offset(0.1, 0.75), Offset(0.5, 0.72), Offset(0.9, 0.75)],
);

String jpegData(int r, int g, int b, {int w = 400, int h = 300}) =>
    'data:image/jpeg;base64,${base64Encode(img.encodeJpg(img.Image(width: w, height: h)..clear(img.ColorRgb8(r, g, b))))}';
String jpegB64(int r, int g, int b, {int w = 400, int h = 300}) => base64Encode(
  img.encodeJpg(img.Image(width: w, height: h)..clear(img.ColorRgb8(r, g, b))),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  apiKeyTests();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('2단계 마무리 지시: 요청하신 문장 그대로', () {
    expect(
      kFinishPrompt,
      '입력된 이미지의 치아 외곽선, 서비컬 마진 경계선, 가로 폭과 길이, 잇몸 높이는 100% 그대로 고정할 것. '
      '형태는 절대 바꾸지 말고, 치아 표면의 자연스러운 세라믹·법랑질 광택, 절단연의 은은한 투명감, '
      '주변 자연 치아와의 이질감 없는 색조 조화 및 구강 플래시 반사광만 실제 임상 사진처럼 사실적으로 다듬을 것.',
    );
    // 형태 변경 지시가 섞이지 않음
    expect(kFinishPrompt, isNot(contains('정돈')));
    expect(kFinishPrompt, isNot(contains('정렬')));
  });

  group('엔진 자동 전환', () {
    test('교정 → 나노바나나 단독 (1단계 없음)', () {
      final e = effectiveEngine(Engine.b, {'라미네이트', '교정'}, true);
      expect(e.engine, Engine.solo);
      expect(e.note, contains('교정'));
    });
    test('1단계 대상 치료 5가지는 선택한 옵션 그대로', () {
      for (final t in kPass1Treatments) {
        expect(
          effectiveEngine(Engine.c, {t}, true).engine,
          Engine.c,
          reason: t,
        );
      }
    });
    test('잇몸 성형만 / 서비컬 라인 없음 → 단독', () {
      expect(effectiveEngine(Engine.a, {'잇몸 성형'}, true).engine, Engine.solo);
      expect(
        effectiveEngine(Engine.a, {'라미네이트'}, false).note,
        contains('서비컬 라인'),
      );
    });
    test('진행 단계 문구', () {
      expect(
        stepMessage(Engine.b, 1),
        '1단계: FLUX 마진·형태 설계 중... ➡️ 2단계: 나노바나나 Pro 리얼리즘 마무리 대기',
      );
      expect(
        stepMessage(Engine.b, 2),
        contains('2단계: 나노바나나 Pro 리얼리즘 마무리 중...'),
      );
      expect(stepMessage(Engine.c, 2), contains('Vertex AI Imagen'));
      expect(stepMessage(Engine.a, 2), contains('나노바나나 2.1'));
    });
  });

  test('1단계 마스크: 상악선~하악선 사이(치아)만 흰색, 잇몸·입술은 검정', () {
    final m = buildToothMask(400, 300, [upper, lower])!;
    int v(int x, int y) => m.getPixel(x, y).r.toInt();
    expect(v(200, 160), 255); // 치아
    expect(v(200, 90), 0); // 상악 잇몸
    expect(v(200, 260), 0); // 하악 잇몸
    expect(v(10, 160), 0); // 선이 없는 가로 범위
    // 상악선만 있으면 그 아래 일정 높이만
    final only = buildToothMask(400, 300, [upper])!;
    expect(only.getPixel(200, 140).r.toInt(), 255);
    expect(only.getPixel(200, 250).r.toInt(), 0);
    expect(buildToothMask(400, 300, const []), isNull);
  });

  test('FLUX 지시: 1단계 대상 치료의 영어 지시 + 기존 임상 지시 원문', () {
    final p = ClinicalPrompt.fluxPrompt(
      treatments: {'무삭제 라미네이트', '교정', '미백'},
      teeth: const [11, 21],
      shade: 'A1',
    );
    expect(p, contains('Redraw ONLY the masked tooth area'));
    expect(p, contains('no-prep additive-only veneers'));
    expect(p, contains(ClinicalPrompt.clinical['무삭제 라미네이트']!));
    expect(p, contains(ClinicalPrompt.clinical['미백']!));
    expect(p, isNot(contains(ClinicalPrompt.clinical['교정']!))); // 교정은 1단계 대상 아님
    expect(p, contains('VITA A1'));
  });

  group('Fal.ai FLUX.1 Fill 요청', () {
    test('주소·인증 헤더·사진·마스크·sync_mode, 결과(data URI) 읽기', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'images': [
              {'url': jpegData(0, 0, 200)},
            ],
            'has_nsfw_concepts': [false],
          }),
          200,
        );
      });
      final out = await FalFluxFill('KEY123', client: client).fill(
        jpeg: base64Decode(jpegB64(200, 0, 0)),
        maskPng: img.encodePng(buildToothMask(400, 300, [upper, lower])!),
        prompt: 'P',
      );
      expect(seen.url.toString(), 'https://fal.run/fal-ai/flux-pro/v1/fill');
      expect(seen.headers['Authorization'], 'Key KEY123');
      final body = jsonDecode(seen.body) as Map;
      expect(body['prompt'], 'P');
      expect(
        (body['image_url'] as String).startsWith('data:image/jpeg;base64,'),
        isTrue,
      );
      expect(
        (body['mask_url'] as String).startsWith('data:image/png;base64,'),
        isTrue,
      );
      expect(body['sync_mode'], true);
      expect(img.decodeJpg(out)!.getPixel(10, 10).b, greaterThan(150));
    });
    test('결과가 https 주소면 내려받기', () async {
      final client = MockClient((req) async {
        if (req.method == 'POST') {
          return http.Response(
            jsonEncode({
              'images': [
                {'url': 'https://v3.fal.media/files/x.jpg'},
              ],
            }),
            200,
          );
        }
        expect(req.url.host, 'v3.fal.media');
        return http.Response.bytes(base64Decode(jpegB64(0, 200, 0)), 200);
      });
      final out = await FalFluxFill('K', client: client).fill(
        jpeg: base64Decode(jpegB64(1, 1, 1)),
        maskPng: [1, 2, 3].toBytes(),
        prompt: 'p',
      );
      expect(img.decodeJpg(out)!.getPixel(5, 5).g, greaterThan(150));
    });
    test('키 오류(401) → 알기 쉬운 안내', () async {
      final client = MockClient(
        (_) async => http.Response('{"detail":"bad key"}', 401),
      );
      expect(
        () => FalFluxFill(
          'bad',
          client: client,
        ).fill(jpeg: [1].toBytes(), maskPng: [1].toBytes(), prompt: 'p'),
        throwsA(
          isA<PipelineError>().having(
            (e) => e.message,
            'message',
            contains('Fal.ai API 키'),
          ),
        ),
      );
    });
  });

  test('Vertex AI Imagen 편집 요청: 서비스 계정으로 토큰 받기 → 주소·사진·마스크·편집 방식', () async {
    final seen = <http.Request>[];
    final client = MockClient((req) async {
      seen.add(req);
      if (req.url.host == 'oauth2.googleapis.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'TOKEN-1',
            'expires_in': 3600,
            'token_type': 'Bearer',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'predictions': [
            {
              'bytesBase64Encoded': jpegB64(0, 200, 0),
              'mimeType': 'image/jpeg',
            },
          ],
        }),
        200,
      );
    });
    final out =
        await VertexImagen(
          serviceAccountJson: fakeServiceAccount,
          project: 'test-project',
          location: 'us-central1',
          model: 'imagen-3.0-capability-001',
          client: client,
        ).refine(
          jpeg: base64Decode(jpegB64(200, 0, 0)),
          maskPng: [1, 2].toBytes(),
          prompt: kFinishPrompt,
        );
    expect(seen.first.url.host, 'oauth2.googleapis.com'); // 서비스 계정 JWT → 토큰
    final call = seen.last;
    expect(
      call.url.toString(),
      'https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google/models/imagen-3.0-capability-001:predict',
    );
    expect(call.headers['Authorization'], 'Bearer TOKEN-1');
    final body = jsonDecode(call.body) as Map;
    final refs = (body['instances'] as List).first['referenceImages'] as List;
    expect(refs.map((r) => r['referenceType']), [
      'REFERENCE_TYPE_RAW',
      'REFERENCE_TYPE_MASK',
    ]);
    expect(refs[1]['maskImageConfig']['maskMode'], 'MASK_MODE_USER_PROVIDED');
    expect(body['parameters']['editMode'], 'EDIT_MODE_INPAINT_INSERTION');
    expect((body['instances'] as List).first['prompt'], kFinishPrompt);
    expect(img.decodeJpg(out)!.getPixel(3, 3).g, greaterThan(150));
  });

  test('설정: 키는 보안 저장소에, 서비스 계정 JSON 형식 확인', () async {
    final s = PipelineSettings.instance;
    await s.saveFalKey('  abc:defg  ');
    expect(s.falKey, 'abc:defg');
    expect(PipelineSettings.masked(s.falKey), '저장됨 ●●●●defg');
    expect(
      await const FlutterSecureStorage().read(key: 'pipe.falKey'),
      'abc:defg',
    );
    await expectLater(
      s.saveVertexJson('not json'),
      throwsA(isA<PipelineError>()),
    );
    await expectLater(
      s.saveVertexJson('{"type":"user"}'),
      throwsA(isA<PipelineError>()),
    );
    await s.saveVertexJson(fakeServiceAccount);
    expect(s.hasVertex, isTrue);
    expect(s.vertexProject, 'test-project'); // JSON 의 프로젝트 ID 자동 사용
    await s.saveFalKey(null);
    expect(s.hasFal, isFalse);
    expect(await const FlutterSecureStorage().read(key: 'pipe.falKey'), isNull);
  });

  testWidgets('전체 흐름 (옵션 C): 1단계 FLUX → 2단계 Vertex → 잇몸은 원본, 치아는 2단계 결과', (
    t,
  ) async {
    final s = PipelineSettings.instance;
    await t.runAsync(() async {
      await s.saveFalKey('KEY');
      await s.saveVertexJson(fakeServiceAccount);
    });
    final steps = <int>[];
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add(req.url.host);
      if (req.url.host == 'fal.run') {
        return http.Response(
          jsonEncode({
            'images': [
              {'url': jpegData(0, 0, 200)},
            ],
          }),
          200,
        ); // 1단계: 파랑
      }
      if (req.url.host == 'oauth2.googleapis.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'T',
            'expires_in': 3600,
            'token_type': 'Bearer',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'predictions': [
            {'bytesBase64Encoded': jpegB64(0, 200, 0)},
          ],
        }),
        200,
      ); // 2단계: 초록
    });
    final before = img.encodePng(
      img.Image(width: 400, height: 300)..clear(img.ColorRgb8(200, 0, 0)),
    ); // 원본: 빨강
    String? notice;
    final out = await t.runAsync(
      () => TwoPassPipeline(client: client).run(
        engine: Engine.c,
        before: before,
        lines: [upper, lower],
        fluxPrompt: 'P',
        lock: [upper, lower],
        onStep: steps.add,
        onNotice: (m) => notice = m,
      ),
    );
    expect(steps, [1, 2]);
    expect(calls, [
      'fal.run',
      'oauth2.googleapis.com',
      'us-central1-aiplatform.googleapis.com',
    ]);
    expect(notice, isNull);
    final o = img.decodeJpg(out!)!;
    expect(o.getPixel(200, 50).r, greaterThan(150)); // 상악 잇몸 = 원본(빨강) 고정
    expect(o.getPixel(200, 160).g, greaterThan(150)); // 치아 = 2단계 결과(초록)
    expect(o.getPixel(200, 285).r, greaterThan(150)); // 하악 잇몸 = 원본

    // 2단계 실패 → 1단계 결과(파랑) + 안내
    final failing = MockClient((req) async {
      if (req.url.host == 'fal.run') {
        return http.Response(
          jsonEncode({
            'images': [
              {'url': jpegData(0, 0, 200)},
            ],
          }),
          200,
        );
      }
      if (req.url.host == 'oauth2.googleapis.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'T',
            'expires_in': 3600,
            'token_type': 'Bearer',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{"error":"boom"}', 500);
    });
    final out2 = await t.runAsync(
      () => TwoPassPipeline(client: failing).run(
        engine: Engine.c,
        before: before,
        lines: [upper, lower],
        fluxPrompt: 'P',
        lock: [upper, lower],
        onStep: (_) {},
        onNotice: (m) => notice = m,
      ),
    );
    expect(notice, contains('1단계(FLUX) 결과'));
    expect(img.decodeJpg(out2!)!.getPixel(200, 160).b, greaterThan(150));

    // Fal 키가 없으면 1단계 전에 안내
    await t.runAsync(() => s.saveFalKey(null));
    Object? err;
    await t.runAsync(() async {
      try {
        await TwoPassPipeline(client: client).run(
          engine: Engine.a,
          before: before,
          lines: [upper],
          fluxPrompt: 'P',
          lock: const [],
          onStep: (_) {},
          onNotice: (_) {},
        );
      } catch (e) {
        err = e;
      }
    });
    expect(
      err,
      isA<PipelineError>().having(
        (e) => e.message,
        'm',
        contains('Fal.ai API 키'),
      ),
    );
  });
}

void apiKeyTests() {
  group('Vertex AI API 키 방식 (AIzaSy… + 프로젝트 ID)', () {
    const key = 'AIzaSyTEST-key_0123456789abcdefghijklm';
    test('헤더 x-goog-api-key, 서비스 계정 로그인 없음, 프로젝트 주소로 청구', () async {
      final seen = <http.Request>[];
      final client = MockClient((req) async {
        seen.add(req);
        return http.Response(
          jsonEncode({
            'predictions': [
              {'bytesBase64Encoded': jpegB64(0, 200, 0)},
            ],
          }),
          200,
        );
      });
      final out =
          await VertexImagen(
            apiKey: key,
            project: 'project-4bd0de84-7f97-49cd-8bb',
            location: 'us-central1',
            model: 'imagen-3.0-capability-001',
            client: client,
          ).refine(
            jpeg: base64Decode(jpegB64(200, 0, 0)),
            maskPng: [1, 2].toBytes(),
            prompt: kFinishPrompt,
          );
      expect(seen, hasLength(1)); // 토큰 받기(oauth) 없음
      expect(
        seen.single.url.toString(),
        'https://us-central1-aiplatform.googleapis.com/v1/projects/project-4bd0de84-7f97-49cd-8bb/locations/us-central1/publishers/google/models/imagen-3.0-capability-001:predict',
      );
      expect(seen.single.headers['x-goog-api-key'], key);
      expect(seen.single.headers.containsKey('Authorization'), isFalse);
      expect(img.decodeJpg(out)!.getPixel(2, 2).g, greaterThan(150));
    });
    test('프로젝트 주소가 API 키를 거절(401)하면 간편(Express) 주소로 한 번 더', () async {
      final urls = <String>[];
      final client = MockClient((req) async {
        urls.add(req.url.host);
        if (req.url.host.startsWith('us-central1')) {
          return http.Response('{"error":{"code":401}}', 401);
        }
        return http.Response(
          jsonEncode({
            'predictions': [
              {'bytesBase64Encoded': jpegB64(0, 200, 0)},
            ],
          }),
          200,
        );
      });
      await VertexImagen(
        apiKey: key,
        project: 'p',
        location: 'us-central1',
        model: 'm',
        client: client,
      ).refine(jpeg: [1].toBytes(), maskPng: [1].toBytes(), prompt: 'p');
      expect(urls, [
        'us-central1-aiplatform.googleapis.com',
        'aiplatform.googleapis.com',
      ]);
    });
    test('둘 다 거절되면 해결 방법 안내', () async {
      final client = MockClient(
        (_) async =>
            http.Response('{"error":{"message":"API key not valid"}}', 403),
      );
      expect(
        () => VertexImagen(
          apiKey: key,
          project: 'p',
          location: 'us-central1',
          model: 'm',
          client: client,
        ).refine(jpeg: [1].toBytes(), maskPng: [1].toBytes(), prompt: 'p'),
        throwsA(
          isA<PipelineError>().having(
            (e) => e.message,
            'm',
            contains('"Vertex AI API" 사용 설정'),
          ),
        ),
      );
    });
    test('설정: API 키 형식 확인·저장, API 키가 있으면 옵션 C 준비됨', () async {
      final s = PipelineSettings.instance;
      await s.saveVertexJson(null);
      await expectLater(
        s.saveVertexApiKey('not-a-key'),
        throwsA(isA<PipelineError>()),
      );
      await s.saveVertexApiKey('  $key  ');
      expect(s.vertexApiKey, key);
      expect(s.hasVertex, isTrue);
      expect(
        await const FlutterSecureStorage().read(key: 'pipe.vertexApiKey'),
        key,
      );
      await s.saveVertexApiKey(null);
      expect(s.hasVertex, isFalse);
    });
  });
}

extension on List<int> {
  Uint8List toBytes() => Uint8List.fromList(this);
}
