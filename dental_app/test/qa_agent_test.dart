import 'dart:convert';
import 'dart:io';

import 'package:dental_app/ai/pipeline.dart';
import 'package:dental_app/qa/archive.dart';
import 'package:dental_app/qa/archive_screen.dart';
import 'package:dental_app/qa/qa_agent.dart';
import 'package:dental_app/qa/qa_remote.dart';
import 'package:dental_app/qa/qa_screen.dart';
import 'package:dental_app/qa/qa_session.dart';
import 'package:dental_app/ai/ai_service.dart';
import 'package:dental_app/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

Uint8List jpg(int r, int g, int b) => img.encodeJpg(
  img.Image(width: 64, height: 48)..clear(img.ColorRgb8(r, g, b)),
);

QaSetup setup({List<String> tx = const ['교정']}) => QaSetup(
  original: jpg(200, 0, 0),
  target: jpg(0, 200, 0),
  treatments: tx,
  teeth: const [11, 21],
  shade: 'A1',
  strength: 90,
  request: '시작 요청',
  lines: const [],
  lockGum: false,
);

/// 회차마다 정해 둔 점수를 주는 가짜 채점기 (엔진별)
QaAgent fakeAgent(
  Map<Engine, List<int>> scores, {
  Set<Engine> broken = const {},
  List<QaParams>? seen,
}) {
  final round = <Engine, int>{};
  return QaAgent(
    generate: (e, s, p, prompt) async {
      if (broken.contains(e)) throw const PipelineError('Fal.ai API 키가 없습니다');
      seen?.add(p);
      return jpg(0, 0, 200);
    },
    score: (s, p, result) async {
      // 어느 엔진인지는 순서로 알 수 있게 generate 와 같은 순서로 셈
      final e = scores.keys.firstWhere(
        (k) => (round[k] ?? 0) < scores[k]!.length && !broken.contains(k),
      );
      final i = round[e] = (round[e] ?? 0) + 1;
      final total = scores[e]![i - 1];
      final per = total ~/ 4;
      return QaScore(
        c1: per + total % 4,
        c2: per,
        c3: per,
        c4: per,
        deductions: ['$i회차 감점'],
        nextRequest: '$i회차 후 수정 요청',
        nextStrength: 90 - i * 5,
      );
    },
  );
}

