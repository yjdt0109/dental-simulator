import 'package:dental_app/app_theme.dart';
import 'package:dental_app/models/clinic_profile.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:dental_app/simulator/simulator_screen.dart';
import 'package:dental_app/simulator/whitening.dart';
import 'package:dental_app/widgets/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _profile = ClinicProfile(
  clinicName: '미소드림치과',
  bizNo: '123-45-67890',
  phone: '02-1234-5678',
  zipCode: '06236',
  address: '서울특별시 강남구 테헤란로 152',
  role: '상담실장',
  provider: SocialProvider.kakao,
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
  test('미백 엔진: 노란 치아 영역만 밝아지고 노란기가 줄어듦', () {
    const w = 100, h = 60;
    final px = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = (y * w + x) * 4;
        final tooth = x > 30 && x < 70 && y > 20 && y < 40;
        px[p] = tooth ? 214 : 176;
        px[p + 1] = tooth ? 196 : 80;
        px[p + 2] = tooth ? 140 : 92;
        px[p + 3] = 255;
      }
    }
    final out = whitenPixels(
      px,
      w,
      h,
      const Rect.fromLTWH(0.1, 0.1, 0.8, 0.8),
      92,
      4,
      1,
    )!;
    final c = (30 * w + 50) * 4, lip = (5 * w + 5) * 4;
    expect(
      out[c + 2] - out[c],
      greaterThan(px[c + 2] - px[c]),
    ); // 파랑-빨강 차이 증가 = 노란기 감소
    expect(
      out[c] + out[c + 1] + out[c + 2],
      greaterThan(px[c] + px[c + 1] + px[c + 2]),
    );
    expect(
      out.sublist(lip, lip + 3),
      px.sublist(lip, lip + 3),
    ); // 입술(영역 밖·붉은색)은 그대로
  });

  test('치아 요약 문구', () {
    expect(teethSummary(sortTeeth(kUpper6.toSet())), '상악 앞니 6개');
    expect(sortTeeth({21, 11, 31}), [11, 21, 31]);
  });

  for (final size in const [Size(390, 844), Size(800, 1280), Size(1440, 900)]) {
    testWidgets('시뮬레이터: 변환 → 위아래 → 브리핑 슬라이더 → 동의 $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: const SimulatorHomeScreen(profile: _profile),
        ),
      );
      await _settle(
        t,
        until: () => find.byType(RoiEditor).evaluate().isNotEmpty,
      );
      expect(find.text('📸 촬영실 최근 등록 사진'), findsNothing); // 사진 바 없음
      expect(find.byType(RoiEditor), findsOneWidget); // 처음은 영역 지정 단계
      expect(find.textContaining('📅 '), findsOneWidget); // 상담 날짜 표시

      // 사진 위 이름 칸에 적으면 상담 가이드 이름 칸에도 그대로
      await t.enterText(find.byType(TextField).first, '김민수 환자');
      await t.pump();
      expect(find.text('김민수 환자'), findsNWidgets(2));
      await t.enterText(find.byType(TextField).first, '김민수');
      await t.pump();
      expect(t.takeException(), isNull);

      // 상담 가이드에서 변환
      await t.ensureVisible(find.text('After 변환하기'));
      await t.tap(find.text('After 변환하기'));
      await _settle(
        t,
        until: () => find.byType(StackedCompare).evaluate().isNotEmpty,
      );
      expect(find.byType(StackedCompare), findsOneWidget);
      // [이전으로] → 변환 전(Before)으로, 다시 변환하면 After
      if (size.width >= 600) {
        expect(find.text('이전으로'), findsOneWidget);
        await t.ensureVisible(find.text('이전으로'));
        await t.tap(find.text('이전으로'));
        await _settle(
          t,
          until: () => find.byType(RoiEditor).evaluate().isNotEmpty,
        );
        expect(find.byType(StackedCompare), findsNothing);
        expect(find.byType(RoiEditor), findsOneWidget);
        expect(find.text('이전으로'), findsNothing);
        await t.ensureVisible(find.text('After 변환하기'));
        await t.tap(find.text('After 변환하기'));
        await _settle(
          t,
          until: () => find.byType(StackedCompare).evaluate().isNotEmpty,
        );
        expect(find.byType(StackedCompare), findsOneWidget);
      }
      expect(find.textContaining('✓ 셰이드 A1'), findsOneWidget);

      // 셰이드 바꾸면 '다시 변환' 안내
      await t.ensureVisible(find.text('BL1'));
      await t.tap(find.text('BL1'));
      await t.pump();
      expect(find.textContaining('설정이 바뀌었습니다'), findsOneWidget);

      // 브리핑 모드 → 슬라이더
      await t.ensureVisible(find.text('🖥️ 환자 브리핑 모드'));
      await t.tap(find.text('🖥️ 환자 브리핑 모드'));
      await _settle(t);
      expect(find.byType(SliderCompare), findsOneWidget);
      final slider = find.byType(SliderCompare);
      await t.ensureVisible(slider);
      final center = t.getCenter(slider);
      await t.dragFrom(center, Offset(-t.getSize(slider).width * 0.25, 0));
      await t.pump();
      // Esc 로 종료 → 다시 위아래
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(t);
      expect(find.byType(StackedCompare), findsOneWidget);

      // 다시 변환 후 동의 완료
      await t.ensureVisible(find.text('다시 변환하기'));
      await t.tap(find.text('다시 변환하기'));
      await _settle(
        t,
        until: () => find.textContaining('✓ 셰이드 BL1').evaluate().isNotEmpty,
      );
      await t.ensureVisible(find.text('시뮬레이션 결과 저장 및 상담 완료'));
      await t.tap(find.text('시뮬레이션 결과 저장 및 상담 완료'));
      await _settle(t);
      await t.tap(find.text('저장 및 상담 완료'));
      await _settle(t);
      expect(find.text('📷 다음 환자 사진 등록'), findsOneWidget);
      expect(find.text('김민수 님 결과 저장 · 상담 완료'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
