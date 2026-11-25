import 'package:dental_app/app_theme.dart';
import 'package:dental_app/cast/cast_service.dart';
import 'package:dental_app/models/clinic_profile.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/simulator_screen.dart';
import 'package:dental_app/widgets/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('PC 상담 모니터 명령 → 태블릿 화면에 반영', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(
          profile: ClinicProfile(
            clinicName: '미소드림치과',
            bizNo: '123-45-67890',
            phone: '02-1234-5678',
            zipCode: '06236',
            address: '서울',
            role: '상담실장',
            provider: SocialProvider.kakao,
          ),
        ),
      ),
    );
    for (var i = 0; i < 30 && find.byType(RoiEditor).evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await t.pump(const Duration(milliseconds: 500));
    }
    final send = CastService.instance.onRemoteCmd!;
    send({'t': 'name', 'v': '박서준'});
    send({'t': 'shade', 'v': 'B1'});
    send({'t': 'clearTeeth'});
    send({
      't': 'group',
      'v': [13, 12, 11, 21, 22, 23],
    });
    send({'t': 'tx', 'v': '미백'});
    send({'t': 'shade', 'v': 'XX'}); // 잘못된 값은 무시
    await t.pump();
    expect(find.widgetWithText(TextField, '박서준'), findsWidgets);
    expect(find.textContaining('상악 앞니 6개'), findsWidgets);
    // PC 에서 [After 변환하기]
    send({'t': 'convert'});
    for (
      var i = 0;
      i < 30 && find.byType(StackedCompare).evaluate().isEmpty;
      i++
    ) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await t.pump(const Duration(milliseconds: 500));
    }
    expect(find.byType(StackedCompare), findsOneWidget);
    expect(find.textContaining('셰이드 B1'), findsWidgets);
    // 라벨: 원본 / 박서준 1번
    expect(find.text('원본'), findsWidgets);
    expect(find.text('박서준 After 1'), findsWidgets);
    // 두 번째 변환 → 박서준 2번
    send({'t': 'convert'});
    for (
      var i = 0;
      i < 30 && find.text('박서준 After 2').evaluate().isEmpty;
      i++
    ) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await t.pump(const Duration(milliseconds: 500));
    }
    expect(find.text('박서준 After 2'), findsWidgets);
    // 이전으로 → 1번, 다시 돌아가기 → 2번
    send({'t': 'undo'});
    await t.pump();
    expect(find.text('박서준 After 2'), findsNothing);
    expect(find.text('박서준 After 1'), findsWidgets);
    expect(find.text('다시 돌아가기'), findsOneWidget);
    send({'t': 'redo'});
    await t.pump();
    expect(find.text('박서준 After 2'), findsWidgets);
    expect(find.text('다시 돌아가기'), findsNothing);
    // 브리핑: 왼쪽 목록에서 원본·1번·2번 고르기
    send({'t': 'briefing', 'v': true});
    await t.pump();
    expect(find.text('비교할 사진\n(1~2장 체크)'), findsOneWidget);
    send({'t': 'cmpToggle', 'v': 1}); // 원본 빠지고 1번 vs 2번
    await t.pump();
    expect(find.byType(SliderCompare), findsOneWidget);
    final sc = t.widget<SliderCompare>(find.byType(SliderCompare));
    expect(sc.beforeTitle, '박서준 After 1');
    expect(sc.afterTitle, '박서준 After 2');
    send({'t': 'cmpToggle', 'v': 2}); // 2번 해제 → 1번만 크게
    await t.pump();
    expect(find.byType(SliderCompare), findsNothing);
    send({'t': 'briefing', 'v': false});
    await t.pump();
    // PC 에서 [이전으로] 두 번 → 변환 전
    send({'t': 'undo'});
    send({'t': 'undo'});
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(StackedCompare), findsNothing);
    expect(find.byType(RoiEditor), findsOneWidget);
    // PC 에서 셰이드 해제 (값 없이 옴) → 다시 선택
    send({'t': 'shade'});
    await t.pump();
    expect(find.textContaining('셰이드 B1'), findsNothing);
    send({'t': 'shade', 'v': 'A2'});
    await t.pump();
    // PC 에서 빠르게 두 번 클릭 (태블릿 응답 전) → 선택 후 해제
    send({'t': 'shadeToggle', 'v': 'B1'});
    send({'t': 'shadeToggle', 'v': 'B1'});
    await t.pump();
    expect(find.textContaining('셰이드 B1'), findsNothing);
    send({'t': 'shadeToggle', 'v': 'A1'});
    await t.pump();
    send({'t': 'shadeToggle', 'v': 'B1'}); // 다른 칩 → 바꿈
    await t.pump();
    send({'t': 'shadeToggle', 'v': 'B1'}); // 같은 칩 → 해제
    await t.pump();
    expect(find.textContaining('셰이드 B1'), findsNothing);
    expect(find.textContaining('셰이드 A1'), findsNothing);
    // PC 에서 브리핑 모드 켜기/끄기 (명령 통로 + 손잡이 통로 둘 다)
    send({'t': 'briefing', 'v': true});
    await t.pump();
    expect(find.text('🖥️ 브리핑 종료'), findsOneWidget);
    CastService.instance.onRemoteBriefing!(false);
    await t.pump();
    expect(find.text('🖥️ 환자 브리핑 모드'), findsOneWidget);
    CastService.instance.onRemoteBriefing!(true);
    await t.pump();
    expect(find.text('🖥️ 브리핑 종료'), findsOneWidget);
    send({'t': 'briefing', 'v': false});
    await t.pump();
    await t.pump(const Duration(seconds: 5));
  });
}
