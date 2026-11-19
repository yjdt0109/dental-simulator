import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/cast/cast_service.dart';
import 'package:dental_app/models/clinic_profile.dart';
import 'package:dental_app/records/records.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:dental_app/simulator/simulator_screen.dart';
import 'package:dental_app/simulator/smile_screen.dart';
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
  test('비교 목록: 원본 → 변환 결과 → 불러온 사진 차례, 최대 2장, 같은 사진은 한 번만', () {
    final p = PatientPhoto(
      id: 'a',
      name: '',
      type: '',
      time: '',
      beforeBytes: jpg(10),
      imageSize: const Size(120, 90),
    );
    final s1 = jpg(20), s2 = jpg(30);
    expect(p.addExtra(s1, '😊 미소 1'), -1);
    expect(p.addExtra(s2, '😊 미소 2'), -2);
    expect(p.addExtra(s1, '다시'), -1); // 같은 사진
    expect(p.listOrder, [0, -1, -2]);
    expect(p.compare, [0]);
    p.toggleSel(-2);
    expect(p.compare, [0, -2]);
    p.toggleSel(-1);
    expect(p.compare, [-1, -2]); // 가장 먼저 고른 원본이 빠짐, 목록 위쪽이 왼쪽
    expect(identical(p.bytesOf(-2), s2), isTrue);
    p.addResult(jpg(40), 'k');
    expect(p.listOrder, [0, 1, -1, -2]);
    p.sel = [-1, 1];
    expect(p.compare, [1, -1]); // 변환 결과가 불러온 사진보다 위
    p.smile = s2;
    p.smileAfter = jpg(50);
    p.smileFrom = '1번';
    p.noteSmile();
    expect(p.extras.length, 3); // s2 는 이미 있음 → 미소 미리보기만 추가
    expect(p.extras.last.label, '😊 미소 미리보기 1');
  });

  testWidgets('첫 화면(변환 전): 이전 변환 불러오기·미소 미리보기 버튼, 미소 사진 여러 장 → 브리핑에서 골라 비교', (
    t,
  ) async {
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
    expect(find.text('이전 변환 불러오기'), findsOneWidget);
    expect(find.text('😊 미소 미리보기'), findsOneWidget);
    // PC 에서 미소 사진 2장 + 환자 기록의 미소 사진
    late PatientRecord rec;
    await t.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('bna_extras');
      PatientRecords.instance
        ..overrideDir = tmp
        ..records.clear();
      rec = await PatientRecords.instance.add(
        name: '이서연',
        treatments: const ['미백'],
        teeth: const [],
        shade: 'A1',
        memo: '',
        photoType: '정면',
        before: jpg(120),
        results: const [],
        smile: jpg(150),
        smileAfter: jpg(240),
      );
      CastService.instance.onRemoteCmd?.call({
        't': 'smilePhoto',
        'v': base64Encode(jpg(60)),
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      CastService.instance.onRemoteCmd?.call({
        't': 'smilePhoto',
        'v': base64Encode(jpg(70)),
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      CastService.instance.onRemoteCmd?.call({
        't': 'smileFromRec',
        'v': rec.id,
      });
      await Future<void>.delayed(const Duration(milliseconds: 900));
    });
    await _settle(t);
    // 브리핑 켜기 → 왼쪽 목록에 불러온 차례대로
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({'t': 'briefing', 'v': true});
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settle(t);
    expect(find.textContaining('비교할 사진'), findsOneWidget);
    final labels = ['원본', '😊 미소 1', '😊 미소 2', '😊 이서연 미소', '😊 이서연 미소 미리보기'];
    double y(String s) => t.getTopLeft(find.text(s).first).dy;
    for (final l in labels) {
      expect(find.text(l), findsWidgets, reason: l);
    }
    for (var i = 1; i < labels.length; i++) {
      expect(y(labels[i]), greaterThan(y(labels[i - 1])), reason: labels[i]);
    }
    // 목록에서 미소 1 과 기록 미소 미리보기를 눌러 비교 (PC 는 위치 번호로)
    await t.tap(find.text('😊 미소 1'));
    await t.pump();
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({'t': 'cmpToggle', 'v': 4});
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await _settle(t);
    expect(find.byType(SliderCompare), findsOneWidget);
    expect(find.text('사진 추가'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('미소 미리보기: 변환 전에도 열리고, 환자 기록에서 여러 장 → 비교 목록 + 첫 미소로 미리보기', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final p = PatientPhoto(
      id: 'x',
      name: '',
      type: '',
      time: '',
      beforeBytes: jpg(10),
      imageSize: const Size(120, 90),
    );
    final a = jpg(200, w: 400, h: 300), b = jpg(220, w: 400, h: 300);
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SmilePreviewScreen(
          photo: p,
          pickRecords: () async => [
            (bytes: a, label: '박지은 원본', sub: '환자 기록', smile: false),
            (bytes: b, label: '😊 박지은 미소', sub: '환자 기록', smile: true),
          ],
        ),
      ),
    );
    expect(find.textContaining('아직 변환 전이에요'), findsOneWidget);
    expect(find.textContaining('지금 결과 쓰기'), findsNothing);
    await t.runAsync(() async {
      await t.tap(find.text('🗂 환자 기록에서'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await t.pump();
    expect(identical(p.smile, b), isTrue); // 미소 사진으로 미리보기
    expect([for (final e in p.extras) e.label], ['박지은 원본', '😊 박지은 미소']);
    expect(find.textContaining('2장을 비교 목록에'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
