import 'dart:typed_data';
import 'dart:ui';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/capture/face_align.dart';
import 'package:dental_app/capture/guided_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

FacePose pose(
  double ax,
  double ay,
  double bx,
  double by, {
  double? yaw,
  double? pitch,
}) => FacePose.fromEyes(Offset(ax, ay), Offset(bx, by), yaw: yaw, pitch: pitch);

Uint8List face() {
  // 회색 바탕에 어두운 원 두 개(눈)와 타원 얼굴 → 윤곽선이 생김
  final im = img.Image(width: 300, height: 400)
    ..clear(img.ColorRgb8(200, 200, 200));
  img.fillCircle(
    im,
    x: 150,
    y: 200,
    radius: 110,
    color: img.ColorRgb8(230, 190, 160),
  );
  img.fillCircle(
    im,
    x: 110,
    y: 170,
    radius: 10,
    color: img.ColorRgb8(30, 30, 30),
  );
  img.fillCircle(
    im,
    x: 190,
    y: 170,
    radius: 10,
    color: img.ColorRgb8(30, 30, 30),
  );
  return img.encodeJpg(im);
}

void main() {
  group('📸 실시간 자동 확인 계산', () {
    final ref = pose(0.38, 0.40, 0.62, 0.40, yaw: 0, pitch: 2);

    test('먼저 찍은 사진과 같으면 모두 ✓', () {
      final r = checkAlign(
        pose(0.381, 0.401, 0.619, 0.40, yaw: 1, pitch: 3),
        ref,
      );
      expect(r.allOk, isTrue);
      expect(r.message, contains('지금 찍으세요'));
      expect(r.items.map((i) => i.label), ['수평', '정면', '고개', '거리', '위치']);
    });

    test('고개 기울어짐 → 수평 ✕ (어느 쪽이 낮은지)', () {
      final r = checkAlign(pose(0.38, 0.38, 0.62, 0.43, yaw: 0, pitch: 2), ref);
      final i = r.items.firstWhere((i) => i.label == '수평');
      expect(i.ok, isFalse);
      expect(i.hint, contains('오른쪽이 낮음'));
      expect(r.allOk, isFalse);
    });

    test('가까우면 물러나라, 멀면 가까이', () {
      final near = checkAlign(
        pose(0.34, 0.40, 0.66, 0.40, yaw: 0, pitch: 2),
        ref,
      );
      expect(
        near.items.firstWhere((i) => i.label == '거리').hint,
        contains('뒤로'),
      );
      final far = checkAlign(
        pose(0.41, 0.40, 0.59, 0.40, yaw: 0, pitch: 2),
        ref,
      );
      expect(
        far.items.firstWhere((i) => i.label == '거리').hint,
        contains('가까이'),
      );
    });

    test('고개 숙임·들림, 옆으로 돌림, 위치', () {
      final r = checkAlign(
        pose(0.46, 0.40, 0.70, 0.40, yaw: 12, pitch: 12),
        ref,
      );
      expect(r.items.firstWhere((i) => i.label == '정면').ok, isFalse);
      expect(
        r.items.firstWhere((i) => i.label == '고개').hint,
        contains('턱을 조금 내려'),
      );
      expect(r.items.firstWhere((i) => i.label == '위치').hint, contains('오른쪽'));
    });

    test('기준 사진이 없으면 화면 가이드(눈동자선·중앙선) 기준, 고개 각도는 안 봄', () {
      final r = checkAlign(
        pose(0.38, 0.40, 0.62, 0.40, yaw: 0, pitch: 15),
        null,
      );
      expect(r.items.map((i) => i.label), isNot(contains('고개')));
      expect(r.allOk, isTrue);
    });

    test('얼굴 없음', () {
      final r = checkAlign(null, ref);
      expect(r.face, isFalse);
      expect(r.message, contains('얼굴'));
    });
  });

  test('윤곽선 고스트: 경계선만 남고 바탕은 투명', () {
    final png = ghostOutline(face());
    final o = img.decodePng(png)!;
    expect(o.numChannels, 4);
    expect(o.getPixel(5, 5).a, 0); // 바탕 투명
    var lines = 0;
    for (final p in o) {
      if (p.a > 0) lines++;
    }
    expect(lines, greaterThan(200)); // 얼굴·눈 경계
  });

  testWidgets('📸 촬영 화면: 고스트(반투명·윤곽선·끄기) · 투명도 · 가이드선 · 자동 확인 · 셔터', (t) async {
    t.view.physicalSize = const Size(800, 1280);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    debugCameraPreview = const ColoredBox(color: Color(0xFF334455));
    final shot = face();
    debugCameraShot = shot;
    debugLiveAlign = checkAlign(
      pose(0.38, 0.38, 0.62, 0.43, yaw: 0, pitch: 2),
      pose(0.38, 0.40, 0.62, 0.40, yaw: 0, pitch: 2),
    );
    addTearDown(() {
      debugCameraPreview = null;
      debugCameraShot = null;
      debugLiveAlign = null;
    });
    Uint8List? got;
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  got = await openGuidedCamera(ctx, slot: 2, ghost: face()),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('열기'));
    await t.pumpAndSettle();
    expect(find.text('원본 2 촬영 · 개구기'), findsOneWidget);
    expect(find.text('반투명 사진'), findsOneWidget);
    expect(find.text('투명도 35%'), findsOneWidget);
    expect(find.byType(Opacity), findsWidgets); // 반투명 고스트
    expect(find.text('수평 ✕'), findsOneWidget);
    expect(find.textContaining('고개가 기울었어요'), findsOneWidget);
    // 원본 2 는 교합평면선 없음, 고스트가 있으면 타원도 없음
    final gp = t.widget<CustomPaint>(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is GuidePainter,
      ),
    );
    expect((gp.painter! as GuidePainter).occlusal, isFalse);
    expect((gp.painter! as GuidePainter).oval, isFalse);
    // 윤곽선 · 끄기
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    await t.tap(find.text('윤곽선'));
    await t.pump();
    await t.tap(find.text('끄기'));
    await t.pump();
    expect(find.textContaining('투명도'), findsNothing);
    await t.tap(find.text('가이드선 끄기'));
    await t.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is GuidePainter,
      ),
      findsNothing,
    );
    await t.tap(find.bySemanticsLabel('촬영'));
    await t.pumpAndSettle();
    expect(got, same(shot));
    expect(t.takeException(), isNull);
  });

  testWidgets('📸 원본 1(미소)·고스트 없음: 타원·교합평면선', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    debugCameraPreview = const ColoredBox(color: Color(0xFF334455));
    addTearDown(() => debugCameraPreview = null);
    await t.pumpWidget(
      MaterialApp(theme: buildTheme(), home: const GuidedCameraScreen(slot: 1)),
    );
    await t.pump();
    expect(find.text('원본 1 촬영 · 자연스러운 미소'), findsOneWidget);
    expect(find.text('반투명 사진'), findsNothing);
    final gp = t.widget<CustomPaint>(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is GuidePainter,
      ),
    );
    expect((gp.painter! as GuidePainter).occlusal, isTrue);
    expect((gp.painter! as GuidePainter).oval, isTrue);
    expect(t.takeException(), isNull);
  });
}
