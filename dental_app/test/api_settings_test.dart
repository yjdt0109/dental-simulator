import 'package:dental_app/ai/ai_settings_sheet.dart';
import 'package:dental_app/ai/pipeline.dart';
import 'package:dental_app/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  for (final size in const [Size(390, 844), Size(800, 1280)]) {
    testWidgets(
      'API 키 설정: 휴대폰·태블릿 화면 맨 위에 Fal.ai 칸 → 붙여넣기 → 저장 → 바로 확인 $size',
      (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.runAsync(() => PipelineSettings.instance.saveFalKey(null));
        // 클립보드에 키가 복사돼 있다고 가정
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              return {'text': '  test-key-id:abcd1234  '};
            }
            return null;
          },
        );
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () => showAiSettingsSheet(ctx),
                    child: const Text('열기'),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('열기'));
        await t.pumpAndSettle();
        // 맨 위에 Fal.ai 칸 (스크롤 없이 보임)
        final field = find.byKey(const ValueKey('falField'));
        expect(field, findsOneWidget);
        expect(t.getRect(field).bottom, lessThan(size.height)); // 화면 안에 보임
        expect(find.text('Fal.ai 키: 저장 안 됨'), findsOneWidget);
        // 빈 칸으로 저장 → 시트 안에 안내
        await t.tap(find.text('Fal.ai 키 저장'));
        await t.pump();
        expect(find.text('키를 붙여넣은 뒤 [저장]을 눌러 주세요.'), findsOneWidget);
        // 📋 붙여넣기 → 저장
        await t.tap(find.text('붙여넣기').first);
        await t.pump();
        await t.runAsync(() async {
          await t.tap(find.text('Fal.ai 키 저장'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await t.pump();
        expect(PipelineSettings.instance.falKey, 'test-key-id:abcd1234');
        expect(
          find.textContaining('✓ 저장했습니다: 저장됨 ●●●●1234'),
          findsOneWidget,
        ); // 시트 안에 바로 보임
        expect(find.text('Fal.ai 키: 저장됨 ●●●●1234'), findsOneWidget);
        // 다시 열어도 저장돼 있음
        await t.runAsync(() => PipelineSettings.instance.load());
        expect(PipelineSettings.instance.falKey, 'test-key-id:abcd1234');
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      },
    );
  }

  testWidgets('보안 저장소가 고장 나도 앱 저장소에 저장되고 다시 읽힘', (t) async {
    // 쓰기·읽기가 항상 실패하는 기기 흉내
    final old = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = _BrokenStorage();
    addTearDown(() => FlutterSecureStoragePlatform.instance = old);
    final s = PipelineSettings.instance;
    await t.runAsync(() => s.saveFalKey('fallback-key-9999'));
    expect(s.savedInFallback, isTrue);
    s.falKey = null;
    await t.runAsync(() => s.load());
    expect(s.falKey, 'fallback-key-9999');
  });
}

class _BrokenStorage extends FlutterSecureStoragePlatform {
  Never _fail() => throw PlatformException(
    code: 'KeystoreError',
    message: 'broken keystore',
  );
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => _fail();
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => _fail();
  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _fail();
  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => _fail();
  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => _fail();
  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _fail();
}
