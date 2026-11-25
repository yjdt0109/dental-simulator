import 'dart:typed_data';

import 'package:dental_app/ai/pipeline.dart';
import 'package:dental_app/ai/smile_match.dart';
import 'package:dental_app/app_theme.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:dental_app/simulator/smile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 400x300 미소: 피부 + 입술(160..240 x 170..210) + 입 안쪽(170..230 x 182..198)에 누런 치아
img.Image smileImg() {
  final im = img.Image(width: 400, height: 300)
    ..clear(img.ColorRgb8(200, 150, 130));
  img.fillRect(
    im,
    x1: 160,
    y1: 170,
    x2: 240,
    y2: 210,
    color: img.ColorRgb8(180, 60, 70),
  );
  img.fillRect(
    im,
    x1: 170,
    y1: 182,
    x2: 230,
    y2: 198,
    color: img.ColorRgb8(150, 140, 110),
  );
  return im;
}

AlignOut fakeAlign() {
  // 입 안쪽 마스크
  final mask = img.Image(width: 400, height: 300)
    ..clear(img.ColorRgb8(0, 0, 0));
  img.fillRect(
    mask,
    x1: 170,
    y1: 182,
    x2: 230,
    y2: 198,
    color: img.ColorRgb8(255, 255, 255),
  );
  // 정렬된 보철 치아: 입 안쪽 가운데만 (양 끝 5px 는 못 덮음) + 입술 위까지 삐져나온 부분
  final teeth = img.Image(width: 400, height: 300, numChannels: 4)
    ..clear(img.ColorRgba8(0, 0, 0, 0));
  img.fillRect(
    teeth,
    x1: 175,
    y1: 176,
    x2: 225,
    y2: 198,
    color: img.ColorRgba8(250, 250, 245, 255),
  );
  return AlignOut(
    alignedTeeth: img.encodePng(teeth),
    mask: img.encodePng(mask),
    crop: img.encodePng(img.Image(width: 10, height: 10)),
    residual: 0.004,
    eyes: true,
    scale: 1.08,
    degrees: -1.5,
  );
}

