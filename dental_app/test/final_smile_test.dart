import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dental_app/ai/final_smile.dart';
import 'package:dental_app/app_theme.dart';
import 'package:dental_app/cast/cast_service.dart';
import 'package:dental_app/models/clinic_profile.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
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
  test('Final Smile 합성: AI 가 입을 더 다물게(입술 색) 그려도 입 가장자리는 원본 모양, 가운데는 AI 치아', () {
    // 원본: 피부(200,160,140) 위 입술(180,70,80) 안에 입 벌어진 곳(밝은 치아 230,225,215)
    final src = img.Image(width: 200, height: 160)
      ..clear(img.ColorRgb8(200, 160, 140));
    img.fillRect(
      src,
      x1: 40,
      y1: 50,
      x2: 160,
      y2: 110,
      color: img.ColorRgb8(180, 70, 80),
    );
    img.fillRect(
      src,
      x1: 60,
      y1: 65,
      x2: 140,
      y2: 95,
      color: img.ColorRgb8(230, 225, 215),
    );
    // AI: 입술이 안쪽으로 6px 두꺼워짐(입을 더 다묾) + 새 치아 색(250,250,245)
    final ai = img.Image(width: 200, height: 160)
      ..clear(img.ColorRgb8(200, 160, 140));
    img.fillRect(
      ai,
      x1: 40,
      y1: 50,
      x2: 160,
      y2: 110,
      color: img.ColorRgb8(180, 70, 80),
    );
    img.fillRect(
      ai,
      x1: 66,
      y1: 71,
      x2: 134,
      y2: 89,
      color: img.ColorRgb8(250, 250, 245),
    );
    const poly = [
      Offset(0.30, 0.40625),
      Offset(0.70, 0.40625),
      Offset(0.70, 0.59375),
      Offset(0.30, 0.59375),
    ];
    final out = img.decodeJpg(composeFinalSmile((src, ai, poly)))!;
    // 가장자리 띠(원래 열린 곳인데 AI 는 입술) → 원본(밝은 치아), 입술 색이 아님
    final edge = out.getPixel(62, 80);
    expect(edge.r - edge.g, lessThan(30), reason: '입 가장자리에 AI 입술이 들어옴');
    // 가운데는 AI 새 치아
    expect(out.getPixel(100, 80).b, greaterThan(235));
    // 바깥 입술·피부는 원본
    expect(out.getPixel(50, 55).g, closeTo(70, 12));
    expect(out.getPixel(10, 10).r, closeTo(200, 8));
  });

  test('Final Smile: AI 가 정사각형으로 돌려줘도 늘이지 않고 잘라 맞춤', () {
    final src = img.Image(width: 120, height: 160)
      ..clear(img.ColorRgb8(90, 90, 90));
    img.fillCircle(
      src,
      x: 60,
      y: 80,
      radius: 30,
      color: img.ColorRgb8(240, 240, 240),
    );
    // 같은 장면을 정사각형(160x160, 좌우 여백)으로
    final ai = img.Image(width: 160, height: 160)
      ..clear(img.ColorRgb8(90, 90, 90));
    img.fillCircle(
      ai,
      x: 80,
      y: 80,
      radius: 30,
      color: img.ColorRgb8(240, 240, 240),
    );
    final f = fitAiToSource(src, ai);
    expect(f.width, 120);
    expect(f.height, 160);
    expect(f.getPixel(60, 80).r, greaterThan(200)); // 원 가운데 그대로
    expect(f.getPixel(60, 80 - 36).r, lessThan(120)); // 원이 세로로 늘어나지 않음
    expect(f.getPixel(60 - 26, 80).r, greaterThan(200)); // 가로로 찌그러지지 않음
  });

  testWidgets('🆕 Final Smile: 길이 유지 지시 · 다시 만들기 · 이어서 다듬기 · 추가 요청', (t) async {
    debugStepFlowOff = false;
    addTearDown(() => debugStepFlowOff = true);
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final bases = <Uint8List?>[];
    final prompts = <String>[];
    debugFinalSmile =
        ({required orig1, required after, base, prompt = ''}) async {
          bases.add(base);
          prompts.add(prompt);
          // 매번 다른 사진 (같은 사진은 목록에 한 번만 들어가므로)
          return (
            image: jpg(240 - prompts.length * 20, w: 160, h: 120),
            lipsLocked: true,
          );
        };
    addTearDown(() => debugFinalSmile = null);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile),
      ),
    );
    await _settle(t, until: () => find.byType(RoiEditor).evaluate().isNotEmpty);
    final send = CastService.instance.onRemoteCmd!;
    send({'t': 'clearTeeth'});
    send({
      't': 'group',
      'v': [13, 12, 11, 21, 22, 23],
    });
    send({'t': 'tx', 'v': '미백'});
    await t.pump();
    send({'t': 'convert'});
    await _settle(
      t,
      until: () => find.textContaining('After 1').evaluate().isNotEmpty,
    );
    await t.runAsync(() async {
      send({
        't': 'slotPhoto',
        'v': {'s': 1, 'b': base64Encode(jpg(150, w: 160, h: 120))},
      });
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await _settle(t);
    send({'t': 'step', 'v': 5});
    await _settle(t);
    expect(find.text('원래 미소의 치아 길이 유지'), findsOneWidget);
    await t.ensureVisible(find.text('✨ Final Smile 만들기'));
    await t.pump();
    await t.runAsync(() async {
      await t.tap(find.text('✨ Final Smile 만들기'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await _settle(t, until: () => prompts.isNotEmpty);
    await _settle(t);
    expect(prompts.first, contains('same visible length'));
    expect(bases.first, isNull); // 처음은 원본 1 에서
    // 다시 만들기: 이어서 다듬기 + 추가 요청
    expect(find.text('✨ Final Smile 다시 만들기'), findsOneWidget);
    expect(find.textContaining('먼저 3단계'), findsNothing);
    expect(find.text('🦷 Final Smile 치아 크기 조절 (길이·폭)'), findsOneWidget);
    await t.ensureVisible(find.text('지난 Final Smile 을 바탕으로 이어서 다듬기'));
    await t.tap(find.text('지난 Final Smile 을 바탕으로 이어서 다듬기'));
    await t.ensureVisible(find.text('조금 더 짧게'));
    await t.tap(find.text('조금 더 짧게'));
    await t.pump();
    await t.ensureVisible(find.text('✨ Final Smile 다시 만들기'));
    await t.pump();
    await t.runAsync(() async {
      await t.tap(find.text('✨ Final Smile 다시 만들기'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await _settle(t, until: () => prompts.length > 1);
    await _settle(t);
    expect(bases.last, isNotNull); // 지난 Final Smile 을 바탕으로
    expect(prompts.last, contains('조금 더 짧게'));
    expect(find.textContaining('Final Smile 2'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  test('fal 나노바나나 요청: image_urls 순서 [원본 1, After], 지시문 상수, sync_mode', () {
    final a = Uint8List.fromList([1, 2, 3]), b = Uint8List.fromList([4, 5]);
    final body = FalNanoBananaEdit.body([a, b], kFinalSmilePrompt);
    final urls = body['image_urls']! as List;
    expect(urls[0], 'data:image/jpeg;base64,${base64Encode(a)}');
    expect(urls[1], 'data:image/jpeg;base64,${base64Encode(b)}');
    expect(
      body['prompt'],
      startsWith(
        'Strictly preserve the first image (natural smile) as the base',
      ),
    );
    expect(kFinalSmilePrompt, contains('green attachment dots'));
    expect(kFinalSmilePrompt, endsWith('Photorealistic clinical portrait.'));
    expect(body['sync_mode'], isTrue);
    expect(
      FalNanoBananaEdit('k').endpoint.toString(),
      'https://fal.run/fal-ai/nano-banana/edit',
    );
  });

  test('2단계: 입술 사이 바깥은 원본 1 픽셀로 고정', () async {
    final orig = img.Image(width: 200, height: 150)
      ..clear(img.ColorRgb8(200, 150, 130));
    late List<Uint8List> sent;
    final r = await makeFinalSmile(
      orig1: img.encodeJpg(orig, quality: 100),
      after: jpg(240),
      edit: (jpegs, prompt) async {
        sent = jpegs;
        expect(prompt, kFinalSmilePrompt);
        // AI 가 전체를 하얗게 바꿨다고 가정 (입술·얼굴까지)
        return img.encodeJpg(
          img.Image(width: 200, height: 150)
            ..clear(img.ColorRgb8(250, 250, 250)),
        );
      },
      lips: (_) async => const [
        Offset(0.4, 0.6),
        Offset(0.6, 0.6),
        Offset(0.6, 0.7),
        Offset(0.4, 0.7),
      ],
    );
    expect(sent.length, 2);
    expect(img.decodeJpg(sent[0])!.width, 200); // 첫 번째 = 원본 1
    expect(r.lipsLocked, isTrue);
    final out = img.decodeJpg(r.image)!;
    expect(out.getPixel(100, 97).r, greaterThan(240)); // 입 안쪽 = AI 결과
    expect((out.getPixel(20, 20).g - 150).abs(), lessThan(8)); // 얼굴 = 원본 1
  });

  testWidgets('원본 2슬롯: 원본 2 변환(After) → 원본 1 넣기 → 2단계 Final Smile, 슬롯 바꿔 변환', (
    t,
  ) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    Uint8List? gotOrig1, gotAfter;
    final finalImg = jpg(251, w: 160, h: 120);
    debugFinalSmile =
        ({required orig1, required after, base, prompt = ''}) async {
          gotOrig1 = orig1;
          gotAfter = after;
          return (image: finalImg, lipsLocked: true);
        };
    addTearDown(() => debugFinalSmile = null);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile),
      ),
    );
    await _settle(t, until: () => find.byType(RoiEditor).evaluate().isNotEmpty);
    final send = CastService.instance.onRemoteCmd!;
    final smile = jpg(150, w: 160, h: 120);
    // 예시 사진 = 원본 2 (개구기) 자리
    expect(find.text('원본 1 · 자연스러운 미소'), findsOneWidget);
    expect(find.text('원본 2 · 개구기'), findsOneWidget);
    expect(find.text('눌러서 사진 올리기'), findsOneWidget); // 원본 1 비어 있음
    // 1단계: 원본 2 변환
    send({'t': 'clearTeeth'});
    send({
      't': 'group',
      'v': [13, 12, 11, 21, 22, 23],
    });
    send({'t': 'tx', 'v': '미백'});
    send({'t': 'shade', 'v': 'B1'});
    await t.pump();
    send({'t': 'convert'});
    await _settle(
      t,
      until: () => find.byType(StackedCompare).evaluate().isNotEmpty,
    );
    expect(find.text('After'), findsWidgets); // After 배지
    expect(find.text('원본 2 (개구기)'), findsNothing); // 짝이 생기기 전엔 '원본'
    // 원본 1 넣기 → 2단계
    await t.runAsync(() async {
      send({
        't': 'slotPhoto',
        'v': {'s': 1, 'b': base64Encode(smile)},
      });
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await _settle(t);
    expect(find.text('원본 2 (개구기)'), findsWidgets);
    expect(find.text('2단계 · 최종 미소 만들기'), findsOneWidget);
    await t.runAsync(() async {
      send({'t': 'finalSmile'});
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await _settle(t, until: () => gotAfter != null);
    await _settle(t);
    expect(img.decodeJpg(gotOrig1!)!.width, 160); // 첫 번째 = 원본 1 (미소)
    expect(gotAfter, isNotNull);
    expect(find.textContaining('Final Smile'), findsWidgets);
    // 원본 1 을 변환할 사진으로 고르기
    send({'t': 'slotSelect', 'v': 1});
    await _settle(t);
    expect(find.text('원본 1 (미소)'), findsWidgets);
    expect(find.byType(RoiEditor), findsOneWidget); // 원본 1 은 아직 변환 전
    send({'t': 'slotSelect', 'v': 2});
    await _settle(t);
    expect(find.byType(RoiEditor), findsNothing); // 원본 2 는 After 있음
    expect(t.takeException(), isNull);
  });
}
