import 'dart:typed_data';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/simulator/resize_session.dart';
import 'package:dental_app/simulator/tooth_resize.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List photo() {
  final im = img.Image(width: 400, height: 300)
    ..clear(img.ColorRgb8(60, 25, 30));
  img.fillRect(
    im,
    x1: 160,
    y1: 100,
    x2: 204,
    y2: 200,
    color: img.ColorRgb8(235, 225, 205),
  );
  img.fillRect(
    im,
    x1: 210,
    y1: 100,
    x2: 254,
    y2: 200,
    color: img.ColorRgb8(235, 225, 205),
  );
  return img.encodeJpg(im);
}

const teeth = <ResizeTooth>[
  (label: '#11', box: Rect.fromLTRB(0.4, 1 / 3, 0.5125, 0.67), upper: true),
  (label: '#21', box: Rect.fromLTRB(0.525, 1 / 3, 0.6375, 0.67), upper: true),
];

void main() {
  for (final size in const [Size(390, 844), Size(1280, 900)]) {
    testWidgets('치아 크기 조절: ± 버튼 · 무삭제면 마진 고정·줄이기 불가 · 적용 $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      Uint8List? result;
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async =>
                      result = await Navigator.of(c).push<Uint8List>(
                        MaterialPageRoute(
                          builder: (_) => ToothResizeScreen(
                            image: photo(),
                            imageSize: const Size(400, 300),
                            teeth: teeth,
                            noPrep: true,
                          ),
                        ),
                      ),
                  child: const Text('열기'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('열기'));
      await t.pumpAndSettle();
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await t.pump();
      expect(find.text('고정'), findsOneWidget); // 상악: 위(마진) 고정
      IconButton btn(String tip) => t.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip(tip),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(btn('위 키우기').onPressed, isNull); // 상악 마진 고정
      expect(btn('아래 줄이기').onPressed, isNull); // 0% 에서 줄이기 불가
      await t.tap(find.byTooltip('아래 키우기'));
      await t.tap(find.byTooltip('아래 키우기'));
      await t.pump();
      expect(find.text('+6%'), findsOneWidget);
      await t.tap(find.text('#21'));
      await t.pump();
      await t.ensureVisible(find.byTooltip('오른쪽 키우기'));
      await t.tap(find.byTooltip('오른쪽 키우기'));
      await t.pump();
      expect(find.text('#11 ●'), findsOneWidget);
      await t.runAsync(() async {
        await t.tap(find.text('적용'));
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await t.pumpAndSettle();
      expect(result, isNotNull);
      final out = img.decodeJpg(result!)!;
      expect(out.getPixel(182, 203).b, greaterThan(150)); // #11 아래로 길어짐
      expect(t.takeException(), isNull);
    });
  }

  test('늘이기 계산: 아무것도 안 바꾸면 그대로', () {
    final src = img.decodeJpg(photo())!;
    expect(
      identical(applyGrows(src, [(teeth[0].box, const Grow(), null)]), src),
      isTrue,
    );
  });

  test('조절 세션: 무삭제 규칙 · 3%씩 · 번호 · 이미 고른 치아 탭 · PC 상태', () async {
    final rs = ResizeSession(
      image: photo(),
      noPrep: true,
      teeth: teeth,
      chartTeeth: const [11, 21],
    );
    expect(rs.stepTooth(0, GrowSide.up, 1), isFalse); // 상악 마진(위) 고정
    expect(rs.stepTooth(0, GrowSide.down, -1), isFalse); // 작아지지 않음
    expect(rs.stepTooth(0, GrowSide.down, 1), isTrue);
    expect(rs.pct(0, GrowSide.down), 3);
    // 이미 고른 치아 안을 탭하면 SAM 없이 그 치아 선택
    expect(await rs.tap(teeth[1].box.center, falKey: null), isNull);
    expect(rs.sel, 1);
    expect(
      await rs.tap(const Offset(0.05, 0.05), falKey: null),
      contains('Fal.ai'),
    );
    rs.addTooth(const Rect.fromLTRB(0.3, 0.33, 0.39, 0.67), true);
    expect(rs.teeth.map((t) => t.label), [
      '상악 2',
      '상악 3',
      '상악 1',
    ]); // 차트(2개)와 수가 달라 '상악 n'
    rs.removeTooth(2);
    expect(rs.teeth.map((t) => t.label), ['#11', '#21']);
    final j = rs.toJson();
    expect(((j['teeth'] as List).first as Map)['p'], containsPair('down', 3));
    final out = img.decodeJpg(await rs.apply())!;
    expect(out.width, 400);
  });

  test('윤곽만 키우기: 고른 치아만 커지고 잇몸·옆 치아는 그대로', () {
    final src = img.decodeJpg(photo())!;
    // #11 마스크 (160..204 x 100..200)
    final mask = img.Image(width: 400, height: 300, numChannels: 1);
    img.fillRect(
      mask,
      x1: 160,
      y1: 100,
      x2: 204,
      y2: 200,
      color: img.ColorRgb8(255, 255, 255),
    );
    final out = applyGrows(src, [
      (teeth[0].box, const Grow(down: 0.04, right: 0.02), mask),
    ]);
    expect(out.getPixel(182, 208).b, greaterThan(150)); // 아래로 길어짐
    expect(out.getPixel(182, 225).r, lessThan(120)); // 그 아래는 그대로
    final gum = out.getPixel(182, 80), og = src.getPixel(182, 80);
    expect(
      (gum.r - og.r).abs() + (gum.g - og.g).abs(),
      lessThan(6),
    ); // 잇몸(위) 그대로
    final far = out.getPixel(240, 150), of = src.getPixel(240, 150);
    expect((far.b - of.b).abs(), lessThan(6)); // 옆 치아 안쪽 그대로
    final left = out.getPixel(150, 150), ol = src.getPixel(150, 150);
    expect((left.r - ol.r).abs(), lessThan(6)); // 반대쪽(왼쪽) 바깥 그대로
  });
}
