part of 'simulator_screen.dart';

// -----------------------------------------------------------------------------
// 🆕 단계형 시뮬레이터 화면 (새 단장)
//   ① 사진 → ② 치료 정하기 → ③ After 만들기 → ④ 다듬기 → ⑤ Final Smile → ⑥ 저장
//   (2026.11.27-f: '치아 고르기' 단계 뺌 — 사용자 요청. 🪄 선택은 1단계 사진에서 탭하면 그대로 됨)
//   기능(변환·🪄·크기 조절·Final Smile·저장·PC 연결)은 기존 것을 그대로 쓰고 화면 흐름만 새로.
// -----------------------------------------------------------------------------

const kSteps = ['사진', '치료 정하기', 'After 만들기', '다듬기', 'Final Smile', '저장'];

extension _StepFlow on _SimulatorHomeScreenState {
  /// 단계마다 할 일을 끝냈는지 (단계 표시줄의 ✓)
  bool _stepDone(int k) {
    final p = _cur!;
    final c = _c;
    return switch (k) {
      1 => _slotPhoto(p, 2) != null || _slotPhoto(p, 1) != null,
      2 => c.tx.isNotEmpty && c.teeth.isNotEmpty,
      3 => p.results.isNotEmpty,
      4 => p.results.any((r) => r.engine.contains('크기조절')),
      5 => p.extras.any((e) => e.label.contains('Final Smile')),
      6 => c.doneAt != null,
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
        case 1 || 2:
          if (!p.editing) _toEditView(p);
          _smileView = false;
        case 3 || 4:
          _smileView = false;
          if (p.results.isNotEmpty) {
            p.editing = false;
            p.sel = [0, p.results.length];
          }
        case 5:
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
    // 폰에서는 단계 표시줄 숨김 (사용자 요청 2026.11.27-e) — [이전]/[다음] 으로 이동
    if (phone) return const SizedBox.shrink();
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
          if (!phone) const SizedBox(height: 12),
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
        if (help.isNotEmpty) const SizedBox(height: 4),
        if (help.isNotEmpty)
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
          _stepTitle('치료 정하기', '환자 이름 · 치료 종류 · 치료 부위 · 희망 셰이드를 정하세요.'),
          _panelParts(locked, const {1, 2, 3, 4}), // 상담 메모(6)는 마지막 저장 단계로
        ],
      ),
      3 => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _stepTitle('After 만들기', ''), // 설명 글 뺌 (사용자 요청)
          _step4(p, locked),
        ],
      ),
      4 => Column(
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
      5 => Column(
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
                ? '⚠ 먼저 3단계에서 After 를 만들어 주세요'
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
          _panelParts(locked, const {6, 7}), // 상담 메모 + 저장
        ],
      ),
    };
  }

  /// 🔁 기준 사진 고르기 목록: 원본 2 · 원본 1 · 각 원본의 After 1, 2 …  (k = 원본 번호, n = 0 원본 / N After)
  List<({int k, int n, String label})> _baseChoices(PatientPhoto p) {
    final out = <({int k, int n, String label})>[];
    for (final k in const [2, 1]) {
      final q = _slotPhoto(p, k);
      if (q == null) {
        // 원본 1 은 미소 사진만 넣어 둔 경우도 고를 수 있게 (고르면 원본 1 자리를 만듦)
        if (k == 1 && _slot1Bytes(p) != null) {
          out.add((k: 1, n: 0, label: '원본 1 (미소)'));
        }
        continue;
      }
      out.add((k: k, n: 0, label: _label(q, 0)));
      for (var n = 1; n <= q.results.length; n++) {
        out.add((
          k: k,
          n: n,
          label: '${_label(q, n)}${k == 1 ? ' · 원본 1' : ''}',
        ));
      }
    }
    if (out.isEmpty) out.add((k: p.slot, n: 0, label: _label(p, 0)));
    return out;
  }

  /// 지금 기준 사진 (원본 번호, 0 원본 / N After)
  ({int k, int n}) _baseNow(PatientPhoto p) => (k: p.slot, n: p.baseIndex);

  /// 기준 사진 정하기: 다른 원본이면 그 사진으로 옮기고, 그 사진의 기준을 원본/After N 으로
  Future<void> _pickBase(int k, int n) async {
    final p = _cur;
    if (p == null || _converting) return;
    var q = _slotPhoto(p, k);
    if (q == null && k == 1) {
      await _slotSelect(p, 1);
      q = _cur != null && _cur!.slot == 1 ? _cur : null;
    }
    if (q == null || !mounted) return;
    if (!identical(q, _cur)) _select(q);
    final t = q;
    _ss(() {
      t.basePick = n.clamp(0, t.results.length);
      _smileView = false;
      if (t.results.isEmpty || n == 0) {
        if (t.results.isEmpty) {
          t.editing = true;
        } else {
          t.editing = false;
          t.sel = [0];
        }
      } else {
        t.editing = false;
        t.sel = [0, n];
      }
    });
  }

  /// [기준 사진 고르기] 버튼 + 지금 기준
  Widget _basePicker(PatientPhoto p, bool locked) {
    final now = _baseNow(p);
    final cur = _baseChoices(p).where((c) => c.k == now.k && c.n == now.n);
    final label = cur.isEmpty ? _label(p, p.baseIndex) : cur.first.label;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      onPressed: locked || _converting ? null : () => _openBasePicker(p),
      icon: const Icon(Icons.photo_library_outlined),
      label: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text: '기준 사진 고르기\n',
              style: TextStyle(fontSize: 12, color: AppColors.gray500),
            ),
            TextSpan(
              text: '$label  ▾',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openBasePicker(PatientPhoto p) async {
    final now = _baseNow(p);
    final list = _baseChoices(p);
    final pick = await showModalBottomSheet<({int k, int n, String label})>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '기준 사진 고르기 · 이 사진을 바탕으로 변환해요',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
            for (final c in list)
              ListTile(
                leading: Icon(
                  c.k == now.k && c.n == now.n
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: AppColors.blue,
                ),
                title: Text(c.label),
                onTap: () => Navigator.pop(ctx, c),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (pick != null) await _pickBase(pick.k, pick.n);
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
    // 엔진 설명 글은 뺌 (사용자 요청 2026.11.27-f, 엔진은 ⚙ 고급에서)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _basePicker(p, locked),
        const SizedBox(height: 10),
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
                onChanged: (v) => _setEyeMask(v),
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
            help: '보통은 5단계 Final Smile 을 쓰세요.',
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
