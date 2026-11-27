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
  testWidgets('🆕 시뮬레이터를 열면 예시 사진 없이 빈 화면 (1단계)', (t) async {
    debugStepFlowOff = false;
    debugSamplePhotos = false;
    addTearDown(() {
      debugStepFlowOff = true;
      debugSamplePhotos = true;
    });
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile),
      ),
    );
    await _settle(t, until: () => find.text('1. 사진 넣기').evaluate().isNotEmpty);
    expect(find.textContaining('김민수'), findsNothing);
    expect(find.textContaining('예시'), findsNothing);
    expect(find.text('눌러서 사진 넣기 (촬영·갤러리)'), findsNWidgets(2));
    expect(t.takeException(), isNull);
  });

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
    for (final s in ['사진', '치료 정하기', 'After 만들기', '다듬기', 'Final Smile', '저장']) {
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
    // 다음 → 2단계 (치아 고르기 단계는 없음)
    expect(find.text('다음: 치아 고르기'), findsNothing);
    await t.tap(find.text('다음: 치료 정하기'));
    await _settle(t);
    expect(find.text('2. 치료 정하기'), findsOneWidget);
    expect(find.text('치료 항목'), findsOneWidget);
    expect(find.text('상담 메모'), findsNothing); // 메모는 마지막 저장 단계에
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
    expect(find.text('3. After 만들기'), findsOneWidget);
    expect(find.text('✨ After 만들기'), findsOneWidget); // 간단한 3단계
    expect(find.textContaining('엔진:'), findsNothing); // 엔진 설명 글 없음
    expect(find.textContaining('기준 사진 고르기'), findsOneWidget);
    expect(find.text('AI 시뮬레이션 엔진'), findsNothing); // 엔진 목록은 ⚙ 고급에
    // ⚙ 고급 열고 닫기
    await t.tap(find.text('⚙ 고급'));
    await _settle(t);
    expect(find.text('⚙ 고급 설정'), findsOneWidget);
    expect(find.text('🔑 API 키 · 모델 설정'), findsOneWidget);
    await t.tap(find.text('닫고 3단계로'));
    await _settle(t);
    expect(find.text('⚙ 고급 설정'), findsNothing);
    // 위쪽: 자동 QA·보관함 버튼은 없고 🧪 전문가 메뉴 안에
    expect(find.text('🤖 자동 QA'), findsNothing);
    await t.tap(find.byTooltip('🧪 전문가'));
    await _settle(t);
    expect(find.text('🤖 자동 QA'), findsOneWidget);
    expect(find.text('예전 화면으로 (모든 기능)'), findsOneWidget);
    await t.tapAt(const Offset(5, 450)); // 메뉴 닫기
    await _settle(t);
    send({'t': 'convert'});
    await _settle(
      t,
      until: () => find.textContaining('정하늘 After 1').evaluate().isNotEmpty,
    );
    expect(find.textContaining('정하늘 After 1'), findsWidgets);
    expect(find.textContaining('비교할 사진'), findsOneWidget); // 3단계부터 목록
    // 🔁 기준 사진: 고를 수 있는 사진(원본 2·원본 1·After 1) → PC 에서 After 1 고르기
    await t.tap(find.textContaining('기준 사진 고르기'));
    await _settle(t);
    expect(find.text('원본 2 (개구기)'), findsWidgets);
    expect(find.text('원본 1 (미소)'), findsWidgets);
    await t.tapAt(const Offset(5, 5)); // 닫기
    await _settle(t);
    send({
      't': 'basePick',
      'v': {'k': 2, 'n': 1},
    });
    await _settle(t);
    expect(find.textContaining('정하늘 After 1  ▾'), findsOneWidget);
    // 저장 단계로 바로
    send({'t': 'step', 'v': 6});
    await _settle(t);
    expect(find.text('6. 저장'), findsOneWidget);
    expect(find.text('상담 메모'), findsOneWidget);
    expect(find.text('정하늘 님'), findsWidgets);
    expect(find.text('＋ 새 작업'), findsWidgets);
    // 💾 저장·상담 완료(잠김) 뒤에도 PC ＋ 새 작업 → 빈 1단계
    send({'t': 'confirmSave'});
    await _settle(t);
    expect(find.textContaining('이미 저장'), findsNothing);
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
    // 폰: 위 단계 표시줄(1 사진 › 2 › …)·사진 아래 🪄 도구 줄 없음
    expect(find.text('1 사진'), findsNothing);
    expect(
      find.byTooltip('🪄 탭 한 번 자동 선택 (SAM) — 치아를 탭하면 윤곽을 자동으로 찾아요 (다시 탭하면 빠짐)'),
      findsNothing,
    );
    for (var k = 2; k <= 6; k++) {
      CastService.instance.onRemoteCmd!({'t': 'step', 'v': k});
      await _settle(t);
      expect(find.textContaining('$k. '), findsWidgets, reason: '$k');
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('🆕 PC 왼쪽 목록의 사진을 원본 1 로 넣기', (t) async {
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
    expect(find.text('눌러서 사진 넣기 (촬영·갤러리)'), findsOneWidget); // 원본 1 비어 있음
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd!({
        't': 'extraPhoto',
        'v': base64Encode(jpg(150, w: 160, h: 120)),
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      CastService.instance.onRemoteCmd!({
        't': 'slotFromList',
        'v': {'s': 1, 'n': 1},
      });
      await Future<void>.delayed(const Duration(milliseconds: 900));
    });
    await _settle(t);
    expect(find.text('눌러서 사진 넣기 (촬영·갤러리)'), findsNothing); // 원본 1 채워짐
    expect(t.takeException(), isNull);
  });
}
