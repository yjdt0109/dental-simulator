part of 'simulator_screen.dart';

// -----------------------------------------------------------------------------
// 🆕 단계형 시뮬레이터 화면 (새 단장)
//   ① 사진 → ② 치아 고르기 → ③ 치료 정하기 → ④ After 만들기 → ⑤ 다듬기 → ⑥ Final Smile → ⑦ 저장
//   기능(변환·🪄·크기 조절·Final Smile·저장·PC 연결)은 기존 것을 그대로 쓰고 화면 흐름만 새로.
// -----------------------------------------------------------------------------

const kSteps = [
  '사진',
  '치아 고르기',
  '치료 정하기',
  'After 만들기',
  '다듬기',
  'Final Smile',
  '저장',
];

extension _StepFlow on _SimulatorHomeScreenState {
  /// 단계마다 할 일을 끝냈는지 (단계 표시줄의 ✓)
  bool _stepDone(int k) {
    final p = _cur!;
    final c = _c;
    return switch (k) {
      1 => _slotPhoto(p, 2) != null || _slotPhoto(p, 1) != null,
      2 => p.hasSam,
      3 => c.tx.isNotEmpty && c.teeth.isNotEmpty,
      4 => p.results.isNotEmpty,
      5 => p.results.any((r) => r.engine.contains('크기조절')),
      6 => p.extras.any((e) => e.label.contains('Final Smile')),
      7 => c.doneAt != null,
      _ => false,
    };
  }

  /// 단계 이동 → 그 단계에 맞는 화면 (원본·After·미소)
  void _goStep(int k) {
    final p = _cur;
    if (p == null) return;
    _ss(() {
      _step = k.clamp(1, kSteps.length);
      switch (_step) {
        case 1 || 2 || 3:
          if (!p.editing) _toEditView(p);
          _smileView = false;
        case 4 || 5:
          _smileView = false;
          if (p.results.isNotEmpty) {
            p.editing = false;
            p.sel = [0, p.results.length];
          }
        case 6:
          if (p.smileAfter != null) {
            p.editing = false;
            _smileView = true;
          }
        default:
          break;
      }
    });
  }

