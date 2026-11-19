import 'dart:typed_data';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:dental_app/simulator/smile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List face() {
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
  return img.encodeJpg(im);
}

void main() {
  for (final size in const [Size(390, 844), Size(1280, 900)]) {
    testWidgets('😊 미소 미리보기: 사진 올리기 → 붓으로 치아 영역 → 입히기 → 비교 $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final p = PatientPhoto(
        id: 'x',
        name: '김민수',
        type: '정면',
        time: '방금',
        beforeBytes: face(),
        imageSize: const Size(400, 300),
      );
      final white = Uint8List.fromList(
        img.encodeJpg(
          img.Image(width: 400, height: 300)
            ..clear(img.ColorRgb8(250, 250, 245)),
        ),
      );
      Object? region;
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: SmilePreviewScreen(
            photo: p,
            after: white,
            afterLabel: '김민수 1번 (B)',
            pick: (_) async => face(),
            make: (s, a, r) async {
              region = r;
              return white;
            },
          ),
        ),
      );
      expect(find.textContaining('환자의 미소 사진을 올려 주세요'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('😊 미소에 입히기'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await t.runAsync(() async {
        await t.tap(find.text('갤러리에서 고르기 (여러 장)'));
        await Future<void>.delayed(const Duration(milliseconds: 800));
      });
      await t.pump();
      expect(p.smile, isNotNull);
      expect(find.textContaining('자동 찾기를 쓸 수 없어요'), findsNothing); // 자동은 조용히 시도
      // 붓 [더하기]로 치아 영역 칠하기
      await t.tap(find.byTooltip('선택 다듬기: 손으로 칠해 선택 영역 더하기'));
      await t.pump();
      final r = t.getRect(
        find.byType(InteractiveViewer).evaluate().isEmpty
            ? find.byType(Stack).first
            : find.byType(Stack).first,
      );
      await t.runAsync(() async {
        await t.dragFrom(r.center, const Offset(20, 0));
        await Future<void>.delayed(const Duration(milliseconds: 800));
      });
      await t.pump();
      expect(p.smileSet!.union, isNotNull);
      await t.ensureVisible(find.text('😊 미소에 입히기'));
      await t.runAsync(() async {
        await t.tap(find.text('😊 미소에 입히기'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await t.pump();
      expect(region, isNotNull);
      expect(p.smileAfter, isNotNull);
      expect(p.smileFrom, '김민수 1번 (B)');
      expect(find.textContaining('완성!'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
