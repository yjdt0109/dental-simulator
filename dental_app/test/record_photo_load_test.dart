import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/cast/cast_service.dart';
import 'package:dental_app/models/clinic_profile.dart';
import 'package:dental_app/qa/qa_remote.dart';
import 'package:dental_app/records/records.dart';
import 'package:dental_app/records/records_screen.dart';
import 'package:dental_app/simulator/compare_viewer.dart';
import 'package:dental_app/simulator/sim_import.dart';
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

Uint8List jpg(int r) => Uint8List.fromList(
  img.encodeJpg(
    img.Image(width: 120, height: 90)..clear(img.ColorRgb8(r, 90, 90)),
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
  testWidgets('🗂 기록 사진 한 장씩 불러오기: 시작 화면에서 기록 열기 → [이 사진만 불러오기] → 차례대로', (
    t,
  ) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late PatientRecord rec;
    await t.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('bna_one');
      PatientRecords.instance
        ..overrideDir = tmp
        ..records.clear();
      rec = await PatientRecords.instance.add(
        name: '최유나',
        treatments: const ['라미네이트'],
        teeth: const [11, 21],
        shade: 'A1',
        memo: '',
        photoType: '정면',
        before: jpg(120),
        results: [
          (bytes: jpg(200), label: '최유나 1번 (B)', engine: 'B', check: ''),
          (bytes: jpg(230), label: '최유나 2번 (C)', engine: 'C', check: ''),
        ],
        smile: jpg(150),
        smileAfter: jpg(240),
      );
    });
    // 시작 화면의 [시뮬레이터 불러오기] = 시뮬레이터를 열자마자 환자 기록
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile, openRecords: true),
      ),
    );
    await _settle(
      t,
      until: () => find.byType(RecordsScreen).evaluate().isNotEmpty,
    );
    expect(find.byType(RecordsScreen), findsOneWidget);
    // 기록 상세 화면에서 2번만 먼저
    Navigator.of(t.element(find.byType(RecordsScreen))).push(
      MaterialPageRoute<void>(builder: (_) => RecordDetailScreen(record: rec)),
    );
    await _settle(t);
    expect(find.text('🖼 시뮬레이터로 모두 불러오기'), findsNothing); // 한 장씩만
    expect(find.text('이 사진만 불러오기'), findsWidgets);
    late String msg;
    await t.runAsync(() async {
      msg = await RecordPhotoLoader.run(rec.id, 'after_2.jpg');
    });
    await _settle(t);
    expect(msg, contains('최유나 2번 (C)'));
    // 같은 사진 다시 → 이미 불러옴
    await t.runAsync(() async {
      msg = await RecordPhotoLoader.run(rec.id, 'after_2.jpg');
    });
    expect(msg, contains('이미'));
    // PC 에서 한 장씩: 미소 사진 → 미소 미리보기
    await t.runAsync(() async {
      await QaRemote.instance.handle('recPhoto', {
        'id': rec.id,
        'f': 'smile_before.jpg',
      });
      await QaRemote.instance.handle('recPhoto', {
        'id': rec.id,
        'f': 'smile_after.jpg',
      });
      await QaRemote.instance.handle('recPhoto', {
        'id': rec.id,
        'f': '../x.jpg',
      }); // 이상한 이름은 무시
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await _settle(t);
    // 화면을 닫고 시뮬레이터 확인: 결과는 2번 하나만, 미소 비교 가능
    Navigator.of(t.element(find.byType(RecordDetailScreen))).pop();
    await _settle(t);
    Navigator.of(t.element(find.byType(RecordsScreen))).pop();
    await _settle(t);
    expect(find.textContaining('최유나 1번 (C)'), findsWidgets); // 불러온 결과 1장 (C)
    expect(find.textContaining('2번'), findsNothing);
    expect(find.text('😊 미소 비교'), findsOneWidget);
    expect(find.byType(RoiEditor), findsNothing);
    // 브리핑 목록에서 ✕ 로 결과 빼기 (원본은 ✕ 없음)
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({'t': 'briefing', 'v': true});
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await _settle(t);
    expect(find.text('기록·사진 추가'), findsOneWidget);
    final before = find.byTooltip('목록에서 빼기').evaluate().length;
    expect(before, greaterThanOrEqualTo(2)); // 결과 + 미소 사진들
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({
        't': 'cmpRemove',
        'v': 0,
      }); // 원본은 못 뺌
      CastService.instance.onRemoteCmd?.call({
        't': 'cmpRemove',
        'v': 1,
      }); // 1번 결과
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await _settle(t);
    expect(find.byTooltip('목록에서 빼기').evaluate().length, before - 1);
    // 같은 사진을 다시 한 장 불러오기 → 다시 들어감
    await t.runAsync(() async {
      await RecordPhotoLoader.run(rec.id, 'after_2.jpg');
    });
    await _settle(t);
    expect(find.byTooltip('목록에서 빼기').evaluate().length, before);
    expect(t.takeException(), isNull);
  });

  testWidgets('직접 올린 환자 화면: 다른 기록의 사진은 그 환자 비교 목록 끝에 한 장씩', (t) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late PatientRecord rec;
    await t.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('bna_one2');
      PatientRecords.instance
        ..overrideDir = tmp
        ..records.clear();
      rec = await PatientRecords.instance.add(
        name: '한지수',
        treatments: const ['미백'],
        teeth: const [],
        shade: 'A1',
        memo: '',
        photoType: '정면',
        before: jpg(110),
        results: [
          (bytes: jpg(210), label: '한지수 1번 (B)', engine: 'B', check: ''),
        ],
      );
    });
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const SimulatorHomeScreen(profile: _profile),
      ),
    );
    await _settle(t, until: () => find.byType(RoiEditor).evaluate().isNotEmpty);
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({
        't': 'photo',
        'v': base64Encode(jpg(60)),
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await _settle(t);
    late String msg;
    await t.runAsync(() async {
      msg = await RecordPhotoLoader.run(rec.id, 'after_1.jpg');
      await RecordPhotoLoader.run(rec.id, 'before.jpg');
    });
    await _settle(t);
    expect(msg, contains('비교 목록에 불러왔습니다'));
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({'t': 'briefing', 'v': true});
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await _settle(t);
    double y(String s) => t.getTopLeft(find.text(s).first).dy;
    expect(y('한지수 원본'), greaterThan(y('한지수 1번 (B)'))); // 불러온 차례대로
    expect(y('한지수 1번 (B)'), greaterThan(y('원본')));
    expect(t.takeException(), isNull);
  });
}
