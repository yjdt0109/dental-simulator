import 'dart:typed_data';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/models/clinic_profile.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dental_app/ai/smile_match.dart';
import 'package:dental_app/cast/cast_service.dart';
import 'package:dental_app/qa/qa_remote.dart';
import 'package:dental_app/records/records.dart';
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
  testWidgets('🖼 QA·보관함 결과를 메인 화면으로: 같은 원본 → N번 추가 / 다른 사진 → 새 환자 + 1번', (
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
    expect(SimImport.handler, isNotNull);
    final orig = QaRemote.instance.originalOf!()!;
    final result = Uint8List.fromList(
      img.encodeJpg(
        img.Image(width: 80, height: 60)..clear(img.ColorRgb8(240, 240, 230)),
      ),
    );
    late String msg;
    await t.runAsync(() async {
      msg = await SimImport.run(original: orig, result: result, tag: 'QA·B');
    });
    await _settle(t);
    expect(msg, contains('1번으로 가져왔습니다'));
    expect(find.byType(RoiEditor), findsNothing); // 결과 비교 화면으로
    expect(find.textContaining('1번 (QA·B)'), findsWidgets);
    // 다른 사진(보관함 케이스) → 새 환자
    final other = Uint8List.fromList(
      img.encodeJpg(
        img.Image(width: 120, height: 90)..clear(img.ColorRgb8(150, 60, 60)),
      ),
    );
    await t.runAsync(() async {
      msg = await SimImport.run(
        original: other,
        result: result,
        tag: '보관함·옵션 A',
        treatments: const ['라미네이트'],
      );
    });
    await _settle(t);
    expect(msg, contains('1번으로 가져왔습니다'));
    expect(find.textContaining('(보관함·옵션 A)'), findsWidgets);
    expect(identical(QaRemote.instance.originalOf!(), other), isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('🗂 환자 기록 → 시뮬레이터로 다시 불러오기 (결과·상담 내용·미소 사진까지)', (t) async {
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
    Uint8List jpg(int r) => Uint8List.fromList(
      img.encodeJpg(
        img.Image(width: 120, height: 90)..clear(img.ColorRgb8(r, 90, 90)),
      ),
    );
    late PatientRecord rec;
    await t.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('bna_load');
      PatientRecords.instance
        ..overrideDir = tmp
        ..records.clear();
      rec = await PatientRecords.instance.add(
        name: '박지은',
        treatments: const ['라미네이트'],
        teeth: const [11, 21],
        shade: 'A1',
        memo: '다음 주 재상담',
        photoType: '정면',
        before: jpg(120),
        results: [
          (bytes: jpg(200), label: '박지은 1번 (B)', engine: 'B', check: ''),
          (bytes: jpg(230), label: '박지은 2번 (크기조절)', engine: '크기조절', check: ''),
        ],
        smile: jpg(150),
        smileAfter: jpg(240),
      );
    });
    await t.runAsync(() async {
      await QaRemote.instance.handle(
        'recLoad',
        rec.id,
      ); // PC [🖼 시뮬레이터로 불러오기] 와 같은 경로
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await _settle(t);
    expect(find.textContaining('박지은'), findsWidgets);
    expect(find.textContaining('2번 (크기조절)'), findsWidgets);
    expect(find.text('😊 미소 비교'), findsOneWidget); // 미소 사진도 함께
    expect(find.text('다음 주 재상담'), findsOneWidget); // 상담 메모
    // 불러온 뒤 새 미소 사진을 올리면 → 같은 환자 기록 폴더에 저장
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({
        't': 'smilePhoto',
        'v': base64Encode(jpg(90)),
      });
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await _settle(t);
    final dir = Directory(
      '${PatientRecords.instance.overrideDir!.path}/${rec.folder}',
    );
    expect(File('${dir.path}/smile_before.jpg').existsSync(), isTrue);
    expect(
      File('${dir.path}/smile_after.jpg').existsSync(),
      isFalse,
    ); // 새 사진이라 예전 결과는 지움
    expect(PatientRecords.instance.records.single.hasSmile, isTrue);
    expect(find.textContaining('미소 사진을 2026.'), findsWidgets);
    // 🦷 PC 에서 보철 사진 정밀 매칭: 지금 결과를 2번으로 → 시작 → ③ 최종이 미소 비교로 + 기록 저장
    final steps = <String>[];
    debugMatchOverride = (s, pr, step) async {
      step('① 📍 정렬 중…');
      steps.add('run');
      return MatchResult(
        align: AlignOut(
          alignedTeeth: Uint8List(0),
          mask: Uint8List(0),
          crop: Uint8List(0),
          residual: 0.003,
          eyes: true,
          scale: 1.0,
          degrees: 0.5,
        ),
        composite: jpg(10),
        stage1: jpg(20),
        finalImage: jpg(250),
      );
    };
    addTearDown(() => debugMatchOverride = null);
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({'t': 'matchRun'}); // 2번 없음 → 안내만
      CastService.instance.onRemoteCmd?.call({'t': 'matchUseAfter'});
      CastService.instance.onRemoteCmd?.call({'t': 'matchRun'});
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await _settle(t);
    expect(steps, ['run']);
    expect(find.textContaining('보철 사진 정밀 매칭'), findsWidgets);
    expect(File('${dir.path}/smile_after.jpg').existsSync(), isTrue);
    // ① 정렬 합성을 골라 미소 비교에 쓰기
    await t.runAsync(() async {
      CastService.instance.onRemoteCmd?.call({'t': 'matchPick', 'v': 1});
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await _settle(t);
    expect(find.textContaining('① 정렬 합성'), findsWidgets);
    expect(t.takeException(), isNull);
  });
}
