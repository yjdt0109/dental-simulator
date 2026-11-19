import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../ai/ai_service.dart';
import '../ai/pipeline.dart';
import '../app_theme.dart';
import '../simulator/sim_models.dart' show GuideLine;
import 'archive_screen.dart';
import 'qa_agent.dart';
import 'qa_session.dart';
import '../simulator/sim_import.dart';

/// 🤖 자동 QA 에이전트 화면
class QaAgentScreen extends StatefulWidget {
  const QaAgentScreen({
    super.key,
    required this.original,
    required this.treatments,
    required this.teeth,
    required this.shade,
    required this.strength,
    required this.request,
    required this.lines,
    required this.lockGum,
    required this.engine,
    this.patientName = '',
    this.agent,
    this.pickTarget,
  });

  final Uint8List original;
  final List<String> treatments;
  final List<int> teeth;
  final String? shade;
  final int strength;
  final String request;
  final List<GuideLine> lines;
  final bool lockGum;
  final Engine engine; // 지금 선택된 엔진
  final String patientName;

  /// 시험용: 가짜 AI / 가짜 사진 고르기
  final QaAgent? agent;
  final Future<Uint8List?> Function()? pickTarget;

  @override
  State<QaAgentScreen> createState() => _QaAgentScreenState();
}

class _QaAgentScreenState extends State<QaAgentScreen> {
  final _s = QaSession.instance;
  late final _modelCtrl = TextEditingController(text: QaSettings.scorerModel);

  @override
  void initState() {
    super.initState();
    _s.addListener(_changed);
  }

  @override
  void dispose() {
    _s.removeListener(_changed);
    _modelCtrl.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  List<Engine> get _engines =>
      _s.compareAll ? [Engine.a, Engine.b, Engine.c] : [widget.engine];

  Future<void> _pick() async {
    Uint8List? bytes;
    if (widget.pickTarget != null) {
      bytes = await widget.pickTarget!();
    } else {
      final f = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 92,
      );
      bytes = await f?.readAsBytes();
    }
    if (bytes != null && mounted) _s.setTarget(bytes);
  }

  Future<void> _start() async {
    final t = _s.target;
    final n = _engines.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('자동 QA 테스트를 시작할까요?'),
        content: Text(
          '${n > 1 ? '옵션 A·B·C를 차례로' : widget.engine.tag}${n > 1 ? '' : '으로'} 최대 ${kMaxTries * n}회 변환하고 '
          '같은 횟수만큼 비전 AI가 채점합니다. ${_s.passScore}점이 되면 그 엔진은 바로 멈춥니다.\n\n'
          '${t == null ? '🎯 정답지가 없어 AI가 원본과 결과만 보고 \'이 치료의 이상적인 결과\' 기준으로 자체 채점합니다.\n' : ''}'
          '먼저 채점 AI 연결을 확인하고, 안 되면 변환하지 않습니다.\n'
          '변환·채점마다 크레딧(또는 Fal.ai 요금)이 사용됩니다.',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('시작'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_modelCtrl.text.trim() != QaSettings.scorerModel) {
      await QaSettings.save(_modelCtrl.text);
    }
    await _s.start(
      QaSetup(
        original: widget.original,
        target: t,
        treatments: widget.treatments,
        teeth: widget.teeth,
        shade: widget.shade,
        strength: widget.strength,
        request: widget.request,
        lines: widget.lines,
        lockGum: widget.lockGum,
        patientName: widget.patientName,
        passScore: _s.passScore,
      ),
      _engines,
      agent: widget.agent,
    );
  }

