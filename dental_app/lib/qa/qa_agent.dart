import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_service.dart';
import '../ai/pipeline.dart';
import '../ai/prompt_engine.dart';
import '../simulator/sim_models.dart' show GuideLine;

// =============================================================================
// 🤖 자동 QA 테스트 에이전트
//   ① 변환 → ② 비전 AI 채점(원본·정답지·결과 3장, 4대 기준 × 25점) → ③ 90점 미만이면
//   감점 원인을 분석해 '추가 요청'과 적용 강도를 스스로 고쳐 다시 변환 (최대 5회)
// =============================================================================

const kPassScore = 90;
const kMaxTries = 5;

/// 테스트 조건 (시뮬레이터에서 선택된 그대로)
class QaSetup {
  const QaSetup({
    required this.original,
    this.target,
    required this.treatments,
    required this.teeth,
    required this.shade,
    required this.strength,
    required this.request,
    required this.lines,
    required this.lockGum,
    this.patientName = '',
    this.passScore = kPassScore,
  });
  final int passScore; // 목표 점수 (80 또는 90)
  final Uint8List original; // 변환 전 원본
  final Uint8List? target; // 🎯 실제 치료 후 정답지 (없으면 AI 자체 평가)
  bool get selfScore => target == null;
  final List<String> treatments;
  final List<int> teeth;
  final String? shade;
  final int strength; // 시작 적용 강도
  final String request; // 시작 '추가 요청'
  final List<GuideLine> lines; // 서비컬 라인
  final bool lockGum; // 잇몸 원본 잠금
  final String patientName;
}

/// 한 회차의 설정 (에이전트가 회차마다 바꾸는 값)
class QaParams {
  const QaParams({required this.request, required this.strength});
  final String request;
  final int strength;
}

/// 4대 임상 기준 점수
class QaScore {
  const QaScore({
    required this.c1,
    required this.c2,
    required this.c3,
    required this.c4,
    required this.deductions,
    required this.nextRequest,
    required this.nextStrength,
    this.summary = '',
  });
  final int c1, c2, c3, c4; // 각 0~25
  final List<String> deductions; // 감점 원인
  final String nextRequest; // 다음 회차 '추가 요청'
  final int nextStrength; // 다음 회차 적용 강도
  final String summary;
  int get total => c1 + c2 + c3 + c4;

  static int _n(Object? v, int max) {
    final n = v is num ? v.round() : int.tryParse('$v') ?? 0;
    return n.clamp(0, max);
  }

  /// 비전 AI 의 JSON 답 → 점수 (코드블록·앞뒤 설명이 섞여도 읽음)
  factory QaScore.parse(String raw, {required QaParams current}) {
    var t = raw.trim();
    final a = t.indexOf('{'), b = t.lastIndexOf('}');
    if (a < 0 || b <= a) throw const FormatException('채점 결과(JSON)를 읽지 못했습니다.');
    t = t.substring(a, b + 1);
    final j = jsonDecode(t) as Map<String, dynamic>;
    final ded = j['deductions'];
    final next = '${j['next_request'] ?? ''}'.trim();
    return QaScore(
      c1: _n(j['c1'], 25),
      c2: _n(j['c2'], 25),
      c3: _n(j['c3'], 25),
      c4: _n(j['c4'], 25),
      deductions: ded is List ? [for (final d in ded) '$d'] : ['$ded'],
      nextRequest: next.isEmpty ? current.request : next,
      nextStrength: j['next_strength'] == null
          ? current.strength
          : (_n(j['next_strength'], 100) ~/ 5 * 5).clamp(30, 100),
      summary: '${j['summary'] ?? ''}',
    );
  }

  Map<String, Object?> toJson() => {
    'c1': c1,
    'c2': c2,
    'c3': c3,
    'c4': c4,
    'total': total,
    'deductions': deductions,
    'next_request': nextRequest,
    'next_strength': nextStrength,
    'summary': summary,
  };
}