void main() {
  group('자가 개선 루프', () {
    test('74 → 83 → 92: 3회차에 합격하면 바로 멈춤 + 배지·기록', () async {
      final seen = <QaParams>[];
      final runs = await fakeAgent({
        Engine.b: [74, 83, 92, 99],
      }, seen: seen).run(setup(), [Engine.b], onUpdate: (_, _) {});
      final r = runs.single;
      expect(r.attempts, hasLength(3));
      expect(r.passed, isTrue);
      expect(r.badge, '🎉 총 3회 시도 만에 90% 이상 합격! (최종 점수: 92점)');
      expect(r.timeline, '1회차 74점 ➡️ 2회차 83점 ➡️ 3회차 92점 합격');
      // ③ 감점 원인으로 고친 지시·강도가 다음 회차에 쓰임
      expect(seen.map((p) => p.request), [
        '시작 요청',
        '1회차 후 수정 요청',
        '2회차 후 수정 요청',
      ]);
      expect(seen.map((p) => p.strength), [90, 85, 80]);
    });
    test('5회 안에 90점 못 넘으면 5회에서 멈추고 최고 점수 표시', () async {
      final r = (await fakeAgent({
        Engine.a: [70, 88, 80, 85, 81],
      }).run(setup(), [Engine.a], onUpdate: (_, _) {})).single;
      expect(r.attempts, hasLength(5));
      expect(r.passed, isFalse);
      expect(r.badge, '5회 시도 완료 (최고 점수: 88점)');
    });
    test('A·B·C 전체 비교: 적은 시도 합격 → 순위 1위, 키 없는 엔진은 맨 뒤', () async {
      final runs = await fakeAgent(
        {
          Engine.a: [80, 91],
          Engine.b: [93],
          Engine.c: [1],
        },
        broken: {Engine.c},
      ).run(setup(), [Engine.a, Engine.b, Engine.c], onUpdate: (_, _) {});
      final ranked = rankRuns(runs);
      expect(ranked.map((r) => r.engine), [Engine.b, Engine.a, Engine.c]);
      expect(ranked.first.badge, contains('총 1회 시도 만에'));
      expect(ranked.last.fatal, contains('Fal.ai'));
    });
  });

  test('채점 답 읽기: 코드블록·범위 밖 값도 안전하게', () {
    const raw =
        '```json\n{"c1": 30, "c2": 20, "c3": "18", "c4": 22, "deductions": ["대문니 틈"], "next_request": "11·21 사이 틈을 닫기", "next_strength": 73}\n```';
    final s = QaScore.parse(
      raw,
      current: const QaParams(request: 'x', strength: 90),
    );
    expect(s.c1, 25); // 최대 25
    expect(s.total, 25 + 20 + 18 + 22);
    expect(s.nextStrength, 70); // 5 단위
    expect(s.nextRequest, '11·21 사이 틈을 닫기');
    expect(
      () => QaScore.parse(
        '채점 못함',
        current: const QaParams(request: '', strength: 90),
      ),
      throwsFormatException,
    );
  });

  test('채점 지시: 4대 기준 문장 그대로 포함', () {
    final p = buildScoringPrompt(
      setup(),
      const QaParams(request: 'R', strength: 80),
    );
    expect(
      p,
      contains(
        '기준 1 (공간 폐쇄 및 아치 정렬 유사도): 대문니 틈새 폐쇄 정도와 전치부 수평 아치 라인이 정답지와 얼마나 일치하는가?',
      ),
    );
    expect(p, contains('기준 2 (교합 관계 및 맞물림 정확도)'));
    expect(p, contains('기준 3 (원본 치아 고유 형태·크기·색조 보존)'));
    expect(p, contains('기준 4 (잇몸·서비컬 라인 및 주변 조직 보존)'));
    expect(p, contains('적용 강도 80%'));
  });

  group('오류 처리 (실사용 오류 재현)', () {
    test('채점 AI 모델이 없으면(종료된 gemini-2.5-pro) 변환을 아예 하지 않음', () async {
      var gens = 0;
      final runs = await QaAgent(
        generate: (e, s, p, pr) async {
          gens++;
          return jpg(0, 0, 200);
        },
        score: (s, p, r) async => throw StateError('x'),
        check: () async => '채점 AI 모델을 찾지 못했습니다',
      ).run(setup(), [Engine.a, Engine.b, Engine.c], onUpdate: (_, _) {});
      expect(gens, 0);
      expect(runs, hasLength(3));
      expect(
        runs.every((r) => r.unranked && r.fatal!.contains('채점 AI 연결 실패')),
        isTrue,
      );
      expect(rankRuns(runs).first.unranked, isTrue); // '1위 0점' 같은 순위 없음
    });
    test('채점이 계속 실패하면 2회에서 멈춤 (변환 크레딧 낭비 방지)', () async {
      var gens = 0;
      final r = (await QaAgent(
        generate: (e, s, p, pr) async {
          gens++;
          return jpg(0, 0, 200);
        },
        score: (s, p, res) async => throw const FormatException('JSON 아님'),
      ).run(setup(), [Engine.a], onUpdate: (_, _) {})).single;
      expect(gens, 2);
      expect(r.unranked, isTrue);
      expect(r.badge, contains('채점 실패'));
    });
    test('모델 없음 오류면 1회에서 바로 멈춤', () async {
      var gens = 0;
      await QaAgent(
        generate: (e, s, p, pr) async {
          gens++;
          return jpg(0, 0, 200);
        },
        score: (s, p, res) async =>
            throw const AiError('이 AI 모델을 쓸 수 없습니다 (x: 종료되었거나)'),
      ).run(setup(), [Engine.a], onUpdate: (_, _) {});
      expect(gens, 1);
    });
    test('요청이 많습니다(429) → 기다렸다가 다시 시도해서 이어감', () async {
      final waits = <int>[];
      var calls = 0;
      final status = <String>[];
      final r = (await QaAgent(
        generate: (e, s, p, pr) async {
          if (++calls <= 2) {
            throw const AiError('잠시 요청이 많습니다. 1분 뒤 다시 시도해 주세요.');
          }
          return jpg(0, 0, 200);
        },
        score: (s, p, res) async => const QaScore(
          c1: 23,
          c2: 23,
          c3: 23,
          c4: 23,
          deductions: [],
          nextRequest: '',
          nextStrength: 90,
        ),
        wait: (d) async => waits.add(d.inSeconds),
      ).run(setup(), [Engine.b], onUpdate: (_, m) => status.add(m))).single;
      expect(waits, [20, 40]);
      expect(r.passed, isTrue);
      expect(status.any((m) => m.contains('20초 기다린 뒤')), isTrue);
    });
    test('429 가 계속되면 3번 기다린 뒤 그 엔진만 중단', () async {
      final waits = <int>[];
      final r = (await QaAgent(
        generate: (e, s, p, pr) async =>
            throw const AiError('잠시 요청이 많습니다. 1분 뒤 다시 시도해 주세요.'),
        score: (s, p, res) async => throw StateError('x'),
        wait: (d) async => waits.add(d.inSeconds),
      ).run(setup(), [Engine.b], onUpdate: (_, _) {})).single;
      expect(waits, [20, 40, 60]);
      expect(r.unranked, isTrue);
    });
  });

  group('정답지·목표 점수', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      QaSession.instance.reset();
    });
    test('새 사진(다른 환자)을 고르면 이전 🎯 정답지·결과가 지워짐 + 직접 지우기', () {
      final s = QaSession.instance;
      final p1 = Object(), p2 = Object();
      s.bindPatient(p1);
      s.setTarget(jpg(0, 200, 0));
      s.bindPatient(p1); // 같은 환자 → 유지
      expect(s.target, isNotNull);
      s.bindPatient(p2); // 새 사진 → 비움
      expect(s.target, isNull);
      expect(s.runs, isEmpty);
      s.setTarget(jpg(0, 200, 0));
      s.setTarget(null); // [정답지 지우기]
      expect(s.target, isNull);
    });
    test('목표 80점: 83점에서 합격하고 배지도 80%', () async {
      final r =
          (await fakeAgent({
                Engine.b: [74, 83, 92],
              }).run(
                QaSetup(
                  original: jpg(200, 0, 0),
                  target: jpg(0, 200, 0),
                  treatments: const ['교정'],
                  teeth: const [],
                  shade: null,
                  strength: 90,
                  request: '',
                  lines: const [],
                  lockGum: false,
                  passScore: 80,
                ),
                [Engine.b],
                onUpdate: (_, _) {},
              ))
              .single;
      expect(r.attempts, hasLength(2));
      expect(r.badge, '🎉 총 2회 시도 만에 80% 이상 합격! (최종 점수: 83점)');
      expect(r.timeline, '1회차 74점 ➡️ 2회차 83점 합격');
    });
    test('PC 명령: 목표 점수·정답지 지우기', () async {
      final s = QaSession.instance;
      await QaRemote.instance.handle('qaPass', 80);
      expect(s.passScore, 80);
      expect(QaRemote.instance.qaJson()['pass'], 80);
      await QaRemote.instance.handle('qaPass', 55); // 80·90 외에는 무시
      expect(s.passScore, 80);
      s.setTarget(jpg(0, 200, 0));
      await QaRemote.instance.handle('qaTargetClear', null);
      expect(s.target, isNull);
      expect(
        buildScoringPrompt(
          QaSetup(
            original: jpg(1, 1, 1),
            target: jpg(1, 1, 1),
            treatments: const [],
            teeth: const [],
            shade: null,
            strength: 90,
            request: '',
            lines: const [],
            lockGum: false,
            passScore: 80,
          ),
          const QaParams(request: '', strength: 90),
        ),
        contains('총점이 80점 미만이면'),
      );
    });
  });

  group('정답지 없이 자체 평가', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      QaSession.instance.reset();
    });
    QaSetup noTarget() => QaSetup(
      original: jpg(200, 0, 0),
      treatments: const ['라미네이트'],
      teeth: const [11, 21],
      shade: 'BL1',
      strength: 90,
      request: '',
      lines: const [],
      lockGum: false,
    );
    test('채점 지시가 정답지 없는 자체 평가용으로 바뀜', () {
      final p = buildScoringPrompt(
        noTarget(),
        const QaParams(request: '', strength: 90),
      );
      expect(p, contains('실제 치료 후 사진(정답지)은 없습니다'));
      expect(p, contains('사진 2: AI 가 만든 치료 후 예상 결과물'));
      expect(p, contains('이상적이면서 현실적인 임상 결과'));
      expect(p, isNot(contains('사진 3')));
      expect(p, contains('"c1": 0-25'));
    });
    test('정답지 없이 돌려서 점수·합격·보관함 저장(정답지 사진 없이)', () async {
      final tmp = await Directory.systemTemp.createTemp('bna_self');
      PromptArchive.instance
        ..overrideDir = tmp
        ..overrideTemp = tmp
        ..cases.clear();
      final s = QaSession.instance;
      final runs = await s.start(
        noTarget(),
        [Engine.a],
        agent: fakeAgent({
          Engine.a: [70, 91],
        }),
      );
      expect(runs.single.passed, isTrue);
      expect(runs.single.badge, contains('총 2회 시도 만에 90% 이상 합격'));
      final c = (await s.save(runs.single))!;
      expect(c.selfScored, isTrue);
      expect(
        await (await PromptArchive.instance.imageFile(c.id, 'target')).exists(),
        isFalse,
      );
      final b = await PromptArchive.instance.backupOf(c);
      expect(b.html, contains('정답지 없음 (AI 자체 평가)'));
      expect(b.html, contains('AI 자체 평가 점수'));
      PromptArchive.instance.cases.clear();
      await PromptArchive.instance.load();
      expect(PromptArchive.instance.cases.single.selfScored, isTrue);
    });
    test('PC 에서 정답지 없이 시작', () async {
      QaRemote.instance
        ..putOverride = ((p, v) async {})
        ..originalOf = (() => jpg(200, 0, 0))
        ..setupOf = ((t) => QaSetup(
          original: jpg(200, 0, 0),
          target: t,
          treatments: const ['미백'],
          teeth: const [],
          shade: null,
          strength: 90,
          request: '',
          lines: const [],
          lockGum: false,
        ))
        ..engineOf = (() => Engine.b);
      QaSession.instance.agentFactory = () => fakeAgent({
        Engine.b: [95],
      });
      addTearDown(() {
        QaRemote.instance.putOverride = null;
        QaSession.instance.agentFactory = null;
      });
      await QaRemote.instance.handle('qaStart', null);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final j = QaRemote.instance.qaJson();
      expect(j['selfScore'], isTrue);
      expect(((j['runs'] as List).single as Map)['passed'], isTrue);
    });
  });

  group('상담 PC 연결', () {
    late Directory tmp;
    final puts = <String, Object?>{};
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('bna_remote');
      PromptArchive.instance
        ..overrideDir = tmp
        ..overrideTemp = tmp
        ..cases.clear();
      QaSession.instance.reset();
      puts.clear();
      QaRemote.instance
        ..putOverride = ((p, v) async => puts[p] = v)
        ..originalOf = (() => jpg(200, 0, 0))
        ..setupOf = ((t) => QaSetup(
          original: jpg(200, 0, 0),
          target: t,
          treatments: const ['교정'],
          teeth: const [11, 21],
          shade: null,
          strength: 90,
          request: '',
          lines: const [],
          lockGum: false,
          patientName: '김민수',
        ))
        ..engineOf = (() => Engine.b)
        ..resetForTest();
      QaSession.instance.agentFactory = () => fakeAgent({
        Engine.b: [74, 83, 92],
      });
    });
    tearDown(() {
      QaRemote.instance.putOverride = null;
      QaSession.instance.agentFactory = null;
    });

    test('PC: 정답지 → 시작 → 진행·합격 공유 → 저장 → 보관함 목록·백업·기본값 적용·삭제', () async {
      final r = QaRemote.instance;
      await r.handle('qaTarget', base64Encode(jpg(0, 200, 0)));
      expect(QaSession.instance.target, isNotNull);
      await r.handle('qaStart', {'scorer': ''});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(QaSession.instance.running, isFalse);
      await r.publishQa();
      final qa = puts['qa'] as Map;
      expect(qa['hasTarget'], isTrue);
      final run = (qa['runs'] as List).single as Map;
      expect(run['badge'], '🎉 총 3회 시도 만에 90% 이상 합격! (최종 점수: 92점)');
      expect(run['timeline'], '1회차 74점 ➡️ 2회차 83점 ➡️ 3회차 92점 합격');
      expect((run['attempts'] as List), hasLength(3));
      expect((puts['qaImg'] as Map).keys, containsAll(['target', 'latest']));
      await r.handle('qaSave', 'b');
      expect(PromptArchive.instance.count('교정'), 1);
      await r.publishArchive();
      final ar = puts['archive'] as Map;
      final folders = {
        for (final f in ar['folders'] as List) (f as Map)['name']: f['count'],
      };
      expect(folders['교정'], 1);
      expect(folders[kAllFolder], 1);
      final c = (ar['cases'] as List).single as Map;
      expect(c['badge'], '3회차 만에 합격 · 92점');
      expect(
        (c['thumbs'] as Map).keys,
        containsAll(['original', 'target', 'result']),
      );
      await r.handle('archFull', c['id']);
      final full = puts['archiveFull'] as Map;
      expect(full['html'], contains('② 실제 정답지'));
      expect(jsonDecode(full['json'] as String)['treatments'], ['교정']);
      await r.handle('archApply', c['id']);
      expect(TreatmentDefaults.instance.map['교정']?.strength, isNotNull);
      expect((puts['archiveMsg'] as Map)['text'], contains('교정 기본 설정으로 적용'));
      await r.handle('archDel', c['id']);
      expect(PromptArchive.instance.cases, isEmpty);
    });
    test('PC: A·B·C 비교 켜기 → 순위·추천 공유', () async {
      QaSession.instance.agentFactory = () => fakeAgent(
        {
          Engine.a: [80, 91],
          Engine.b: [93],
          Engine.c: [50],
        },
        broken: {Engine.c},
      );
      final r = QaRemote.instance;
      await r.handle('qaCompare', true);
      await r.handle('qaTarget', base64Encode(jpg(0, 200, 0)));
      await r.handle('qaStart', null);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final qa = r.qaJson();
      expect(qa['rank'], ['b', 'a', 'c']);
      expect(qa['recommend'], startsWith('옵션 B'));
    });
  });

  group('📚 보관함', () {
    late Directory tmp;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('bna_archive');
      PromptArchive.instance
        ..overrideDir = tmp
        ..overrideTemp = tmp
        ..cases.clear();
      QaSession.instance.reset();
    });

    Future<ArchiveCase> addOne(
      WidgetTester? t, {
      List<String> tx = const ['교정'],
    }) async {
      Future<ArchiveCase> go() => PromptArchive.instance.add(
        title: '교정 · 김민수 님 · 옵션 B',
        treatments: tx,
        tries: 3,
        passed: true,
        score: 92,
        engine: '옵션 B · FLUX + 나노바나나 Pro',
        strength: 80,
        request: '11·21 틈 닫기',
        prompt: '황금 프롬프트 전문',
        timeline: '1회차 74점 ➡️ 2회차 83점 ➡️ 3회차 92점 합격',
        criteria: const {'c1': 23, 'c2': 23, 'c3': 23, 'c4': 23},
        original: jpg(200, 0, 0),
        target: jpg(0, 200, 0),
        result: jpg(0, 0, 200),
      );
      return t == null ? go() : (await t.runAsync(go))!;
    }

    test('치료 종류로 자동 폴더 분류 + 다시 열어도 그대로 + 백업(HTML·JSON)', () async {
      final c = await addOne(null);
      final ar = PromptArchive.instance;
      expect(ar.count(kAllFolder), 1);
      expect(ar.count('교정'), 1);
      expect(ar.count('라미네이트'), 0);
      expect(c.badge, '3회차 만에 합격 · 92점');
      ar.cases.clear();
      await ar.load();
      expect(ar.count('교정'), 1);
      final paths = await ar.exportCase(ar.cases.single);
      expect(paths, hasLength(2));
      final html = await File(paths.first).readAsString();
      expect(html, contains('① 원본 사진'));
      expect(html, contains('② 실제 정답지'));
      expect(html, contains('③ AI 최종 결과물'));
      expect(html, contains('황금 프롬프트 전문'));
      expect(html, contains('data:image/jpeg;base64,'));
      final j = jsonDecode(await File(paths.last).readAsString()) as Map;
      expect(j['treatments'], ['교정']);
      expect(
        (j['images_base64_jpeg'] as Map).keys,
        containsAll(['original', 'target', 'result']),
      );
      // 치료가 2개면 두 폴더 모두에
      await addOne(null, tx: ['미백', '라미네이트']);
      expect(ar.count('미백'), 1);
      expect(ar.count('라미네이트'), 1);
      expect(ar.count(kAllFolder), 2);
    });

    testWidgets('보관함 화면: 폴더 개수 배지·카드·프롬프트 복사·기본값 적용·백업', (t) async {
      t.view.physicalSize = const Size(1280, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await addOne(t);
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String?;
          return null;
        },
      );
      List<String>? shared;
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: ArchiveScreen(share: (p) async => shared = p),
        ),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await t.pump();
      for (final f in archiveFolders) {
        expect(find.textContaining(f), findsWidgets, reason: f);
      }
      expect(find.text('🎉 3회차 만에 합격 · 92점'), findsOneWidget);
      expect(find.text('① 원본'), findsOneWidget);
      expect(find.text('② 실제 정답지'), findsOneWidget);
      expect(find.text('③ AI 최종 결과'), findsOneWidget);
      expect(find.textContaining('권장 적용 강도: 80%'), findsOneWidget);
      // 다른 폴더 → 비어 있음
      await t.tap(find.textContaining('📁 미백'));
      await t.pump();
      expect(find.textContaining('폴더에 저장된 케이스가 없습니다'), findsOneWidget);
      await t.tap(find.textContaining('📁 교정'));
      await t.pump();
      await t.tap(find.text('프롬프트 복사'));
      await t.pump();
      expect(copied, '황금 프롬프트 전문');
      await t.tap(find.text('이 치료의 기본 설정으로 적용'));
      await t.pumpAndSettle();
      await t.runAsync(() async {
        await t.tap(find.text('적용'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await t.pump();
      expect(TreatmentDefaults.instance.map['교정']?.strength, 80);
      expect(TreatmentDefaults.instance.map['교정']?.request, '11·21 틈 닫기');
      await t.runAsync(() async {
        await t.tap(find.text('데이터 백업 다운로드'));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await t.pump();
      expect(shared, hasLength(2));
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    for (final size in const [Size(390, 844), Size(1280, 900)]) {
      testWidgets('QA 화면: 정답지 올리기 → 시작 → 합격 배지 → 보관함 자동 분류 저장 $size', (
        t,
      ) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: QaAgentScreen(
              original: jpg(200, 0, 0),
              treatments: const ['교정'],
              teeth: const [11, 21],
              shade: 'A1',
              strength: 90,
              request: '',
              lines: const [],
              lockGum: false,
              engine: Engine.b,
              patientName: '김민수',
              agent: fakeAgent({
                Engine.b: [74, 83, 92],
              }),
              pickTarget: () async => jpg(0, 200, 0),
            ),
          ),
        );
        expect(find.text('자동 QA 테스트 시작 (정답지 없이 자체 평가)'), findsOneWidget);
        await t.tap(find.textContaining('탭해서 실제 치료 후'));
        await t.pump();
        expect(find.text('자동 QA 테스트 시작'), findsOneWidget);
        await t.ensureVisible(find.text('자동 QA 테스트 시작'));
        await t.pump();
        await t.tap(find.text('자동 QA 테스트 시작'));
        await t.pumpAndSettle();
        await t.tap(find.text('시작'));
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        expect(QaSession.instance.running, isFalse);
        await t.scrollUntilVisible(
          find.text('🎉 총 3회 시도 만에 90% 이상 합격! (최종 점수: 92점)'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.text('🎉 총 3회 시도 만에 90% 이상 합격! (최종 점수: 92점)'),
          findsOneWidget,
        );
        expect(
          find.textContaining('1회차 74점 ➡️ 2회차 83점 ➡️ 3회차 92점 합격'),
          findsOneWidget,
        );
        final save = find.text('💾 프롬프트 & 사진 보관함에 저장');
        await t.ensureVisible(save);
        await t.pump();
        await t.runAsync(() async {
          await t.tap(save);
          await Future<void>.delayed(const Duration(milliseconds: 800));
        });
        await t.pump();
        expect(PromptArchive.instance.count('교정'), 1);
        expect(PromptArchive.instance.cases.single.tries, 3);
        expect(PromptArchive.instance.cases.single.score, 92);
        expect(find.text('보관함에 저장됨'), findsOneWidget);
      });
    }

    testWidgets('QA 화면: A·B·C 전체 비교 → 순위 리포트', (t) async {
      t.view.physicalSize = const Size(1280, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: QaAgentScreen(
            original: jpg(200, 0, 0),
            treatments: const ['라미네이트'],
            teeth: const [],
            shade: null,
            strength: 90,
            request: '',
            lines: const [],
            lockGum: false,
            engine: Engine.a,
            agent: fakeAgent({
              Engine.a: [80, 85, 91],
              Engine.b: [92],
              Engine.c: [70, 75, 79, 82, 84],
            }),
            pickTarget: () async => jpg(0, 200, 0),
          ),
        ),
      );
      await t.tap(find.textContaining('탭해서 실제 치료 후'));
      await t.pump();
      await t.tap(find.text('옵션 A · B · C 전체 자동 비교 테스트'));
      await t.pump();
      await t.tap(find.text('자동 QA 테스트 시작'));
      await t.pumpAndSettle();
      await t.tap(find.text('시작'));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('🏆 옵션 A·B·C 비교 리포트'), findsOneWidget);
      expect(find.textContaining('추천: 옵션 B'), findsOneWidget);
      expect(find.text('1회차'), findsOneWidget); // B 합격 회차
      expect(find.text('미합격 (5회)'), findsOneWidget); // C
    });
  });
}