  /// 이 엔진의 가장 좋은 결과를 시뮬레이터 메인 화면(원본·After)으로
  Future<void> _import(QaRun run) async {
    final best = run.passedAttempt ?? run.best;
    final s = _s.setup;
    if (best?.result == null || s == null) return;
    final msg = await SimImport.run(
      original: s.original,
      result: best!.result!,
      tag: 'QA·${run.engine.short}',
      name: s.patientName,
      treatments: s.treatments,
    );
    if (mounted && SimImport.handler == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _save(QaRun run) async {
    final c = await _s.save(run);
    if (c == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('📚 \'${c.folders.join('·')}\' 폴더에 저장했습니다'),
          action: SnackBarAction(
            label: '보관함 열기',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ArchiveScreen())),
          ),
        ),
      );
  }

  // ---------------------------------------------------------------------------
  Widget _card({required Widget child}) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: AppColors.gray200),
    ),
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  Widget _photo(
    String title,
    Uint8List? bytes, {
    VoidCallback? onTap,
    String? empty,
    bool busy = false,
  }) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Material(
              color: const Color(0xFF0D1622),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (bytes != null)
                      Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    else
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            empty ?? '',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    if (busy)
                      const ColoredBox(
                        color: Color(0x66000000),
                        child: Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _runCard(QaRun run, {int? rank}) {
    final passed = run.passed;
    final best = run.passedAttempt ?? run.best;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (rank != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      rank == 1
                          ? '🥇'
                          : rank == 2
                          ? '🥈'
                          : '🥉',
                      style: const TextStyle(fontSize: 22),
                    ),
                  ),
                Expanded(
                  child: Text(
                    '${run.engine.tag} · ${run.engine.label}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 합격 배지
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: passed
                    ? AppColors.mint.withValues(alpha: 0.12)
                    : const Color(0xFFFFF4E5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                run.badge,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: passed ? AppColors.mint : const Color(0xFFB25E00),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 회차별 점수 변화
            Text(
              '점수 기록: ${run.timeline.isEmpty ? '-' : run.timeline}${_s.setup?.selfScore == true ? '  (정답지 없이 AI 자체 평가)' : ''}',
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            for (final a in run.attempts)
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    '${a.round}회차 · ${a.score == null ? (a.error ?? '진행 중') : '${a.score!.total}점'} · 강도 ${a.params.strength}%',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  children: [
                    if (a.score != null) ...[
                      _crit('기준 1 · 공간 폐쇄 및 아치 정렬', a.score!.c1),
                      _crit('기준 2 · 교합 관계 및 맞물림', a.score!.c2),
                      _crit('기준 3 · 원본 형태·크기·색조 보존', a.score!.c3),
                      _crit('기준 4 · 잇몸·서비컬 라인·주변 조직 보존', a.score!.c4),
                      if (a.score!.summary.isNotEmpty)
                        _line('한 줄 평', a.score!.summary),
                      if (a.score!.deductions.isNotEmpty)
                        _line(
                          '감점 원인',
                          a.score!.deductions.map((d) => '• $d').join('\n'),
                        ),
                      if (!a.passed)
                        _line(
                          '다음 회차 수정',
                          '${a.score!.nextRequest}\n(적용 강도 ${a.score!.nextStrength}%)',
                        ),
                    ],
                    _line(
                      '이 회차 추가 요청',
                      a.params.request.isEmpty ? '(없음)' : a.params.request,
                    ),
                  ],
                ),
              ),
            if (best?.result != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _s.running || _s.saved.contains(run.engine)
                        ? null
                        : () => _save(run),
                    icon: const Icon(Icons.save_alt_rounded),
                    label: Text(
                      _s.saved.contains(run.engine)
                          ? '보관함에 저장됨'
                          : '💾 프롬프트 & 사진 보관함에 저장',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _s.running ? null : () => _import(run),
                    icon: const Icon(Icons.input_rounded),
                    label: const Text('🖼 메인 화면으로 가져오기'),
                  ),
                  Text(
                    '→ ${widget.treatments.isEmpty ? '미분류' : widget.treatments.join('·')} 폴더로 자동 분류',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.gray500,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _crit(String label, int v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5))),
        SizedBox(
          width: 90,
          child: LinearProgressIndicator(
            value: v / 25,
            minHeight: 6,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            '$v/25',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    ),
  );

  Widget _line(String k, String v) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          k,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AppColors.blueDeep,
          ),
        ),
        SelectableText(v, style: const TextStyle(fontSize: 12.5, height: 1.5)),
      ],
    ),
  );

  Widget _report() {
    final ranked = rankRuns(_s.runs);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '🏆 옵션 A·B·C 비교 리포트',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            const Text(
              '순위: 합격 여부 → 적은 시도 횟수 → 높은 점수',
              style: TextStyle(fontSize: 12, color: AppColors.gray500),
            ),
            const SizedBox(height: 10),
            Table(
              columnWidths: const {
                0: FixedColumnWidth(44),
                1: FlexColumnWidth(2.2),
                2: FlexColumnWidth(1.3),
                3: FlexColumnWidth(1),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                const TableRow(
                  decoration: BoxDecoration(color: AppColors.blueSoft),
                  children: [_Th('순위'), _Th('엔진'), _Th('합격 회차'), _Th('최고 점수')],
                ),
                for (var i = 0; i < ranked.length; i++)
                  TableRow(
                    children: [
                      _Td(ranked[i].unranked ? '-' : '${i + 1}위'),
                      _Td('${ranked[i].engine.tag}\n${ranked[i].engine.label}'),
                      _Td(
                        ranked[i].unranked
                            ? '못 돌림'
                            : ranked[i].passed
                            ? '${ranked[i].passedAttempt!.round}회차'
                            : '미합격 (${ranked[i].tries}회)',
                      ),
                      _Td(ranked[i].unranked ? '-' : '${ranked[i].bestScore}점'),
                    ],
                  ),
              ],
            ),
            if (ranked.isNotEmpty && !ranked.first.unranked) ...[
              const SizedBox(height: 10),
              Text(
                '추천: ${ranked.first.engine.tag} (${ranked.first.engine.label}) — '
                '${ranked.first.passed ? '${ranked.first.passedAttempt!.round}회 만에 ${ranked.first.passedAttempt!.score!.total}점 합격' : '최고 ${ranked.first.bestScore}점'}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.blueDeep,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ready = AiService.instance.ready || widget.agent != null;
    final st = PipelineSettings.instance;
    final ranked = _s.runs.length > 1 && !_s.running ? rankRuns(_s.runs) : null;
    return Scaffold(
      backgroundColor: AppColors.gray50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '🤖 자동 QA 에이전트',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: AppColors.blueDeep,
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ArchiveScreen())),
            icon: const Icon(Icons.collections_bookmark_outlined),
            label: const Text('보관함'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '테스트 조건 (시뮬레이터에서 선택한 그대로)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '치료 종류: ${widget.treatments.isEmpty ? '없음' : widget.treatments.join(', ')}  ·  '
                      '치아: ${widget.teeth.isEmpty ? '전체' : widget.teeth.join(', ')}  ·  셰이드: ${widget.shade ?? '미선택'}  ·  '
                      '서비컬 라인 ${widget.lines.length}개  ·  시작 강도 ${widget.strength}%\n'
                      '추가 요청: ${widget.request.trim().isEmpty ? '(없음)' : widget.request.trim()}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.gray500,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _photo('① 변환 전 원본', widget.original),
                        const SizedBox(width: 10),
                        _photo(
                          '② 🎯 목표 정답지 (선택)',
                          _s.target,
                          onTap: _s.running ? null : _pick,
                          empty: '탭해서 실제 치료 후\n임상 사진 올리기\n(없으면 AI 자체 평가)',
                        ),
                        const SizedBox(width: 10),
                        _photo(
                          '③ AI 결과 (최근 회차)',
                          _s.latest,
                          empty: '테스트를 시작하면\n여기에 보여요',
                          busy: _s.running,
                        ),
                      ],
                    ),
                    if (_s.target != null && !_s.running)
                      Wrap(
                        spacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: _pick,
                            icon: const Icon(
                              Icons.swap_horiz_rounded,
                              size: 18,
                            ),
                            label: const Text('정답지 바꾸기'),
                          ),
                          TextButton.icon(
                            onPressed: () => _s.setTarget(null),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.error,
                            ),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            label: const Text('정답지 지우기'),
                          ),
                        ],
                      ),
                    const SizedBox(height: 10),
                    const Divider(height: 1),
                    const SizedBox(height: 6),
                    // 목표 점수
                    Row(
                      children: [
                        const Text(
                          '🎯 목표 점수',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 12),
                        SegmentedButton<int>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: 80, label: Text('80점 이상')),
                            ButtonSegment(value: 90, label: Text('90점 이상')),
                          ],
                          selected: {_s.passScore},
                          onSelectionChanged: _s.running
                              ? null
                              : (v) => _s.setPassScore(v.first),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // 실행 옵션
                    CheckboxListTile(
                      value: !_s.compareAll,
                      onChanged: _s.running
                          ? null
                          : (v) => _s.setCompareAll(!(v ?? true)),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        '현재 선택한 엔진만 테스트 (${widget.engine.tag} · ${widget.engine.label})',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    CheckboxListTile(
                      value: _s.compareAll,
                      onChanged: _s.running
                          ? null
                          : (v) => _s.setCompareAll(v ?? false),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        '옵션 A · B · C 전체 자동 비교 테스트',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '세 엔진을 차례로 각각 최대 $kMaxTries회 테스트하고 순위를 매깁니다'
                        '${!st.hasFal
                            ? ' · ⚠ Fal.ai 키가 없어 A·B·C 모두 1단계가 안 됩니다'
                            : !st.hasVertex
                            ? ' · ⚠ Vertex 키가 없어 C는 테스트되지 않습니다'
                            : ''}',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '목표 ${_s.passScore}점 · 최대 $kMaxTries회 · 원본·정답지·결과 3장 비교, 4대 기준 각 25점'
                      '${QaSettings.active != null ? ' · 채점 모델: ${QaSettings.active}' : ''}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.gray500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _modelCtrl,
                      enabled: !_s.running,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: '채점 모델 (비워 두면 자동으로 찾음)',
                        hintText: '예: gemini-3.1-pro',
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 52,
                      child: _s.running
                          ? OutlinedButton.icon(
                              onPressed: () {
                                _s.stop();
                              },
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const Text('중지'),
                            )
                          : FilledButton.icon(
                              onPressed: !ready ? null : _start,
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(
                                _s.target == null
                                    ? '자동 QA 테스트 시작 (정답지 없이 자체 평가)'
                                    : '자동 QA 테스트 시작',
                              ),
                            ),
                    ),
                    if (!ready)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'AI 연결이 준비되지 않았습니다 (태블릿 앱에서 [API 키 설정] 확인)',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.error,
                          ),
                        ),
                      ),
                    if (_s.status.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _s.status,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.blueDeep,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (ranked != null) _report(),
              if (ranked != null)
                for (var i = 0; i < ranked.length; i++)
                  _runCard(
                    ranked[i],
                    rank: ranked[i].fatal == null ? i + 1 : null,
                  )
              else
                for (final r in _s.runs) _runCard(r),
            ],
          ),
        ),
      ),
    );
  }
}

class _Th extends StatelessWidget {
  const _Th(this.t);
  final String t;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Text(
      t,
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
    ),
  );
}

class _Td extends StatelessWidget {
  const _Td(this.t);
  final String t;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Text(t, style: const TextStyle(fontSize: 12.5)),
  );
}