/// 회차 기록
class QaAttempt {
  QaAttempt({
    required this.round,
    required this.params,
    required this.prompt,
    this.pass = kPassScore,
  });
  final int pass; // 목표 점수
  final int round;
  final QaParams params;
  final String prompt; // 이 회차에 실제로 쓴 전체 지시문
  Uint8List? result;
  QaScore? score;
  String? error;
  bool get passed => (score?.total ?? 0) >= pass;
}

/// 엔진 하나의 테스트 결과
class QaRun {
  QaRun(this.engine, {this.pass = kPassScore});
  final int pass; // 목표 점수
  final Engine engine;
  final List<QaAttempt> attempts = [];
  String? fatal; // 키 없음 등으로 아예 못 돌림

  QaAttempt? get best {
    final scored = attempts
        .where((a) => a.score != null && a.result != null)
        .toList();
    if (scored.isEmpty) return null;
    scored.sort((a, b) => b.score!.total.compareTo(a.score!.total));
    return scored.first;
  }

  QaAttempt? get passedAttempt => attempts.where((a) => a.passed).firstOrNull;
  bool get passed => passedAttempt != null;
  int get tries => attempts.length;
  int get bestScore => best?.score?.total ?? 0;

  /// 예: 1회차 74점 ➡️ 2회차 83점 ➡️ 3회차 92점 합격
  String get timeline => attempts
      .map(
        (a) =>
            '${a.round}회차 ${a.score == null ? (a.error != null ? '오류' : '…') : '${a.score!.total}점'}${a.passed ? ' 합격' : ''}',
      )
      .join(' ➡️ ');

  /// 결과 화면 맨 위 배지
  String get badge => passed
      ? '🎉 총 ${passedAttempt!.round}회 시도 만에 $pass% 이상 합격! (최종 점수: ${passedAttempt!.score!.total}점)'
      : fatal != null
      ? '⚠ 테스트하지 못함: $fatal'
      : best == null
      ? '⚠ 채점된 회차가 없습니다'
      : '$tries회 시도 완료 (최고 점수: $bestScore점)';

  /// 점수가 하나도 없으면 순위에서 제외 (못 돌림)
  bool get unranked => fatal != null || best == null;
}

/// A·B·C 비교 순위: 합격 우선 → 적은 시도 → 높은 점수
List<QaRun> rankRuns(List<QaRun> runs) {
  final r = [...runs];
  r.sort((a, b) {
    if (a.unranked || b.unranked) {
      return (a.unranked ? 1 : 0) - (b.unranked ? 1 : 0);
    }
    if (a.passed != b.passed) return a.passed ? -1 : 1;
    if (a.passed) {
      final t = a.passedAttempt!.round.compareTo(b.passedAttempt!.round);
      if (t != 0) return t;
      return b.passedAttempt!.score!.total.compareTo(
        a.passedAttempt!.score!.total,
      );
    }
    return b.bestScore.compareTo(a.bestScore);
  });
  return r;
}