  Widget _stepBar() {
    final phone = MediaQuery.sizeOf(context).width < 700;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var k = 1; k <= kSteps.length; k++) ...[
            if (k > 1)
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.gray500.withValues(alpha: 0.6),
              ),
            Material(
              color: _step == k
                  ? AppColors.blue
                  : _stepDone(k)
                  ? AppColors.blueSoft
                  : Colors.white,
              shape: StadiumBorder(
                side: BorderSide(
                  color: _step == k ? AppColors.blue : AppColors.gray200,
                ),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: _converting ? null : () => _goStep(k),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: phone ? 9 : 12,
                    vertical: 7,
                  ),
                  child: Text(
                    '${_stepDone(k) && _step != k ? '✓' : '$k'} ${phone && _step != k ? '' : kSteps[k - 1]}'
                        .trim(),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: _step == k ? Colors.white : AppColors.blueDeep,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 새 화면 배치: 위 단계 표시줄 · 왼쪽 사진 · 오른쪽(또는 아래) 지금 단계 패널
  Widget _stepLayout(bool wide, BoxConstraints c) {
    if (wide) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _stepBar(),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _viewerCard(fill: true)),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 400,
                    child: _card(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              child: _advOpen ? _advancedPanel() : _stepPanel(),
                            ),
                          ),
                          if (!_advOpen) ...[
                            const SizedBox(height: 10),
                            _stepNav(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final pad = c.maxWidth < 600 ? 12.0 : 20.0;
    final w = c.maxWidth - pad * 2 - 24;
    final phone = c.maxWidth < 700;
    final stageH = _mode == _ViewMode.stack
        ? (phone ? w * 0.75 * 2 + 8 : c.maxHeight * 0.6)
        : (phone ? w * 4 / 3 : c.maxHeight * 0.5);
    return SingleChildScrollView(
      controller: _scroll,
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepBar(),
          const SizedBox(height: 12),
          _viewerCard(fill: false, stageHeight: stageH),
          const SizedBox(height: 14),
          _card(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _advOpen
                  ? [_advancedPanel()]
                  : [_stepPanel(), const SizedBox(height: 12), _stepNav()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepNav() {
    final next = _step < kSteps.length;
    return Row(
      children: [
        if (_step > 1)
          OutlinedButton.icon(
            onPressed: _converting ? null : () => _goStep(_step - 1),
            icon: const Icon(Icons.chevron_left_rounded),
            label: const Text('이전'),
          ),
        const SizedBox(width: 8),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: next
                ? FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: _converting ? null : () => _goStep(_step + 1),
                    icon: const Icon(Icons.chevron_right_rounded),
                    label: Text(
                      '다음: ${kSteps[_step]}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                : FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: _newCase,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('＋ 새 작업'),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _stepTitle(String t, String help) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$_step. $t',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.blueDeep,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          help,
          style: const TextStyle(
            fontSize: 12.5,
            color: AppColors.gray500,
            height: 1.45,
          ),
        ),
      ],
    ),
  );

  // 스위치·펼침 목록이 그려질 수 있게 투명 Material 로 감쌈
  Widget _stepPanel() =>
      Material(type: MaterialType.transparency, child: _stepPanelBody());

  Widget _stepPanelBody() {
    final p = _cur!;
    final c = _c;
    final locked = c.doneAt != null;
    return switch (_step) {
      1 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle(
            '사진 넣기',
            '원본 2(개구기)는 변환에, 원본 1(자연스러운 미소)은 Final Smile 에 씁니다. '
                '카드를 눌러 변환할 사진을 고르고, 옆으로 누운 사진은 ⟲ ⟳ 로 돌리세요.',
          ),
          _slotCard(p, 2),
          const SizedBox(height: 10),
          _slotCard(p, 1),
        ],
      ),
      2 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle(
            '치아 고르기',
            '사진에서 치료할 치아를 하나씩 누르세요 (🪄 자동으로 윤곽을 찾아요). 다시 누르면 빠집니다. '
                '이웃 치아까지 고르면 치아 사이 틈도 자연스럽게 채워져요.',
          ),
          if (!_samOn)
            _warn(
              _useAi
                  ? '🪄 자동 선택에는 Fal.ai 키가 필요해요 ([🔑 API 키 설정]). 고르지 않고 넘어가면 AI 가 치아 전체를 바꿉니다.'
                  : 'AI 를 켜야 치아를 고를 수 있어요.',
            )
          else
            Text(
              p.hasSam ? '✓ 고른 치아 ${p.sam.length}개' : '아직 고른 치아가 없어요',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: p.samHistory.isEmpty ? null : () => _samUndo(p),
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('마지막 선택 취소'),
              ),
              OutlinedButton.icon(
                onPressed: p.sam.isEmpty ? null : () => _samClear(p),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('모두 지우기'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              '고급: 서비컬 라인 직접 그리기',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
            children: [if (_useAi) _guideCheck(p)],
          ),
        ],
      ),
      3 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle('치료 정하기', '환자 이름 · 치료 종류 · 치료 부위 · 희망 셰이드를 정하세요.'),
          _panelParts(locked, const {1, 2, 3, 4, 6}),
        ],
      ),
      4 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle(
            'After 만들기',
            '[After 변환하기]를 누르면 고른 치아만 새로 만들어요. 결과는 왼쪽 목록에 After 1, 2 … 로 쌓이고, '
                '결과를 누르면 그 결과를 기준으로 다시 다듬을 수 있어요.',
          ),
          _step4(p, locked),
        ],
      ),
      5 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle(
            '다듬기',
            '왼쪽 목록에서 다듬을 사진(After·Final Smile 등)을 누르고 치아 크기를 키우거나 줄이세요. '
                '다듬은 결과는 새 사진으로 추가돼요. 마음에 안 들면 [이전으로].',
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
            onPressed: _rzTargetOf(p) == null || locked
                ? null
                : () => _openResize(p),
            icon: const Icon(Icons.open_in_full_rounded),
            label: Text(
              _rzTargetOf(p) == null
                  ? '🦷 치아 크기 조절 (먼저 After 를 만드세요)'
                  : '🦷 치아 크기 조절 · ${_label(p, _rzTargetOf(p)!)}',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _showContour,
            onChanged: (v) => _ss(() => _showContour = v),
            title: const Text('원본 윤곽 겹쳐 보기'),
            subtitle: const Text('After 위에 원본 잇몸선(초록)·절단선(노랑)을 점선으로'),
          ),
          if (p.history.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () {
                late String? label;
                _ss(() => label = p.undo());
                if (label != null) _toast('↶ \'$label\' 이전 상태로 돌아갔습니다.');
              },
              icon: const Icon(Icons.undo_rounded),
              label: Text('이전으로 (${p.history.last.label} 취소)'),
            ),
        ],
      ),
      6 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle(
            'Final Smile',
            '원본 1(자연스러운 미소)에 After 치열을 맞춰 최종 미소를 만들어요. 입술·얼굴은 원본 1 그대로 둡니다.',
          ),
          _slotCard(p, 1),
          const SizedBox(height: 10),
          Text(
            _finalAfter(p) == null
                ? '⚠ 먼저 4단계에서 After 를 만들어 주세요'
                : '쓸 After: ${_finalAfterLabel(p)}',
            style: const TextStyle(fontSize: 12.5, color: AppColors.gray500),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            onPressed: _finalReady(p) ? () => _finalSmile(p) : null,
            icon: _finalBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(_finalBusy ? '만드는 중…' : '✨ Final Smile 만들기'),
          ),
          if (_finalMsg.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_finalMsg, style: const TextStyle(color: AppColors.blueDeep)),
          ],
          if (p.smileAfter != null) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _smileView,
              onChanged: (v) => _ss(() {
                _smileView = v;
                if (v) p.editing = false;
              }),
              title: const Text('미소 원본 ↔ Final Smile 비교'),
            ),
          ],
        ],
      ),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle(
            '저장',
            '환자 기록(날짜 › 환자이름)에 원본·After·미소 결과·상담 내용을 저장해요. '
                'PC 상담 모니터에서 폴더 저장을 켜 두면 PC 에도 함께 저장됩니다.',
          ),
          _summary(p),
          const SizedBox(height: 12),
          _panelParts(locked, const {7}),
        ],
      ),
    };
  }

  String _finalAfterLabel(PatientPhoto p) {
    for (final q in [p, p.pair]) {
      if (q == null || _shownAfter(q) == null) continue;
      final n = q.compare.where((i) => i > 0).lastOrNull ?? q.results.length;
      return identical(q, p) ? _label(q, n) : '${_label(q, n)} (원본 ${q.slot})';
    }
    return '';
  }

  Widget _warn(String t) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF7E6),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFFFD591)),
    ),
    child: Text(t, style: const TextStyle(fontSize: 12.5)),
  );

  Widget _summary(PatientPhoto p) {
    final c = _c;
    final rows = [
      ('환자', c.name.trim().isEmpty ? '(이름 없음)' : '${c.name.trim()} 님'),
      ('치료', c.tx.isEmpty ? '선택 안 함' : c.tx.join(', ')),
      ('부위', c.teeth.isEmpty ? '-' : teethSummary(sortTeeth(c.teeth))),
      ('셰이드', c.shade ?? '선택 안 함'),
      ('After', '${p.results.length}장'),
      (
        'Final Smile',
        p.extras.any((e) => e.label.contains('Final Smile')) ? '있음' : '없음',
      ),
    ];
    return Column(
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text(
                    k,
                    style: const TextStyle(color: AppColors.gray500),
                  ),
                ),
                Expanded(
                  child: Text(
                    v,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 원본 슬롯 큰 카드 (사진 · 변환할 사진 고르기 · 넣기/바꾸기 · 돌리기)
  Widget _slotCard(PatientPhoto p, int k) {
    final q = _slotPhoto(p, k);
    final b = k == 1 ? _slot1Bytes(p) : q?.beforeBytes;
    final sel = p.slot == k && !p.blank;
    final busy = _converting || _finalBusy;
    return Material(
      color: sel ? AppColors.blueSoft : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: sel ? AppColors.blue : AppColors.gray200,
          width: sel ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy
            ? null
            : () => b == null ? _slotUpload(p, k) : _slotSelect(p, k),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    sel
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: sel ? AppColors.blue : AppColors.gray500,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      k == 1 ? '원본 1 · 자연스러운 미소' : '원본 2 · 개구기',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (sel)
                    const Text(
                      '변환할 사진',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.blue,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              AspectRatio(
                aspectRatio: 4 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: b == null
                      ? const ColoredBox(
                          color: AppColors.gray100,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.add_a_photo_outlined,
                                  size: 34,
                                  color: AppColors.gray500,
                                ),
                                SizedBox(height: 6),
                                Text(
                                  '눌러서 사진 넣기 (촬영·갤러리)',
                                  style: TextStyle(color: AppColors.gray500),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ColoredBox(
                          color: const Color(0xFF0D1622),
                          child: Image.memory(
                            b,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            cacheWidth: 600,
                          ),
                        ),
                ),
              ),
              if (b != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton.outlined(
                      tooltip: '왼쪽으로 돌리기',
                      onPressed: busy || (k == 1 && _slotPhoto(p, 1) == null)
                          ? null
                          : () => _rotateSlot(p, k, -1),
                      icon: const Icon(Icons.rotate_left_rounded),
                    ),
                    const SizedBox(width: 6),
                    IconButton.outlined(
                      tooltip: '오른쪽으로 돌리기',
                      onPressed: busy || (k == 1 && _slotPhoto(p, 1) == null)
                          ? null
                          : () => _rotateSlot(p, k, 1),
                      icon: const Icon(Icons.rotate_right_rounded),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: busy ? null : () => _slotUpload(p, k),
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: const Text('사진 바꾸기'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── ④ After 만들기 (간단): 큰 버튼 · 추가 요청 · 엔진 한 줄 ─────────────────
  Widget _step4(PatientPhoto p, bool locked) {
    final c = _c;
    final converted = _converted, stale = _stale;
    final eff = _useAi ? _engineNow() : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          eff == null
              ? '엔진: AI 꺼짐 (기본 미백 방식)'
              : '엔진: ${eff.engine.tag} · ${eff.engine.label}${eff.note == null ? '' : '\n${eff.note}'}',
          style: const TextStyle(fontSize: 12.5, color: AppColors.gray500),
        ),
        const SizedBox(height: 6),
        _baseLine(p),
        if (_useAi) ...[
          const Text(
            '추가 요청 (선택)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _aiReqCtrl,
            enabled: !locked,
            minLines: 2,
            maxLines: 5,
            style: const TextStyle(fontSize: 13, height: 1.4),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.all(10),
              hintText: '예: 11·21 절단끝 0.5mm 길게, 좌우 대칭, 22번 깨진 끝 복원',
            ),
            onChanged: (v) {
              AiService.instance.saveRequest(v);
              _ss(() {});
            },
          ),
          const SizedBox(height: 10),
        ],
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            onPressed: locked || _converting ? null : _convert,
            icon: _converting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.auto_fix_high_rounded),
            label: Text(
              _converting
                  ? '만드는 중…'
                  : converted
                  ? '✨ 다시 만들기 (After ${p.results.length + 1})'
                  : '✨ After 만들기',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _converting
              ? _convertMsg
              : !converted
              ? '고른 치아만 새로 만들어요. 결과는 왼쪽 목록에 쌓입니다.'
              : stale
              ? '설정이 바뀌었어요 · [다시 만들기]로 반영하세요'
              : '✓ 셰이드 ${c.shade ?? '선택 안 함'}로 만들었어요 · 마음에 들면 [다음]',
          style: TextStyle(
            fontSize: 12,
            color: stale ? const Color(0xFFB26A00) : AppColors.gray500,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _ss(() => _advOpen = true),
            icon: const Icon(Icons.tune_rounded, size: 18),
            label: const Text('엔진·강도·지시문 바꾸기 (⚙ 고급)'),
          ),
        ),
      ],
    );
  }

  // ── ⚙ 고급 설정 패널 ──────────────────────────────────────────────
  Widget _advancedPanel() {
    final p = _cur!;
    final c = _c;
    final locked = c.doneAt != null;
    Widget sec(String t, Widget child, {String? help}) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t, style: const TextStyle(fontWeight: FontWeight.w800)),
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                help,
                style: const TextStyle(fontSize: 12, color: AppColors.gray500),
              ),
            ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '⚙ 고급 설정',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppColors.blueDeep,
                  ),
                ),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: () => _ss(() => _advOpen = false),
                child: Text('닫고 $_step단계로'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          sec(
            'AI 엔진 · 자동 임상 지시 · 추가 요청',
            _aiRow(locked),
            help: '평소엔 옵션 B. 비교해 보고 싶을 때만 바꾸세요.',
          ),
          sec(
            '적용 강도 ${c.strength}%',
            Slider(
              value: c.strength.toDouble(),
              min: 30,
              max: 100,
              divisions: 14,
              label: '${c.strength}%',
              onChanged: locked
                  ? null
                  : (v) => _ss(() => c.strength = v.round()),
            ),
          ),
          sec('미소 사진 참고 변환 (원본 2장)', _smileRefBox(p)),
          if (_useAi)
            sec(
              '서비컬 라인 직접 그리기',
              _guideCheck(p),
              help: '🪄 치아 고르기 대신 잇몸선을 손으로 그릴 때 (체크하면 원본 화면으로)',
            ),
          sec(
            '보기',
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _showContour,
              onChanged: (v) => _ss(() => _showContour = v),
              title: const Text('원본 윤곽 겹쳐 보기'),
            ),
          ),
          if (EyeMasker.supported)
            sec(
              '개인정보',
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _eyeMask,
                onChanged: (v) {
                  _ss(() => _eyeMask = v);
                  SharedPreferences.getInstance()
                      .then(
                        (pr) => pr.setBool(
                          _SimulatorHomeScreenState._prefEyeMask,
                          v,
                        ),
                      )
                      .ignore();
                },
                title: const Text('개구기 사진 눈 자동 가리기'),
              ),
            ),
          sec(
            '예전 미소 기능',
            OutlinedButton.icon(
              onPressed: () => _openSmile(p),
              icon: const Icon(Icons.sentiment_very_satisfied_outlined),
              label: const Text('😊 미소 미리보기 (미소에 입히기 · 정밀 매칭)'),
            ),
            help: '보통은 6단계 Final Smile 을 쓰세요.',
          ),
          sec(
            'API 키',
            OutlinedButton.icon(
              onPressed: () =>
                  showAiSettingsSheet(context).then((_) => _ss(() {})),
              icon: const Icon(Icons.key_rounded),
              label: const Text('🔑 API 키 · 모델 설정'),
            ),
          ),
        ],
      ),
    );
  }

  // ── 🧪 전문가 메뉴 ───────────────────────────────────────────────
  Widget _expertMenu() => PopupMenuButton<String>(
    tooltip: '🧪 전문가',
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    icon: const Icon(Icons.science_outlined, color: AppColors.blue),
    onSelected: (v) => switch (v) {
      'qa' => _openQa(),
      'archive' => _openArchive(),
      'old' => _toggleUi(),
      'reset' => _resetConsult(),
      _ => _logout(),
    },
    itemBuilder: (_) => [
      if (_pro)
        const PopupMenuItem(
          value: 'qa',
          child: ListTile(
            leading: Icon(Icons.smart_toy_outlined),
            title: Text('🤖 자동 QA'),
          ),
        ),
      if (_pro)
        const PopupMenuItem(
          value: 'archive',
          child: ListTile(
            leading: Icon(Icons.collections_bookmark_outlined),
            title: Text('📚 프롬프트 보관함'),
          ),
        ),
      const PopupMenuItem(
        value: 'old',
        child: ListTile(
          leading: Icon(Icons.view_quilt_outlined),
          title: Text('예전 화면으로 (모든 기능)'),
        ),
      ),
      const PopupMenuItem(
        value: 'reset',
        child: ListTile(
          leading: Icon(Icons.restart_alt_rounded),
          title: Text('상담 초기화'),
        ),
      ),
      const PopupMenuItem(
        value: 'logout',
        child: ListTile(
          leading: Icon(Icons.logout_rounded),
          title: Text('로그아웃'),
        ),
      ),
    ],
  );

  /// 새 화면 위쪽 버튼: ＋ 새 작업 · 🗂 환자 기록 · PC 연결 · ⚙ 고급 · 🧪 전문가
  List<Widget> _stepActions(bool phone) => [
    _barButton(Icons.add_box_outlined, '＋ 새 작업', phone, _newCase),
    _barButton(Icons.folder_shared_outlined, '🗂 환자 기록', phone, _openRecords),
    CastButton(iconOnly: phone),
    _barButton(
      _advOpen ? Icons.tune : Icons.tune_rounded,
      _advOpen ? '⚙ 고급 닫기' : '⚙ 고급',
      phone,
      () => _ss(() => _advOpen = !_advOpen),
    ),
    _expertMenu(),
    const SizedBox(width: 6),
  ];
}
