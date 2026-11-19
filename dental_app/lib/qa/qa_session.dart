import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/pipeline.dart';
import 'archive.dart';
import 'qa_agent.dart';

/// 자동 QA 진행 상태 (태블릿 QA 화면과 상담 PC 가 같은 것을 봄)
class QaSession extends ChangeNotifier {
  QaSession._();
  static final instance = QaSession._();

  /// 시험용: 가짜 AI 로 바꿔 끼우기
  QaAgent Function()? agentFactory;

  Uint8List? target; // 🎯 정답지
  int targetVer = 0;
  Object? _patient; // 정답지가 어느 환자 사진에 대한 것인지
  int passScore = kPassScore; // 목표 점수 (80 또는 90)
  bool compareAll = false;
  bool running = false;
  String status = '';
  List<QaRun> runs = [];
  Uint8List? latest; // 가장 최근 회차 결과
  int latestVer = 0;
  QaSetup? setup; // 마지막으로 돌린 조건 (저장할 때 씀)
  final Set<Engine> saved = {};
  QaAgent? _agent;
  bool _stopped = false;

  /// 다른 환자 사진으로 바뀌면 정답지·결과를 비움 (사진을 새로 불러오거나 다른 환자를 고를 때)
  void bindPatient(Object? patient) {
    if (identical(_patient, patient)) return;
    _patient = patient;
    if (running) return; // 진행 중인 테스트는 끝까지 (조건은 시작할 때 이미 복사됨)
    target = null;
    targetVer++;
    runs = [];
    latest = null;
    status = '';
    saved.clear();
    notifyListeners();
  }

  void setTarget(Uint8List? b) {
    if (running) return;
    target = b;
    targetVer++;
    notifyListeners();
  }

  static const _kPass = 'qa.passScore';
  Future<void> loadPass() async {
    try {
      final v = (await SharedPreferences.getInstance()).getInt(_kPass);
      if (v == 80 || v == 90) passScore = v!;
    } catch (_) {}
  }

  void setPassScore(int v) {
    if (running || (v != 80 && v != 90) || v == passScore) return;
    passScore = v;
    notifyListeners();
    SharedPreferences.getInstance()
        .then((p) => p.setInt(_kPass, v))
        .catchError((_) => false);
  }

  void setCompareAll(bool v) {
    if (running) return;
    compareAll = v;
    notifyListeners();
  }

  void stop() {
    if (!running) return;
    _agent?.stop();
    _stopped = true;
    status = '중지하는 중… (지금 회차가 끝나면 멈춰요)';
    notifyListeners();
  }

  /// 테스트 시작. [s] 의 target 은 [target] 으로 채워서 넘겨 줌.
  Future<List<QaRun>> start(
    QaSetup s,
    List<Engine> engines, {
    QaAgent? agent,
  }) async {
    if (running) return runs;
    final a = agent ?? agentFactory?.call() ?? QaAgent();
    _agent = a;
    _stopped = false;
    setup = s;
    running = true;
    runs = [];
    saved.clear();
    latest = null;
    status = '시작합니다…';
    notifyListeners();
    try {
      final out = await a.run(
        s,
        engines,
        onUpdate: (run, st) {
          if (!runs.contains(run)) runs = [...runs, run];
          status = st;
          final last = run.attempts.lastOrNull?.result;
          if (last != null && !identical(last, latest)) {
            latest = last;
            latestVer++;
          }
          notifyListeners();
        },
      );
      runs = out;
      status = _stopped ? '중지했습니다' : '테스트 완료';
      return out;
    } catch (e) {
      status = '테스트 중 오류: $e';
      return runs;
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// 💾 보관함에 저장 (치료 종류 폴더로 자동 분류)
  Future<ArchiveCase?> save(QaRun run) async {
    final s = setup;
    final best = run.passedAttempt ?? run.best;
    if (s == null || best == null || best.result == null) return null;
    if (saved.contains(run.engine)) return null;
    final tx = s.treatments;
    final name = s.patientName.trim();
    final c = await PromptArchive.instance.add(
      title:
          '${tx.isEmpty ? kUnsorted : tx.join('·')} · ${name.isEmpty ? 'QA 케이스' : '$name 님'} · ${run.engine.tag}',
      treatments: tx,
      tries: run.passed ? best.round : run.tries,
      passed: run.passed,
      score: best.score!.total,
      engine: '${run.engine.tag} · ${run.engine.label}',
      strength: best.params.strength,
      request: best.params.request,
      prompt: best.prompt,
      timeline: run.timeline,
      criteria: {
        'c1': best.score!.c1,
        'c2': best.score!.c2,
        'c3': best.score!.c3,
        'c4': best.score!.c4,
      },
      original: s.original,
      target: s.target,
      selfScored: s.selfScore,
      result: best.result!,
    );
    saved.add(run.engine);
    notifyListeners();
    return c;
  }

  /// 시험용 초기화
  @visibleForTesting
  void reset() {
    target = null;
    _patient = null;
    passScore = kPassScore;
    compareAll = false;
    running = false;
    status = '';
    runs = [];
    latest = null;
    setup = null;
    saved.clear();
  }
}