// -----------------------------------------------------------------------------
// 채점 지시 (4대 임상 기준은 요청하신 문장 그대로)
// -----------------------------------------------------------------------------
String buildScoringPrompt(QaSetup s, QaParams p) => s.selfScore
    ? buildSelfScoringPrompt(s, p)
    : '''
당신은 치과 임상 사진을 평가하는 엄격한 전문가입니다. 아래 3장의 사진을 비교하세요.
- 사진 1: 변환 전 원본 (치료 전)
- 사진 2: 실제 치료 후 임상 사진 (정답지)
- 사진 3: AI 가 만든 결과물
사진 3이 사진 2(정답지)에 얼마나 가까운지, 아래 4대 임상 기준(각 25점, 총 100점)으로 엄격하게 채점하세요.
- 기준 1 (공간 폐쇄 및 아치 정렬 유사도): 대문니 틈새 폐쇄 정도와 전치부 수평 아치 라인이 정답지와 얼마나 일치하는가?
- 기준 2 (교합 관계 및 맞물림 정확도): 떠 있던 구치부(어금니) 교합 맞물림과 전치부 피개교합(Overbite) 비율이 정답지처럼 개선되었는가?
- 기준 3 (원본 치아 고유 형태·크기·색조 보존): 인위적인 라미네이트처럼 길어지거나 하얘지지 않고 원래 치아 모양과 자연 색상이 정답지처럼 유지되었는가?
- 기준 4 (잇몸·서비컬 라인 및 주변 조직 보존): 잇몸 높낮이, 치간유두, 입술 및 개구기가 원본·정답지와 동일하게 보존되었는가?

이번 회차 설정: 치료 종류 ${s.treatments.isEmpty ? '없음' : s.treatments.join(', ')} / 적용 강도 ${p.strength}% / 추가 요청: ${p.request.trim().isEmpty ? '(없음)' : p.request.trim()}

총점이 ${s.passScore}점 미만이면, 정답지와 다른 감점 원인을 구체적으로 적고, 다음 회차에 AI 이미지 편집 모델에 줄
'추가 요청'(한국어, 치아 번호·위치·길이·색 등 구체적으로, 400자 이내, 형태를 바꾸지 말아야 할 것도 명시)과
적용 강도(30~100, 5 단위)를 새로 제안하세요. 기존 추가 요청에서 잘 된 부분은 유지하고 감점 원인만 고치세요.

반드시 아래 JSON 하나만 답하세요 (설명 문장 없이):
{"c1": 0-25, "c2": 0-25, "c3": 0-25, "c4": 0-25, "deductions": ["감점 원인 1", "..."], "next_request": "다음 회차 추가 요청", "next_strength": 30-100, "summary": "한 줄 평"}
''';

/// 정답지 없이: 원본 → AI 결과만 보고 '이 치료의 이상적인 임상 결과'를 기준으로 자체 채점
String buildSelfScoringPrompt(QaSetup s, QaParams p) {
  final tx = s.treatments.isEmpty ? '없음' : s.treatments.join(', ');
  return '''
당신은 치과 임상 사진을 평가하는 엄격한 전문가입니다. 실제 치료 후 사진(정답지)은 없습니다.
- 사진 1: 변환 전 원본 (치료 전)
- 사진 2: AI 가 만든 치료 후 예상 결과물
선택된 치료($tx)를 실제로 잘 받았을 때의 '이상적이면서 현실적인 임상 결과'를 기준으로, 사진 2를 아래 4대 기준(각 25점, 총 100점)으로 엄격하게 채점하세요.
- 기준 1 (치료 목표 달성 및 아치 정렬): 선택한 치료의 목적(틈 폐쇄·정렬·형태·색 개선 등)이 선택한 치아 범위에서 충분하고 자연스럽게 이루어졌고, 전치부 아치 라인과 정중선이 조화로운가?
- 기준 2 (교합 관계 및 맞물림 자연스러움): 위아래 치아의 맞물림·피개교합(Overbite)·치아 길이 비율이 해부학적으로 자연스럽고, 치료하지 않은 쪽 치아를 망가뜨리지 않았는가?
- 기준 3 (원본 치아 고유 형태·크기·색조 보존): 치료 범위 밖 치아와 치료 목적과 무관한 특징(크기·윤곽·자연 색조·질감)이 원본처럼 유지되고, 인위적으로 길어지거나 하얘지지 않았는가?
- 기준 4 (잇몸·서비컬 라인 및 주변 조직 보존): 잇몸 높낮이, 치간유두, 입술·피부·개구기·사진 구도가 원본과 동일하게 보존되었는가?
사진이 AI 로 만든 티(번짐·왜곡·치아 개수 이상·경계 깨짐)가 나면 해당 기준에서 크게 감점하세요.

이번 회차 설정: 치료 종류 $tx / 치아 ${s.teeth.isEmpty ? '전체' : s.teeth.join(', ')} / 셰이드 ${s.shade ?? '미선택'} / 적용 강도 ${p.strength}% / 추가 요청: ${p.request.trim().isEmpty ? '(없음)' : p.request.trim()}

총점이 ${s.passScore}점 미만이면, 감점 원인을 구체적으로 적고, 다음 회차에 AI 이미지 편집 모델에 줄
'추가 요청'(한국어, 치아 번호·위치·길이·색 등 구체적으로, 400자 이내, 형태를 바꾸지 말아야 할 것도 명시)과
적용 강도(30~100, 5 단위)를 새로 제안하세요. 기존 추가 요청에서 잘 된 부분은 유지하고 감점 원인만 고치세요.

반드시 아래 JSON 하나만 답하세요 (설명 문장 없이):
{"c1": 0-25, "c2": 0-25, "c3": 0-25, "c4": 0-25, "deductions": ["감점 원인 1", "..."], "next_request": "다음 회차 추가 요청", "next_strength": 30-100, "summary": "한 줄 평"}
''';
}

