import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/ai/final_smile.dart';
import 'package:dental_app/library/custom_library_store.dart';
import 'package:dental_app/library/library_screen.dart';
import 'package:dental_app/library/liquify_screen.dart';
import 'package:dental_app/library/tooth_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List photo({int w = 400, int h = 300}) {
  final im = img.Image(width: w, height: h)
    ..clear(img.ColorRgb8(200, 160, 140));
  img.fillRect(
    im,
    x1: 120,
    y1: 120,
    x2: 280,
    y2: 190,
    color: img.ColorRgb8(60, 20, 25),
  );
  return img.encodeJpg(im);
}

void main() {
  test('📐 AI 로 다듬어도 라이브러리 윤곽 밖은 그대로 (길이가 길어지지 않음)', () {
    final comp = img.Image(width: 100, height: 100)
      ..clear(img.ColorRgb8(40, 20, 20));
    img.fillRect(
      comp,
      x1: 40,
      y1: 20,
      x2: 60,
      y2: 60,
      color: img.ColorRgb8(220, 215, 200),
    );
    final mask = img.Image(width: 100, height: 100, numChannels: 1);
    img.fillRect(
      mask,
      x1: 40,
      y1: 20,
      x2: 60,
      y2: 60,
      color: img.ColorRgb8(255, 255, 255),
    );
    // AI: 치아를 아래로 20px 길게 + 색이 조금 다름
    final ai = img.Image(width: 100, height: 100)
      ..clear(img.ColorRgb8(40, 20, 20));
    img.fillRect(
      ai,
      x1: 40,
      y1: 20,
      x2: 60,
      y2: 80,
      color: img.ColorRgb8(250, 248, 240),
    );
    final out = img.decodeJpg(blendInsideMask((comp, ai, mask)))!;
    expect(
      out.getPixel(50, 70).r,
      lessThan(90),
      reason: '윤곽 밖(늘어난 부분)은 원래 어두운 입 안',
    );
    expect(out.getPixel(50, 40).r, greaterThan(235), reason: '윤곽 안은 AI');
  });

  test('📁 내 라이브러리 PNG: 파일 이름의 치아 번호, 투명 배경 잘라 맞춤, 투명 배경 없으면 안내', () {
    Uint8List tooth(int w, int h) {
      final im = img.Image(width: 100, height: 120, numChannels: 4);
      img.fillRect(
        im,
        x1: 10,
        y1: 5,
        x2: 10 + w,
        y2: 5 + h,
        color: img.ColorRgba8(240, 235, 220, 255),
      );
      return img.encodePng(im);
    }

    expect(fdiFromName('UR1_11.png'), 11);
    expect(fdiFromName('tooth-23.png'), 23);
    expect(fdiFromName('IMG_2024.png'), isNull);
    final out = prepareLibraryPngs([
      ('11.png', tooth(40, 90)),
      ('12.png', tooth(30, 80)),
    ]);
    expect(out.keys.toSet(), {11, 12});
    final c = img.decodePng(out[11]!)!;
    expect(c.width, 41); // 투명한 곳은 잘려 나감
    expect(c.height, 91);
    // 이름에 번호가 없으면 고른 차례: 3장이면 11 12 13
    final o3 = prepareLibraryPngs([
      ('a.png', tooth(40, 90)),
      ('b.png', tooth(30, 80)),
      ('c.png', tooth(25, 85)),
    ]);
    expect(o3.keys.toSet(), {11, 12, 13});
    expect(
      () => prepareLibraryPngs([
        ('11.jpg', img.encodeJpg(img.Image(width: 10, height: 10))),
      ]),
      throwsA(isA<StateError>()),
    );
  });

  test('📐 몇 개만·치아별 조절: 고른 치아만, 11번만 길게·옮김', () {
    const pl = LibraryPlacement(center: Offset(500, 300), width: 647.2);
    final all = placedSlots(pl, kToothForms[3]);
    final some = placedSlots(
      pl,
      kToothForms[3],
      teeth: {11, 21},
      adj: {11: const ToothAdj(dx: 5, sh: 1.2)},
    );
    expect(some.map((s) => s.fdi).toSet(), {11, 21});
    final a11 = all.firstWhere((s) => s.fdi == 11).rect;
    final b11 = some.firstWhere((s) => s.fdi == 11).rect;
    expect(b11.height, closeTo(a11.height * 1.2, 0.01));
    expect(b11.top, closeTo(a11.top, 0.01)); // 잇몸 쪽 기준으로 길어짐
    expect(b11.left, closeTo(a11.left + 5, 0.01));
    expect(
      some.firstWhere((s) => s.fdi == 21).rect,
      all.firstWhere((s) => s.fdi == 21).rect,
    );
  });

  test('6전치 라이브러리: 모양 5종 · 황금비율 배열 · 스마일 곡선', () {
    expect(kToothForms.length, 5);
    expect(kToothForms.map((f) => f.name), [
      '사각형',
      '난원형',
      '삼각형',
      '사각-난원형',
      '젊은 형',
    ]);
    const pl = LibraryPlacement(
      center: Offset(500, 300),
      width: 647.2,
      arc: 0.5,
    );
    final s = librarySlots(pl, kToothForms[3]);
    expect(s.map((t) => t.fdi).toSet(), {11, 12, 13, 21, 22, 23});
    Rect r(int fdi) => s.firstWhere((t) => t.fdi == fdi).rect;
    expect(r(11).width / r(12).width, closeTo(1.618, 0.01));
    expect(r(12).width / r(13).width, closeTo(1.618, 0.01));
    expect(r(11).right, closeTo(500, 0.01)); // 정중선
    expect(r(13).left, closeTo(500 - 323.6, 0.1)); // 견치~견치 = 폭
    expect(r(23).right, closeTo(500 + 323.6, 0.1));
    // 측절치·견치 절단끝이 중절치보다 위 (스마일 곡선), 곡선을 키우면 더 올라감
    expect(r(12).bottom, lessThan(r(11).bottom));
    expect(r(13).bottom, lessThan(r(12).bottom + 1));
    final more = librarySlots(pl.copyWith(arc: 1), kToothForms[3]);
    expect(
      more.firstWhere((t) => t.fdi == 13).rect.bottom,
      lessThan(r(13).bottom),
    );
    // 길이 배율
    final longer = librarySlots(pl.copyWith(length: 1.2), kToothForms[3]);
    expect(
      longer.firstWhere((t) => t.fdi == 11).rect.height,
      closeTo(r(11).height * 1.2, 0.01),
    );
    // 중절치를 맨 나중에 (맨 앞에 보이게)
    expect(s.last.kind, 1);
  });

  test('밀어서 다듬기 그물: 미는 곳만 움직이고 사진 가장자리는 고정, 되돌리기 붓', () {
    final m = WarpMesh(400, 300, cols: 40);
    expect(m.changed, isFalse);
    m.push(const Offset(200, 150), const Offset(0, 20), 40);
    expect(m.changed, isTrue);
    final k = (15 * (m.cols + 1) + 20) * 2; // (200,150) 근처 점
    expect(m.pos[k + 1], greaterThan(150 + 10));
    final far = (2 * (m.cols + 1) + 2) * 2;
    expect(m.pos[far + 1], closeTo(m.home(2, 2).dy, 1e-6)); // 먼 곳은 그대로
    m.push(const Offset(0, 0), const Offset(30, 30), 50);
    expect(m.pos[0], 0); // 모서리 고정
    expect(m.pos[1], 0);
    for (var i = 0; i < 40; i++) {
      m.restore(const Offset(200, 150), 60, strength: 0.5);
    }
    expect(m.pos[k + 1], closeTo(150, 1));
  });

  testWidgets('📐 라이브러리 화면: 입술 자동 맞춤 · 모양·막대 · 완성(원본 크기)', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    debugLibraryLips = () => const [
      Offset(0.30, 0.40),
      Offset(0.70, 0.40),
      Offset(0.70, 0.63),
      Offset(0.30, 0.63),
    ];
    addTearDown(() => debugLibraryLips = null);
    LibraryResult? got;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  got = await Navigator.of(ctx).push<LibraryResult>(
                    MaterialPageRoute(
                      builder: (_) => LibraryScreen(
                        image: photo(),
                        imageSize: const Size(400, 300),
                        shade: 'A1',
                      ),
                    ),
                  ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('열기'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await t.pumpAndSettle();
    expect(find.text('📐 6전치 라이브러리'), findsOneWidget);
    // 입 주변 자동 확대 + 확대 버튼
    expect(find.textContaining('두 손가락: 사진 확대 · 100%'), findsNothing);
    await t.tap(find.byTooltip('사진 전체'));
    await t.pump();
    expect(find.textContaining('· 100%'), findsOneWidget);
    await t.tap(find.byTooltip('확대'));
    await t.pump();
    expect(find.textContaining('· 140%'), findsOneWidget);
    for (final n in ['사각형', '난원형', '삼각형', '사각-난원형', '젊은 형']) {
      expect(find.text(n), findsOneWidget);
    }
    await t.tap(find.text('난원형'));
    await t.pump();
    expect(find.textContaining('둥근 모서리'), findsOneWidget);
    // 끌어서 옮기기
    await t.drag(find.byType(Image).first, const Offset(10, 5));
    await t.pump();
    // 몇 개만: 13·23 빼기, 11번만 길게
    await t.scrollUntilVisible(
      find.text('보일 치아 (눌러서 빼기·넣기)'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await t.tap(find.widgetWithText(FilterChip, '13'));
    await t.tap(find.widgetWithText(FilterChip, '23'));
    await t.pump();
    expect(
      find.widgetWithText(ChoiceChip, '13'),
      findsNothing,
    ); // 뺀 치아는 조절 대상에서도 빠짐
    await t.tap(find.widgetWithText(ChoiceChip, '11'));
    await t.pump();
    expect(find.text('11번 길이'), findsOneWidget);
    expect(find.textContaining('한 손가락: 11번만 옮기기'), findsOneWidget);
    await t.tap(find.widgetWithText(ChoiceChip, '전체'));
    await t.pump();
    await t.scrollUntilVisible(
      find.text('완성 후 AI 로 자연스럽게'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await t.tap(find.text('완성 후 AI 로 자연스럽게'));
    await t.pump();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await t.pump();
    await t.runAsync(() async {
      await t.tap(find.text('완성'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await t.pumpAndSettle();
    expect(got, isNotNull);
    expect(got!.aiBlend, isFalse);
    expect(got!.form, '난원형');
    expect(got!.lips, isNotNull);
    final o = img.decodeJpg(got!.image)!;
    expect(o.width, 400);
    expect(o.height, 300);
    // 입 안(어두운 곳)에 밝은 치아가 그려짐, 입술 밖은 그대로
    expect(o.getPixel(200, 150).r, greaterThan(150));
    expect(o.getPixel(20, 20).r, closeTo(200, 10));
    // 치아 윤곽 마스크: 가운데(11·21)는 흰색, 13·23 자리·입술 밖은 검정
    final mk = img.decodePng(got!.mask)!;
    expect(mk.width, 400);
    expect(mk.getPixel(200, 150).r, 255);
    expect(mk.getPixel(20, 20).r, 0);
    expect(mk.getPixel(130, 140).r, 0, reason: '13 자리(뺀 치아)');
    expect(t.takeException(), isNull);
  });

  testWidgets('🖐 밀어서 다듬기 화면: 문지르면 바뀐 사진, 안 문지르면 그대로 닫힘', (t) async {
    t.view.physicalSize = const Size(800, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    Uint8List? got;
    var closed = false;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async {
                got = await Navigator.of(ctx).push<Uint8List>(
                  MaterialPageRoute(
                    builder: (_) =>
                        LiquifyScreen(image: photo(), title: 'After 1'),
                  ),
                );
                closed = true;
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('열기'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    for (
      var n = 0;
      n < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      n++
    ) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('🖐 밀어서 다듬기 · After 1'), findsOneWidget);
    expect(find.text('🖐 밀기'), findsOneWidget);
    expect(find.text('↺ 원래대로 붓'), findsOneWidget);
    // 입 안 어두운 곳의 아래 경계를 아래로 밀기
    final c = t.getCenter(find.byKey(const Key('liquifyCanvas')));
    await t.dragFrom(c + const Offset(0, 40), const Offset(0, 60));
    await t.pump();
    await t.runAsync(() async {
      await t.tap(find.text('완성'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await t.pumpAndSettle();
    expect(closed, isTrue);
    expect(got, isNotNull);
    expect(img.decodeJpg(got!)!.width, 400);
    expect(t.takeException(), isNull);
  });

  testWidgets('📁 내 라이브러리 불러오기 → 그 사진 치아로 합성', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final dir = Directory.systemTemp.createTempSync('lib_test');
    CustomLibraryStore.debugDir = dir;
    Uint8List tooth() {
      final im = img.Image(width: 60, height: 90, numChannels: 4);
      img.fillRect(
        im,
        x1: 0,
        y1: 0,
        x2: 59,
        y2: 89,
        color: img.ColorRgba8(10, 200, 30, 255),
      ); // 초록 (구분용)
      return img.encodePng(im);
    }

    debugLibraryImport = [
      ('11.png', tooth()),
      ('12.png', tooth()),
      ('13.png', tooth()),
    ];
    debugLibraryLips = () => const [
      Offset(0.30, 0.40),
      Offset(0.70, 0.40),
      Offset(0.70, 0.63),
      Offset(0.30, 0.63),
    ];
    addTearDown(() {
      CustomLibraryStore.debugDir = null;
      debugLibraryImport = null;
      debugLibraryLips = null;
      dir.deleteSync(recursive: true);
    });
    LibraryResult? got;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  got = await Navigator.of(ctx).push<LibraryResult>(
                    MaterialPageRoute(
                      builder: (_) => LibraryScreen(
                        image: photo(),
                        imageSize: const Size(400, 300),
                      ),
                    ),
                  ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('열기'));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('＋ 내 라이브러리'));
    await t.pumpAndSettle();
    expect(find.text('라이브러리 이름'), findsOneWidget);
    await t.tap(find.text('저장'));
    await t.pump();
    for (
      var n = 0;
      n < 40 && find.textContaining('📁 내 라이브러리 1').evaluate().isEmpty;
      n++
    ) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('내 라이브러리 1'), findsOneWidget);
    expect(find.textContaining('📁 내 라이브러리 1'), findsOneWidget);
    expect(
      File('${dir.path}/tooth_library/내 라이브러리 1/11.png').existsSync(),
      isTrue,
    );
    await t.runAsync(() async {
      await t.tap(find.text('완성'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await t.pumpAndSettle();
    expect(got!.form, '내 라이브러리 1');
    final o = img.decodeJpg(got!.image)!;
    final px = o.getPixel(200, 150); // 중절치 자리 = 불러온 초록 치아 (21 은 11 을 뒤집어 씀)
    expect(px.g, greaterThan(150));
    expect(px.r, lessThan(80));
    expect(t.takeException(), isNull);
  });
}
