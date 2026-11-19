import 'dart:io';

import 'package:dental_app/app_theme.dart';
import 'package:dental_app/qa/qa_remote.dart';
import 'package:dental_app/records/records.dart';
import 'package:dental_app/records/records_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List jpg(int r) => img.encodeJpg(
  img.Image(width: 80, height: 60)..clear(img.ColorRgb8(r, 100, 100)),
);

Future<PatientRecord> addRec(
  String name,
  DateTime at,
  List<String> tx, {
  int n = 2,
}) => PatientRecords.instance.add(
  name: name,
  treatments: tx,
  teeth: const [11, 21],
  shade: 'A1',
  memo: '상담 메모 $name',
  photoType: '정면',
  before: jpg(10),
  results: [
    for (var i = 1; i <= n; i++)
      (
        bytes: jpg(100 + i * 40),
        label: '$name $i번 (B)',
        engine: 'B',
        check: i == n ? '✓ 무삭제 검사 통과' : '',
      ),
  ],
  at: at,
);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bna_records');
    PatientRecords.instance
      ..overrideDir = tmp
      ..records.clear();
  });

  test('저장: 날짜 폴더 › 환자이름 폴더 › 사진·정보 + 다시 열어도 그대로', () async {
    final r = await addRec('김민수', DateTime(2026, 11, 18, 14, 30), [
      '무삭제 라미네이트',
    ]);
    expect(r.folder, startsWith('2026-11-18/김민수/1430_'));
    final dir = Directory('${tmp.path}/${r.folder}');
    expect(File('${dir.path}/before.jpg').existsSync(), isTrue);
    expect(File('${dir.path}/after_1.jpg').existsSync(), isTrue);
    expect(File('${dir.path}/after_2.jpg').existsSync(), isTrue);
    expect(
      File('${dir.path}/record.json').readAsStringSync(),
      contains('"name": "김민수"'),
    );
    PatientRecords.instance.records.clear();
    await PatientRecords.instance.load();
    expect(
      PatientRecords.instance.records.single.shots.last.check,
      '✓ 무삭제 검사 통과',
    );
  });

  test('검색: 이름·날짜·치료종류 + 날짜 › 이름 묶기 + 삭제 시 빈 폴더 정리', () async {
    final s = PatientRecords.instance;
    final a = await addRec('김민수', DateTime(2026, 11, 18, 10, 0), ['무삭제 라미네이트']);
    await addRec('김민수', DateTime(2026, 11, 18, 15, 0), ['미백']);
    await addRec('이영희', DateTime(2026, 11, 18, 11, 0), ['교정']);
    await addRec('박철수', DateTime(2026, 11, 17, 9, 0), ['라미네이트', '미백']);
    expect(s.search(query: '김민수').length, 2);
    expect(s.search(query: '11.17').single.name, '박철수');
    expect(s.search(query: '2026-11-18').length, 3);
    expect(s.search(query: '11월 18일').length, 3);
    expect(s.search(query: '미백').length, 2);
    expect(s.search(query: '김민수 미백').single.treatments, ['미백']);
    expect(s.search(tx: '교정').single.name, '이영희');
    expect(s.search(day: DateTime(2026, 11, 17)).single.name, '박철수');
    expect(s.search(query: '없는사람'), isEmpty);
    final tree = groupRecords(s.search());
    expect(tree.map((d) => d.$1), ['2026-11-18', '2026-11-17']);
    expect(tree.first.$2.map((n) => n.$1), ['김민수', '이영희']);
    expect(tree.first.$2.first.$2.length, 2);
    // 삭제
    final b = s.search(query: '박철수').single;
    await s.remove(b);
    expect(Directory('${tmp.path}/2026-11-17').existsSync(), isFalse);
    await s.remove(a);
    expect(
      Directory('${tmp.path}/2026-11-18/김민수').existsSync(),
      isTrue,
    ); // 15시 기록은 남음
    expect(s.records.length, 2);
  });

  test('PC 공유: 목록(작은 사진) · 상세 사진 · 삭제', () async {
    final puts = <String, Object?>{};
    QaRemote.instance
      ..putOverride = ((p, v) async => puts[p] = v)
      ..resetForTest();
    addTearDown(() => QaRemote.instance.putOverride = null);
    final r = await addRec('김민수', DateTime(2026, 11, 18, 14, 30), [
      '무삭제 라미네이트',
    ]);
    await QaRemote.instance.publishRecords();
    final items = (puts['records'] as Map)['items'] as List;
    final it = items.single as Map;
    expect(it['name'], '김민수');
    expect(it['dayText'], '2026.11.18 (수)');
    expect((it['thumbs'] as Map).keys, containsAll(['before', 'after']));
    await QaRemote.instance.handle('recFull', r.id);
    final full = puts['recordFull'] as Map;
    expect((full['before'] as String).isNotEmpty, isTrue);
    expect((full['shots'] as List).length, 2);
    await QaRemote.instance.handle('recDel', r.id);
    expect(PatientRecords.instance.records, isEmpty);
  });

  for (final size in const [Size(390, 844), Size(1280, 900)]) {
    testWidgets('기록 화면: 날짜 › 이름 폴더, 검색, 상세 $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        await addRec('김민수', DateTime(2026, 11, 18, 14, 30), ['무삭제 라미네이트']);
        await addRec('이영희', DateTime(2026, 11, 17, 9, 5), ['교정'], n: 1);
      });
      await t.pumpWidget(
        MaterialApp(theme: buildTheme(), home: const RecordsScreen()),
      );
      await t.pump();
      expect(find.text('2026.11.18 (수)'), findsOneWidget);
      expect(find.text('2026.11.17 (화)'), findsOneWidget);
      expect(find.text('김민수 님'), findsOneWidget);
      expect(find.text('이영희 님'), findsOneWidget);
      await t.enterText(find.byType(TextField), '교정');
      await t.pump();
      expect(find.text('김민수 님'), findsNothing);
      expect(find.text('이영희 님'), findsOneWidget);
      await t.enterText(find.byType(TextField), '11.18');
      await t.pump();
      expect(find.text('김민수 님'), findsOneWidget);
      expect(find.text('이영희 님'), findsNothing);
      await t.enterText(find.byType(TextField), '');
      await t.pump();
      await t.tap(find.text('교정').first); // 치료 필터 칩
      await t.pump();
      expect(find.text('김민수 님'), findsNothing);
      await t.tap(find.text('교정').first);
      await t.pump();
      // 폴더 접기
      await t.tap(find.text('2026.11.18 (수)'));
      await t.pump();
      expect(find.text('김민수 님'), findsNothing);
      await t.tap(find.text('2026.11.18 (수)'));
      await t.pump();
      await t.tap(find.textContaining('14:30'));
      await t.pumpAndSettle();
      expect(find.text('김민수 님 · 2026.11.18 (수)'), findsOneWidget);
      expect(find.text('원본 (치료 전)'), findsOneWidget);
      expect(find.text('김민수 2번 (B)'), findsWidgets);
      expect(find.textContaining('🦷 ✓ 무삭제 검사 통과'), findsOneWidget);
      expect(find.text('🖼 시뮬레이터로 불러오기'), findsOneWidget);
      expect(find.text('😊 미소 미리보기'), findsOneWidget);
      await t.scrollUntilVisible(
        find.textContaining('2026-11-18 › 김민수 › 1430_'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.textContaining('2026-11-18 › 김민수 › 1430_'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
