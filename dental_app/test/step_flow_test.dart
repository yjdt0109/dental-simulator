import 'dart:convert';
import 'dart:typed_data';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/cast/cast_service.dart';
import 'package:dental_app/models/clinic_profile.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:dental_app/simulator/simulator_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const _profile = ClinicProfile(
  clinicName: '미소드림치과',
  bizNo: '-',
  phone: '-',
  zipCode: '-',
  address: '-',
  role: '원장',
  provider: null,
);

Uint8List jpg(int r, {int w = 120, int h = 90}) => Uint8List.fromList(
  img.encodeJpg(
    img.Image(width: w, height: h)..clear(img.ColorRgb8(r, 90, 90)),
  ),
);

Future<void> _settle(WidgetTester t, {bool Function()? until}) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump(const Duration(milliseconds: 500));
    if (until == null ? i >= 4 : until()) return;
  }
}

void main() {
  test('사진 돌리기: 가로 120×90 → 세로 90×120, 옆으로 누운(EXIF) 사진 바로 세우기', () {
    final r = img.decodeJpg(rotatePhoto(jpg(100), 1))!;
    expect([r.width, r.height], [90, 120]);
    final l = img.decodeJpg(rotatePhoto(jpg(100), -1))!;
    expect([l.width, l.height], [90, 120]);
    final im = img.Image(width: 120, height: 90)
      ..clear(img.ColorRgb8(50, 50, 50));
    im.exif.imageIfd.orientation = 6; // 90° 돌려서 봐야 하는 사진
    final fixed = img.decodeJpg(
      normalizeOrientation(Uint8List.fromList(img.encodeJpg(im))),
    )!;
    expect([fixed.width, fixed.height], [90, 120]);
    final plain = jpg(10);
    expect(
      identical(normalizeOrientation(plain), plain),
      isTrue,
    ); // 바꿀 게 없으면 그대로
  });

  testWidgets('🆕 단계 화면: 사진 → 치료 → After → 저장 → ＋ 새 작업', (t) async {
    debugStepFlowOff = false;
    addTearDown(() => debugStepFlowOff = true);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile),
      ),
    );
    await _settle(t, until: () => find.byType(RoiEditor).evaluate().isNotEmpty);
    // 단계 표시줄 + 1단계
    for (final s in [
      '사진',
      '치아 고르기',
      '치료 정하기',
      'After 만들기',
      '다듬기',
      'Final Smile',
      '저장',
    ]) {
      expect(find.textContaining(s), findsWidgets, reason: s);
    }
    expect(find.text('1. 사진 넣기'), findsOneWidget);
    expect(find.text('원본 2 · 개구기'), findsOneWidget);
    expect(find.text('원본 1 · 자연스러운 미소'), findsOneWidget);
    expect(find.byTooltip('오른쪽으로 돌리기'), findsWidgets);
    // PC 에서 원본 1 넣고 돌리기
    final send = CastService.instance.onRemoteCmd!;
    await t.runAsync(() async {
      send({
        't': 'slotPhoto',
        'v': {'s': 1, 'b': base64Encode(jpg(150, w: 160, h: 120))},
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      send({
        't': 'slotRotate',
        'v': {'s': 1, 'd': 1},
      });
      await Future<void>.delayed(const Duration(milliseconds: 900));
    });
    await _settle(t);
    // 다음 → 2 → 3단계
    await t.tap(find.text('다음: 치아 고르기'));
    await _settle(t);
    expect(find.text('2. 치아 고르기'), findsOneWidget);
    await t.tap(find.text('다음: 치료 정하기'));
    await _settle(t);
    expect(find.text('3. 치료 정하기'), findsOneWidget);
    expect(find.text('치료 항목'), findsOneWidget);
    send({'t': 'clearTeeth'});
    send({
      't': 'group',
      'v': [13, 12, 11, 21, 22, 23],
    });
    send({'t': 'tx', 'v': '미백'});
    send({'t': 'shade', 'v': 'B1'});
    send({'t': 'name', 'v': '정하늘'});
    await t.pump();
    await t.tap(find.text('다음: After 만들기'));
    await _settle(t);
    expect(find.text('4. After 만들기'), findsOneWidget);
    send({'t': 'convert'});
    await _settle(
      t,
      until: () => find.textContaining('정하늘 After 1').evaluate().isNotEmpty,
    );
    expect(find.textContaining('정하늘 After 1'), findsWidgets);
    expect(find.textContaining('비교할 사진'), findsOneWidget); // 4단계부터 목록
    // 저장 단계로 바로
    send({'t': 'step', 'v': 7});
    await _settle(t);
    expect(find.text('7. 저장'), findsOneWidget);
    expect(find.text('정하늘 님'), findsWidgets);
    expect(find.text('＋ 새 작업'), findsWidgets);
    // ＋ 새 작업 → 빈 1단계
    send({'t': 'newCase'});
    await _settle(t);
    expect(find.text('1. 사진 넣기'), findsOneWidget);
    expect(find.text('눌러서 사진 넣기 (촬영·갤러리)'), findsNWidgets(2));
    expect(t.takeException(), isNull);
  });

  testWidgets('🆕 단계 화면 (폰 크기)도 넘치지 않음', (t) async {
    debugStepFlowOff = false;
    addTearDown(() => debugStepFlowOff = true);
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile),
      ),
    );
    await _settle(t, until: () => find.byType(RoiEditor).evaluate().isNotEmpty);
    expect(find.text('1. 사진 넣기'), findsOneWidget);
    for (var k = 2; k <= 7; k++) {
      CastService.instance.onRemoteCmd!({'t': 'step', 'v': k});
      await _settle(t);
      expect(find.textContaining('$k. '), findsWidgets, reason: '$k');
    }
    expect(t.takeException(), isNull);
  });
}