void main() {
  testWidgets('체이닝: 정렬 → 합성 → FLUX(빈 곳만) → 나노바나나 → 입술·얼굴 원본 고정', (t) async {
    final calls = <String>[];
    Uint8List? fillMask;
    late MatchResult r;
    final steps = <String>[];
    await t.runAsync(() async {
      r = await matchProsthesis(
        smile: img.encodeJpg(smileImg(), quality: 100),
        prosth: img.encodeJpg(smileImg(), quality: 100),
        onStep: steps.add,
        align: (s, p) async {
          calls.add('align');
          return fakeAlign();
        },
        fill: (jpeg, mask, prompt) async {
          calls.add('fill');
          fillMask = mask;
          expect(prompt, contains('Keep every visible tooth exactly'));
          return jpeg; // 그대로 돌려줌
        },
        retouch: (comp, orig, prompt) async {
          calls.add('retouch');
          expect(prompt, contains('Do NOT change the shape'));
          // AI 가 잘라낸 부분 전체를 살짝 어둡게 (입술까지 건드렸다고 가정)
          final c = img.decodeJpg(comp)!;
          for (final px in c) {
            px
              ..r = px.r * 0.9
              ..g = px.g * 0.9
              ..b = px.b * 0.9;
          }
          return img.encodeJpg(c, quality: 100);
        },
      );
    });
    expect(calls, ['align', 'fill', 'retouch']);
    expect(steps.first, contains('준비'));
    expect(steps.any((s) => s.contains('FLUX')), isTrue);
    // ② 합성: 입 안쪽 가운데는 하얀 보철 치아
    final comp = img.decodeJpg(r.composite)!;
    expect(comp.getPixel(200, 190).r, greaterThan(235));
    // 입술 위로 삐져나온 보철 치아(y 176)는 입술 안쪽 마스크 밖이라 안 붙음
    expect(comp.getPixel(200, 177).g, lessThan(100));
    // ③ FLUX 마스크: 보철 치아가 못 덮은 입 안쪽 양 끝(172)은 채움, 치아 가운데는 안 채움
    final fm = img.decodePng(fillMask!)!;
    expect(fm.width, lessThan(400)); // 입 주변만 잘라 보냄
    // ⑤ 최종: 입술·피부는 원본 그대로 (AI 가 어둡게 했어도)
    final out = img.decodeJpg(r.finalImage)!;
    final lip = out.getPixel(200, 174);
    expect((lip.r - 180).abs() + (lip.g - 60).abs(), lessThan(14));
    final skin = out.getPixel(100, 100);
    expect((skin.g - 150).abs(), lessThan(8));
    expect(out.getPixel(200, 190).r, greaterThan(205)); // 치아는 결과 반영
    expect(r.align.summary, contains('양쪽 눈동자 + 코끝'));
    expect(r.notes, isEmpty);
  });

  testWidgets('FLUX 가 실패해도 나노바나나로 이어서 결과를 줌 (안내 남김)', (t) async {
    late MatchResult r;
    await t.runAsync(() async {
      r = await matchProsthesis(
        smile: img.encodeJpg(smileImg()),
        prosth: img.encodeJpg(smileImg()),
        onStep: (_) {},
        align: (s, p) async => fakeAlign(),
        fill: (j, m, p) async =>
            throw const PipelineError('Fal.ai API 키가 없습니다'),
        retouch: (c, o, p) async => c,
      );
    });
    expect(r.notes.single, contains('FLUX 단계를 건너뛰었습니다'));
    expect(img.decodeJpg(r.finalImage)!.getPixel(200, 190).r, greaterThan(230));
  });

  for (final size in const [Size(390, 844), Size(1280, 900)]) {
    testWidgets('미소 화면: 보철 사진 고르기 → 정밀 매칭 → 단계별 결과 $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final smile = Uint8List.fromList(img.encodeJpg(smileImg()));
      final p = PatientPhoto(
        id: 'x',
        name: '김민수',
        type: '정면',
        time: '방금',
        beforeBytes: smile,
        imageSize: const Size(400, 300),
      );
      await t.runAsync(() => setSmile(p, smile));
      final white = Uint8List.fromList(
        img.encodeJpg(
          img.Image(width: 400, height: 300)
            ..clear(img.ColorRgb8(250, 250, 245)),
        ),
      );
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: SmilePreviewScreen(
            photo: p,
            after: white,
            afterLabel: '김민수 1번',
            pick: (_) async => smile,
            matcher: (s, pr, step) async {
              step('① 📍 정렬 중…');
              return MatchResult(
                align: fakeAlign(),
                composite: white,
                stage1: white,
                finalImage: white,
              );
            },
          ),
        ),
      );
      await t.scrollUntilVisible(
        find.text('🎯 정밀 매칭 합성 시작'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await t.ensureVisible(find.text('지금 결과 쓰기 (김민수 1번)'));
      await t.pumpAndSettle();
      await t.tap(find.text('지금 결과 쓰기 (김민수 1번)'));
      await t.pump();
      expect(find.text('2번: 김민수 1번'), findsOneWidget);
      await t.ensureVisible(find.text('🎯 정밀 매칭 합성 시작'));
      await t.pumpAndSettle();
      await t.tap(find.text('🎯 정밀 매칭 합성 시작'));
      await t.pump();
      await t.pump();
      expect(find.textContaining('완성!'), findsOneWidget);
      expect(find.textContaining('정렬 오차 0.4%'), findsOneWidget);
      expect(p.smileAfter, white);
      expect(p.smileFrom, '보철 사진 정밀 매칭');
      await t.scrollUntilVisible(
        find.text('③ 최종'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('① 정렬 합성'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('미소 미리보기: 오늘 만든 After 중 골라 2번(보철 사진)으로', (t) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final smile = Uint8List.fromList(img.encodeJpg(smileImg()));
    final p = PatientPhoto(
      id: 'y',
      name: '김',
      type: '정면',
      time: '방금',
      beforeBytes: smile,
      imageSize: const Size(400, 300),
    );
    await t.runAsync(() => setSmile(p, smile));
    final a1 = Uint8List.fromList(
      img.encodeJpg(
        img.Image(width: 40, height: 30)..clear(img.ColorRgb8(250, 250, 245)),
      ),
    );
    final a2 = Uint8List.fromList(
      img.encodeJpg(
        img.Image(width: 40, height: 30)..clear(img.ColorRgb8(240, 240, 235)),
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SmilePreviewScreen(
          photo: p,
          afterChoices: [
            (label: '김 After 1', bytes: a1),
            (label: '김 After 1 (원본 2)', bytes: a2),
          ],
        ),
      ),
    );
    await t.scrollUntilVisible(
      find.text('오늘 만든 After에서 고르기'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('김 After 1 (원본 2)'));
    await t.pump();
    expect(find.text('2번: 김 After 1 (원본 2)'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
