import 'package:dental_app/ai/ai_service.dart';
import 'package:dental_app/ai/pipeline.dart';
import 'package:dental_app/app_theme.dart';
import 'package:dental_app/cast/cast_service.dart';
import 'package:dental_app/models/clinic_profile.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/simulator_screen.dart';
import 'package:dental_app/widgets/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:dental_app/simulator/sim_models.dart';

void main() {
  test('잇몸 마스크 잠금: 상악선 위·하악선 아래는 원본 픽셀, 치아 쪽은 AI 결과', () {
    final src = img.Image(width: 400, height: 300)
      ..clear(img.ColorRgb8(200, 0, 0));
    final ai = img.encodePng(
      img.Image(width: 400, height: 300)..clear(img.ColorRgb8(0, 0, 200)),
    );
    final lock = [
      GuideLine(upper: true, pts: const [Offset(0.2, 0.4), Offset(0.8, 0.4)]),
      GuideLine(upper: false, pts: const [Offset(0.2, 0.7), Offset(0.8, 0.7)]),
    ];
    final out = img.decodeJpg(fullResultForTest(src, ai, lock: lock))!;
    bool red(int x, int y) =>
        out.getPixel(x, y).r > 150 && out.getPixel(x, y).b < 60;
    bool blue(int x, int y) =>
        out.getPixel(x, y).b > 150 && out.getPixel(x, y).r < 60;
    expect(red(200, 40), isTrue); // 상악선 위 (잇몸·입술) = 원본
    expect(red(200, 110), isTrue); // 선 바로 위도 원본
    expect(blue(200, 150), isTrue); // 치아 쪽 = AI
    expect(red(200, 260), isTrue); // 하악선 아래 = 원본
    expect(blue(20, 40), isTrue); // 선이 없는 가로 범위는 잠그지 않음
    // 선을 안 그리면 전부 AI
    final none = img.decodeJpg(fullResultForTest(src, ai))!;
    expect(none.getPixel(200, 40).b, greaterThan(150));
  });

  test('서비컬 라인 참고 사진: 상악 초록·하악 분홍 선이 그려짐', () {
    final src = img.Image(width: 300, height: 200)
      ..clear(img.ColorRgb8(120, 120, 120));
    final out = img.decodeJpg(
      guideForTest(src, [
        GuideLine(
          upper: true,
          pts: [const Offset(0.1, 0.4), const Offset(0.9, 0.4)],
        ),
        GuideLine(
          upper: false,
          pts: [const Offset(0.1, 0.7), const Offset(0.9, 0.7)],
        ),
      ]),
    )!;
    final g = out.getPixel(150, 80),
        m = out.getPixel(150, 140),
        bg = out.getPixel(150, 20);
    expect(g.g, greaterThan(180));
    expect(g.r, lessThan(80));
    expect(m.r, greaterThan(180));
    expect(m.g, lessThan(80));
    expect(bg.r, closeTo(120, 15));
  });

  test('순수 프롬프트: AI 결과 전체를 원본 크기로 (비율 다르면 가운데 맞춤)', () {
    final src = img.Image(width: 300, height: 200);
    final ai = img.encodePng(
      img.Image(width: 400, height: 400)..clear(img.ColorRgb8(0, 0, 200)),
    );
    final out = img.decodeJpg(fullResultForTest(src, ai))!;
    expect(out.width, 300);
    expect(out.height, 200);
    expect(out.getPixel(10, 10).b, greaterThan(150));
  });

  test('칠한 부분만 AI 결과로 바뀌고 나머지는 원본 그대로', () {
    final src = img.Image(width: 200, height: 100)
      ..clear(img.ColorRgb8(200, 0, 0));
    final ai = img.encodePng(
      img.Image(width: 100, height: 50)..clear(img.ColorRgb8(0, 0, 200)),
    );
    const crop = (x: 50, y: 25, w: 100, h: 50);
    // 가운데(사진 좌표 0.5, 0.5) 에 반지름 = 너비의 5% (10px) 로 한 점 칠함
    final mask = [
      MaskStroke(r: 0.05, erase: false, pts: [const Offset(0.5, 0.5)]),
    ];
    final out = img.decodeJpg(compositeForTest(src, crop, ai, mask))!;
    final center = out.getPixel(100, 50), inCropOutside = out.getPixel(60, 30);
    expect(center.b, greaterThan(150)); // 칠한 곳 = AI(파랑)
    expect(center.r, lessThan(60));
    expect(inCropOutside.r, greaterThan(150)); // 안 칠한 곳 = 원본(빨강)
    expect(inCropOutside.b, lessThan(60));
    // 칠하지 않으면 기존처럼 치아 영역 가운데 전체가 AI 결과
    final out2 = img.decodeJpg(compositeForTest(src, crop, ai, const []))!;
    expect(out2.getPixel(80, 50).b, greaterThan(150));
    expect(out.getPixel(80, 50).r, greaterThan(150));
  });

  for (final size in const [Size(390, 844), Size(800, 1280), Size(1280, 800)]) {
    testWidgets('AI 켜짐: 요청 입력칸 표시·수정 $size', (t) async {
      AiService.instance.ready = true;
      AiService.instance.request = AiService.defaultRequest;
      addTearDown(() => AiService.instance.ready = false);
      t.view.physicalSize = size;
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
      for (
        var i = 0;
        i < 30 && find.byType(Scrollable).evaluate().isEmpty;
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await t.pump(const Duration(milliseconds: 500));
      }
      final field = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.decoration?.hintText ?? '').startsWith('자동 임상 지시에 더할 내용'),
      );
      await t.ensureVisible(field);
      await t.pump();
      expect(field, findsOneWidget);
      expect(find.text('치아 영역'), findsNothing); // AI 사용 시 영역 표시 없음
      expect(find.byTooltip('칠하기'), findsNothing);
      // 사진 아래 체크 → 서비컬 라인 도구
      final chk = find.text('서비컬 라인 그려서 AI 기준 잡기');
      expect(chk, findsOneWidget);
      expect(find.byTooltip('상악선'), findsNothing);
      await t.ensureVisible(chk);
      await t.tap(chk);
      await t.pump();
      expect(find.byTooltip('상악선'), findsOneWidget);
      expect(find.byTooltip('하악선'), findsOneWidget);
      expect(find.byTooltip('영역'), findsNothing); // AI 모드: 영역 도구 없음
      // 사진 위에서 위아래로 그려도 화면이 스크롤되지 않고 선이 그려짐
      await t.ensureVisible(find.byType(RoiEditor));
      await t.pump();
      final sc = find.byType(Scrollable).first;
      final before = t.state<ScrollableState>(sc).position.pixels;
      final c = t.getCenter(find.byType(RoiEditor));
      await t.dragFrom(c, const Offset(30, 60));
      await t.pump();
      expect(t.state<ScrollableState>(sc).position.pixels, before);
      expect(find.textContaining('그린 선 1개'), findsOneWidget);
      // 태블릿 도구: 되돌리기 → 0개, 다시 그리고 모두 지움 → 0개
      await t.tap(find.byTooltip('되돌리기'));
      await t.pump();
      expect(find.textContaining('그린 선'), findsNothing);
      await t.dragFrom(c, const Offset(40, 20));
      await t.pump();
      await t.dragFrom(c + const Offset(0, 30), const Offset(40, 10));
      await t.pump();
      expect(find.textContaining('그린 선 2개'), findsOneWidget);
      await t.tap(find.byTooltip('모두 지움'));
      await t.pump();
      expect(find.textContaining('그린 선'), findsNothing);
      // 모두 지움도 되돌리기로 복구
      await t.tap(find.byTooltip('되돌리기'));
      await t.pump();
      expect(find.textContaining('그린 선 2개'), findsOneWidget);
      // 선이 있으면 자동 임상 지시에 잇몸 마스크 잠금이 들어감
      expect(find.textContaining('서비컬 라인 위쪽 잇몸 = 마스크 잠금'), findsOneWidget);
      send0() => CastService.instance.onRemoteCmd!;
      final send = send0();
      send({'t': 'linesClear'});
      await t.pump();
      expect(find.textContaining('그린 선'), findsNothing);
      // PC 명령: 빠르게 2줄 추가 → 되돌리기 → 모두 지움 → 되돌리기
      final line = {
        'u': 1,
        'p': [0.2, 0.4, 0.5, 0.42, 0.8, 0.4],
      };
      send({'t': 'lineAdd', 'v': line});
      send({'t': 'lineAdd', 'v': line});
      await t.pump();
      expect(find.textContaining('그린 선 2개'), findsOneWidget);
      send({'t': 'linesUndo'});
      await t.pump();
      expect(find.textContaining('그린 선 1개'), findsOneWidget);
      // PC 지우개: 선 가운데를 지나가면 두 개로 나뉨
      send({
        't': 'lineErase',
        'v': {
          'p': [0.5, 0.3, 0.5, 0.5],
          'r': 0.02,
        },
      });
      await t.pump();
      expect(find.textContaining('그린 선 2개'), findsOneWidget);
      // PC 선 다듬기 → 가까운 두 조각이 다시 하나로 이어지지 않음(지운 틈이 4%보다 넓으면 그대로)
      send({'t': 'linesSmooth'});
      await t.pump();
      expect(find.textContaining('그린 선'), findsOneWidget);
      send({'t': 'linesClear'});
      await t.pump();
      expect(find.textContaining('그린 선'), findsNothing);
      send({'t': 'linesUndo'});
      await t.pump();
      expect(find.textContaining('그린 선'), findsOneWidget);
      send({'t': 'linesClear'});
      send({'t': 'lineAdd', 'v': line});
      send({'t': 'lines'}); // 예전 PC 화면의 '빈 목록' (Firebase 가 지워서 값 없이 옴) → 모두 지움
      await t.pump();
      expect(find.textContaining('그린 선'), findsNothing);
      // 자동 임상 지시 요약 + 추가 요청 지우기
      expect(find.text('자동 임상 지시 (치료 항목·부위·셰이드 기준)'), findsOneWidget);
      // 변환 엔진 선택 (변환 버튼 바로 위): 4가지
      expect(find.text('AI 시뮬레이션 엔진 (하나 선택)'), findsOneWidget);
      expect(
        find.text('AI 시뮬레이션 (나노바나나 2.1)'),
        findsNothing,
      ); // 예전 켜기/끄기 칸은 없어짐
      // 옵션 A 를 눌러 선택
      await t.ensureVisible(find.text('옵션 A · FLUX + 나노바나나 2.1'));
      await t.pump();
      await t.tap(find.text('옵션 A · FLUX + 나노바나나 2.1'));
      await t.pump();
      expect(PipelineSettings.instance.engine, Engine.a);
      for (final e in Engine.values) {
        expect(find.text('${e.tag} · ${e.label}'), findsOneWidget);
      }
      PipelineSettings.instance.setEngine(Engine.b).ignore();
      final send2 = CastService.instance.onRemoteCmd!;
      send2({'t': 'linesClear'});
      send2({
        't': 'lineAdd',
        'v': {
          'u': 1,
          'p': [0.2, 0.4, 0.8, 0.4],
        },
      });
      // 교정 선택 → 단독 자동 전환 안내
      final hadOrtho = find
          .textContaining('교정은 치아 위치를 옮겨야')
          .evaluate()
          .isNotEmpty;
      if (!hadOrtho) send2({'t': 'tx', 'v': '교정'});
      await t.pump();
      expect(find.textContaining('교정은 치아 위치를 옮겨야'), findsOneWidget);
      send2({'t': 'tx', 'v': '교정'}); // 교정 끄기
      send2({'t': 'tx', 'v': '라미네이트'});
      await t.pump();
      if (find.textContaining('1단계 FLUX(마진·형태 고정)').evaluate().isEmpty) {
        send2({'t': 'tx', 'v': '라미네이트'});
        await t.pump();
      }
      expect(
        find.textContaining('1단계 FLUX(마진·형태 고정) → 2단계 나노바나나 Pro'),
        findsOneWidget,
      );
      // PC 에서 엔진 바꾸기
      send2({'t': 'engine', 'v': 'c'});
      await t.pump();
      expect(PipelineSettings.instance.engine, Engine.c);
      expect(find.textContaining('2단계 Vertex AI Imagen'), findsOneWidget);
      send2({'t': 'linesClear'});
      await t.pump();
      expect(find.text('지우기'), findsNothing);
      await t.enterText(field, '11, 21 길이 1mm 늘리기');
      await t.pump();
      expect(find.text('지우기'), findsOneWidget);
      await t.ensureVisible(find.text('지우기'));
      await t.pump();
      await t.tap(find.text('지우기'));
      await t.pump();
      expect(find.widgetWithText(TextField, '11, 21 길이 1mm 늘리기'), findsNothing);
      // 셰이드: 같은 칩을 다시 누르면 해제 → 요약에 '셰이드 미선택'
      final a1 = find.bySemanticsLabel(RegExp(r'^셰이드 A1'));
      await t.ensureVisible(a1);
      await t.pump();
      final wasSelected = find.textContaining('＋ 셰이드 A1').evaluate().isNotEmpty;
      await t.tap(a1);
      await t.pump();
      if (wasSelected) {
        expect(find.textContaining('＋ 셰이드 미선택'), findsOneWidget);
        await t.tap(a1);
        await t.pump();
      }
      expect(find.textContaining('＋ 셰이드 A1'), findsOneWidget);
      await t.tap(a1);
      await t.pump();
      expect(find.textContaining('＋ 셰이드 미선택'), findsOneWidget);
    });
  }
}