// -----------------------------------------------------------------------------
// 설정: 채점 모델
// -----------------------------------------------------------------------------
class QaSettings {
  /// 비워 두면 자동: 아래 후보를 차례로 시험해 이 프로젝트에서 열려 있는 모델을 씀
  /// (gemini-2.5-pro 는 2026-10-20 Agent Platform 에서 종료됨)
  static const candidates = [
    'gemini-3.1-pro',
    'gemini-3.1-pro-preview',
    'gemini-3.5-flash',
    'gemini-3.8-flash',
    'gemini-3-pro-preview',
    'gemini-3-flash-preview',
    'gemini-2.5-pro',
    'gemini-2.5-flash',
  ];
  static const _k = 'qa.scorerModel2';
  static String scorerModel = ''; // 사용자가 직접 정한 모델 (비면 자동)
  static String? active; // 실제로 연결 확인된 모델
  static Future<void> load() async {
    try {
      scorerModel = (await SharedPreferences.getInstance()).getString(_k) ?? '';
    } catch (_) {}
  }

  static Future<void> save(String v) async {
    scorerModel = v.trim();
    active = null;
    try {
      await (await SharedPreferences.getInstance()).setString(_k, scorerModel);
    } catch (_) {}
  }

  static List<String> get order => [
    if (scorerModel.isNotEmpty) scorerModel,
    if (active != null && active != scorerModel) active!,
    for (final c in candidates)
      if (c != scorerModel && c != active) c,
  ];
}

/// 모델을 못 찾는 오류 (이름이 틀렸거나 종료됨/권한 없음) → 다음 후보로
bool isModelMissing(Object e) {
  final t = '$e';
  return t.contains('모델을 쓸 수 없습니다') ||
      t.contains('not found') ||
      t.contains('NOT_FOUND') ||
      t.contains('does not have access') ||
      t.contains('Publisher model');
}

/// 잠시 요청이 몰린 오류 (기다리면 풀림)
bool isRateLimited(Object e) {
  final t = '$e';
  return t.contains('요청이 많습니다') && !t.contains('Fal.ai') ||
      t.contains('RESOURCE_EXHAUSTED') ||
      t.contains('429');
}

/// 채점 AI 연결 확인: 열려 있는 모델을 찾아 QaSettings.active 에 기억. 실패하면 오류 문장.
Future<String?> realCheckScorer() async {
  if (QaSettings.active != null) return null;
  Object? last;
  for (final m in QaSettings.order) {
    try {
      await AiService.instance.geminiText(
        model: m,
        prompt: '연결 확인입니다. {"ok": true} 만 답하세요.',
        images: const [],
      );
      QaSettings.active = m;
      return null;
    } catch (e) {
      last = e;
      if (isModelMissing(e)) continue;
      if (isRateLimited(e)) return '잠시 요청이 많습니다. 1분 뒤 다시 시도해 주세요.';
      return '$e';
    }
  }
  return '채점 AI 모델을 찾지 못했습니다 (${QaSettings.order.take(3).join(', ')} …). '
      'QA 화면의 [채점 모델]에 콘솔에서 쓸 수 있는 Gemini 모델 이름을 넣어 주세요. ($last)';
}

