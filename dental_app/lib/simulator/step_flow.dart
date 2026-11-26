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
                            child: SingleChildScrollView(child: _stepPanel()),
                          ),
                          const SizedBox(height: 10),
                          _stepNav(),
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
              children: [_stepPanel(), const SizedBox(height: 12), _stepNav()],
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
          _convertBox(locked),
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
}