// -----------------------------------------------------------------------------
// 실제 AI 연결 (시험에서는 가짜로 바꿔 끼움)
// -----------------------------------------------------------------------------
typedef QaGenerate = Future<Uint8List> Function(
  Engine engine,
  QaSetup s,
  QaParams p,
  String prompt,
);
typedef QaScorer = Future<QaScore> Function(
  QaSetup s,
  QaParams p,
  Uint8List result,
);

/// 이 회차 전체 지시문 (기존 임상 지시 + 추가 요청 + 강도)
String qaPrompt(QaSetup s, QaParams p) => ClinicalPrompt.build(
  treatments: s.treatments,
  teeth: s.teeth,
  shade: s.shade,
  strength: p.strength,
  hasGuide: s.lines.isNotEmpty,
  guideUpper: s.lines.any((l) => l.upper),
  guideLower: s.lines.any((l) => !l.upper),
  request: p.request,
);

/// 실제 변환 (엄격 모드: 실패하면 다른 엔진으로 바꾸지 않고 오류 → 엔진 비교가 공정하게)
Future<Uint8List> realGenerate(
  Engine engine,
  QaSetup s,
  QaParams p,
  String prompt,
) async {
  final lock = s.lockGum ? s.lines : const <GuideLine>[];
  final eff = effectiveEngine(engine, s.treatments, s.lines.isNotEmpty);
  if (eff.engine == Engine.solo) {
    return AiService.instance.generateAfter(
      before: s.original,
      guide: s.lines,
      lock: lock,
      prompt: prompt,
    );
  }
  String? notice;
  final out = await TwoPassPipeline().run(
    engine: eff.engine,
    before: s.original,
    lines: s.lines,
    fluxPrompt: ClinicalPrompt.fluxPrompt(
      treatments: s.treatments,
      teeth: s.teeth,
      shade: s.shade,
      extra: p.request,
    ),
    lock: lock,
    onStep: (_) {},
    onNotice: (m) => notice = m,
  );
  if (notice != null) throw PipelineError(notice!); // 2단계 실패도 이 엔진의 실패로 기록
  return out;
}

/// 실제 채점 (Gemini 비전)
Future<QaScore> realScore(QaSetup s, QaParams p, Uint8List result) async {
  Future<Uint8List> small(Uint8List b) async =>
      AiService.photoJpeg(await AiService.decodePhoto(b, maxSide: 1280));
  final raw = await AiService.instance.geminiText(
    model: QaSettings.active ?? QaSettings.order.first,
    prompt: buildScoringPrompt(s, p),
    images: [
      (label: '사진 1: 변환 전 원본', jpeg: await small(s.original)),
      if (s.target != null) ...[
        (label: '사진 2: 실제 치료 후 정답지', jpeg: await small(s.target!)),
        (label: '사진 3: AI 결과물', jpeg: await small(result)),
      ] else
        (label: '사진 2: AI 결과물', jpeg: await small(result)),
    ],
  );
  return QaScore.parse(raw, current: p);
}

// -----------------------------------------------------------------------------
// 에이전트
// -----------------------------------------------------------------------------
class QaAgent {
  QaAgent({
    QaGenerate? generate,
    QaScorer? score,
    Future<String?> Function()? check,
    Future<void> Function(Duration)? wait,
    this.maxTries = kMaxTries,
  }) : _generate = generate ?? realGenerate,
       _score = score ?? realScore,
       _check = check ?? (generate == null ? realCheckScorer : _noCheck),
       _wait = wait ?? Future<void>.delayed;
  final QaGenerate _generate;
  final QaScorer _score;
  final Future<String?> Function() _check;
  final Future<void> Function(Duration) _wait;
  final int maxTries;
  bool _stop = false;
  void stop() => _stop = true;
  static Future<String?> _noCheck() async => null;

  /// 요청이 몰리면(429) 20·40·60초 기다렸다 다시 시도
  static const backoff = [20, 40, 60];
  Future<T> _retry<T>(
    Future<T> Function() f,
    void Function(String) say,
    String what,
  ) async {
    for (var i = 0; ; i++) {
      try {
        return await f();
      } catch (e) {
        if (!isRateLimited(e) || i >= backoff.length || _stop) rethrow;
        say('⏳ $what: 잠시 요청이 많아 ${backoff[i]}초 기다린 뒤 다시 시도합니다…');
        await _wait(Duration(seconds: backoff[i]));
      }
    }
  }

  /// [engines] 를 차례로 테스트. [onUpdate] 로 화면에 진행 상황 전달.
  Future<List<QaRun>> run(
    QaSetup s,
    List<Engine> engines, {
    required void Function(QaRun run, String status) onUpdate,
  }) async {
    _stop = false;
    final runs = <QaRun>[];
    // 0) 변환 크레딧을 쓰기 전에 채점 AI 가 되는지부터 확인
    final first = QaRun(engines.first, pass: s.passScore);
    onUpdate(first, '채점 AI 연결 확인 중…');
    String? bad;
    try {
      bad = await _retry(_check, (m) => onUpdate(first, m), '채점 AI 확인');
    } catch (e) {
      bad = _msg(e);
    }
    if (bad != null) {
      for (final e in engines) {
        final r = e == first.engine ? first : QaRun(e, pass: s.passScore);
        r.fatal = '채점 AI 연결 실패 — $bad';
        runs.add(r);
        onUpdate(r, '채점 AI 연결 실패: 변환은 하지 않았습니다 (크레딧 사용 없음)');
      }
      return runs;
    }
    for (final e in engines) {
      if (_stop) break;
      final run = e == first.engine && runs.isEmpty
          ? first
          : QaRun(e, pass: s.passScore);
      runs.add(run);
      var params = QaParams(request: s.request, strength: s.strength);
      var scoreFails = 0;
      for (var round = 1; round <= maxTries && !_stop; round++) {
        final prompt = qaPrompt(s, params);
        final at = QaAttempt(
          round: round,
          params: params,
          prompt: prompt,
          pass: s.passScore,
        );
        run.attempts.add(at);
        void say(String m) => onUpdate(run, '${e.tag} · $round회차 $m');
        say('① 변환 중…');
        try {
          at.result = await _retry(
            () => _generate(e, s, params, prompt),
            say,
            '변환',
          );
        } catch (err) {
          at.error = '변환 실패: ${_msg(err)}';
          say(at.error!);
          // 키가 없는 등 다시 해도 안 되는 오류면 이 엔진은 중단
          if (err is PipelineError || round == 1 || isRateLimited(err)) {
            run.fatal ??= _msg(err);
            break;
          }
          continue;
        }
        say('② 비전 AI 채점 중…');
        try {
          at.score = await _retry(
            () => _score(s, params, at.result!),
            say,
            '채점',
          );
          scoreFails = 0;
        } catch (err) {
          at.error = '채점 실패: ${_msg(err)}';
          say(at.error!);
          // 채점이 연달아 안 되면 변환 크레딧만 버리므로 멈춤
          if (++scoreFails >= 2 || isModelMissing(err) || isRateLimited(err)) {
            run.fatal ??= '채점 실패 — ${_msg(err)}';
            if (isModelMissing(err)) QaSettings.active = null;
            break;
          }
          continue;
        }
        if (at.passed) break;
        // ③ 감점 원인으로 다음 회차 지시·강도 수정
        params = QaParams(
          request: at.score!.nextRequest,
          strength: at.score!.nextStrength,
        );
        say('${at.score!.total}점 → ③ 지시 수정 후 재시도');
      }
      onUpdate(run, '${e.tag}: ${run.badge}');
    }
    return runs;
  }

  static String _msg(Object e) => e is PipelineError
      ? e.message
      : e is AiError
      ? e.message
      : '$e'.substring(0, math.min('$e'.length, 300));
}
