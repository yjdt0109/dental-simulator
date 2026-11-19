import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../simulator/sim_models.dart' show kTreatments, teethSummary;
import 'records.dart';
import '../simulator/sim_import.dart';

/// 🗂 환자 기록: 검색(이름·날짜·치료종류) → 날짜 폴더 › 환자이름 폴더 › 기록
class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});
  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  final _q = TextEditingController();
  final _store = PatientRecords.instance;
  DateTime? _day;
  String? _tx;
  final Set<String> _closedDays = {};

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _store.ensureLoaded();
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    _q.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _day ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: '날짜로 찾기',
    );
    if (d != null) setState(() => _day = d);
  }

  @override
  Widget build(BuildContext context) {
    final list = _store.search(query: _q.text, day: _day, tx: _tx);
    final tree = groupRecords(list);
    final w = MediaQuery.sizeOf(context).width;
    final pad = w < 600 ? 14.0 : 24.0;
    return Scaffold(
      backgroundColor: AppColors.gray50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          '🗂 환자 기록',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: AppColors.blueDeep,
          ),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.gray200),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ListView(
            padding: EdgeInsets.fromLTRB(pad, 16, pad, 32),
            children: [
              TextField(
                controller: _q,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '이름 · 날짜(예: 11.18) · 치료종류로 검색',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _q.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '지우기',
                          onPressed: () => setState(_q.clear),
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  InputChip(
                    avatar: const Icon(Icons.event_outlined, size: 18),
                    label: Text(_day == null ? '날짜 선택' : dayLabel(_day!)),
                    selected: _day != null,
                    onPressed: _pickDay,
                    onDeleted: _day == null
                        ? null
                        : () => setState(() => _day = null),
                  ),
                  for (final t in kTreatments)
                    FilterChip(
                      label: Text(t),
                      selected: _tx == t,
                      onSelected: (v) => setState(() => _tx = v ? t : null),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                _store.records.isEmpty
                    ? ''
                    : '${list.length}건 · 날짜 폴더 ${tree.length}개'
                          '${list.length == _store.records.length ? '' : ' (전체 ${_store.records.length}건 중)'}',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.gray500,
                ),
              ),
              const SizedBox(height: 8),
              if (_store.records.isEmpty)
                const _Empty(
                  '아직 저장된 환자 기록이 없습니다.\n시뮬레이터에서 변환 후 [시뮬레이션 결과 저장 및 상담 완료]를 누르면\n날짜 › 환자이름 폴더로 저장됩니다.',
                )
              else if (list.isEmpty)
                const _Empty('검색 결과가 없습니다. 이름·날짜·치료종류를 바꿔 보세요.'),
              for (final (day, names) in tree)
                _DayFolder(
                  day: day,
                  names: names,
                  open: !_closedDays.contains(day),
                  onToggle: () => setState(
                    () => _closedDays.contains(day)
                        ? _closedDays.remove(day)
                        : _closedDays.add(day),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(color: AppColors.gray500, height: 1.6),
    ),
  );
}

class _DayFolder extends StatelessWidget {
  const _DayFolder({
    required this.day,
    required this.names,
    required this.open,
    required this.onToggle,
  });
  final String day;
  final List<(String, List<PatientRecord>)> names;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final first = names.first.$2.first;
    final n = names.fold<int>(0, (a, e) => a + e.$2.length);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.gray200),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                child: Row(
                  children: [
                    Icon(
                      open ? Icons.folder_open_rounded : Icons.folder_rounded,
                      color: AppColors.blue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        first.dayText,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '환자 ${names.length}명 · $n건',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.gray500,
                      ),
                    ),
                    Icon(
                      open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ],
                ),
              ),
            ),
            if (open)
              for (final (name, recs) in names)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.folder_shared_outlined,
                            size: 20,
                            color: AppColors.blueDeep,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '$name 님',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14.5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${recs.length}건',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.gray500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      for (final r in recs) _RecordTile(r),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

Future<Uint8List?> _read(PatientRecord r, String f) async {
  final file = await PatientRecords.instance.file(r, f);
  return await file.exists() ? file.readAsBytes() : null;
}

class _Img extends StatelessWidget {
  const _Img(this.r, this.file, {this.fit = BoxFit.cover});
  final PatientRecord r;
  final String file;
  final BoxFit fit;
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _read(r, file),
    builder: (context, s) => s.data == null
        ? const ColoredBox(color: AppColors.gray100)
        : Image.memory(s.data!, fit: fit, gaplessPlayback: true),
  );
}

class _RecordTile extends StatelessWidget {
  const _RecordTile(this.r);
  final PatientRecord r;

  @override
  Widget build(BuildContext context) {
    final last = r.shots.isEmpty ? null : r.shots.last;
    return Padding(
      padding: const EdgeInsets.only(left: 26, bottom: 8),
      child: Material(
        color: AppColors.gray50,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => RecordDetailScreen(record: r)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                for (final f in ['before.jpg', ?last?.file]) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(width: 74, height: 54, child: _Img(r, f)),
                  ),
                  const SizedBox(width: 6),
                ],
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${r.time} · ${r.treatments.isEmpty ? '치료 미선택' : r.treatments.join(', ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (r.teeth.isNotEmpty) teethSummary(r.teeth),
                          if (r.shade != null) '셰이드 ${r.shade}',
                          '변환 ${r.shots.length}장',
                          if (last != null && last.check.isNotEmpty)
                            last.check.startsWith('✓')
                                ? '🦷 무삭제 검사 통과'
                                : '🦷 ⚠ 검사 주의',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.gray500,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 기록 상세: 원본 · 변환 결과(들) · 상담 내용
class RecordDetailScreen extends StatefulWidget {
  const RecordDetailScreen({super.key, required this.record});
  final PatientRecord record;
  @override
  State<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends State<RecordDetailScreen> {
  late int _sel = widget.record.shots.length; // 0 = 원본, 마지막 = 최종 After

  bool _loading = false;

  /// 🖼 이 기록을 시뮬레이터로 다시 불러오기 ([smile]: 불러온 뒤 미소 미리보기 바로 열기)
  Future<void> _load({bool smile = false}) async {
    final r = widget.record;
    setState(() => _loading = true);
    final f = await readRecordFiles(r);
    if (!mounted) return;
    if (f == null) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('기록 사진을 찾지 못했습니다.')));
      return;
    }
    final msg = await CaseLoader.run(
      LoadedCase(
        before: f.before,
        results: f.results,
        name: r.name,
        treatments: r.treatments,
        teeth: r.teeth,
        shade: r.shade,
        memo: r.memo,
        photoType: r.photoType,
        smile: f.smile,
        smileAfter: f.smileAfter,
        smileFrom: r.shots.isEmpty ? '' : r.shots.last.label,
        recordId: r.id,
      ),
      openSmile: smile,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (CaseLoader.handler == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _delete() async {
    final r = widget.record;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('이 기록을 삭제할까요?'),
        content: Text(
          '${r.dayText} ${r.time} · ${r.name} 님 기록과 사진이 태블릿에서 지워집니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await PatientRecords.instance.remove(r);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final files = ['before.jpg', for (final s in r.shots) s.file];
    String label(int i) => i == 0 ? '원본 (치료 전)' : r.shots[i - 1].label;
    Widget big(int i) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label(i), style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: ColoredBox(
              color: const Color(0xFF0D1622),
              child: InteractiveViewer(
                maxScale: 6,
                child: _Img(r, files[i], fit: BoxFit.contain),
              ),
            ),
          ),
        ),
        if (i > 0 && r.shots[i - 1].check.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '🦷 ${r.shots[i - 1].check}',
              style: const TextStyle(fontSize: 12.5, color: AppColors.gray500),
            ),
          ),
      ],
    );
    final info = [
      ('상담 날짜', '${r.dayText} ${r.time}'),
      ('환자', '${r.name} 님'),
      ('사진', r.photoType.isEmpty ? '-' : r.photoType),
      ('치료 항목', r.treatments.isEmpty ? '선택 안 함' : r.treatments.join(', ')),
      (
        '치료 부위',
        r.teeth.isEmpty
            ? '-'
            : '${r.teeth.map((t) => '#$t').join(' ')} (${r.teeth.length}개)',
      ),
      ('희망 셰이드', r.shade ?? '선택 안 함'),
      ('메모', r.memo.isEmpty ? '(메모 없음)' : r.memo),
      ('저장 폴더', r.folder.replaceAll('/', ' › ')),
    ];
    return Scaffold(
      backgroundColor: AppColors.gray50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text('${r.name} 님 · ${r.dayText}'),
        actions: [
          IconButton(
            tooltip: '기록 삭제',
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline, color: AppColors.error),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: _loading ? null : () => _load(),
                    icon: const Icon(Icons.input_rounded),
                    label: const Text('🖼 시뮬레이터로 불러오기'),
                  ),
                  if (r.shots.isNotEmpty)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                      ),
                      onPressed: _loading ? null : () => _load(smile: true),
                      icon: const Icon(Icons.sentiment_very_satisfied_outlined),
                      label: Text(
                        r.hasSmile ? '😊 미소 미리보기 다시 하기' : '😊 미소 미리보기',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '불러오면 원본·변환 결과·상담 내용이 시뮬레이터에 다시 열려, 비교·미소 미리보기·치아 크기 조절을 이어서 할 수 있어요.',
                style: TextStyle(fontSize: 12, color: AppColors.gray500),
              ),
              const SizedBox(height: 12),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: big(0)),
                    const SizedBox(width: 12),
                    Expanded(child: big(_sel)),
                  ],
                )
              else ...[
                big(0),
                const SizedBox(height: 12),
                big(_sel),
              ],
              if (r.shots.length > 1) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var i = 1; i <= r.shots.length; i++)
                      ChoiceChip(
                        label: Text(label(i)),
                        selected: _sel == i,
                        onSelected: (_) => setState(() => _sel = i),
                      ),
                  ],
                ),
              ],
              if (r.hasSmile) ...[
                const SizedBox(height: 14),
                const Text(
                  '😊 미소 미리보기',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (final (f, l) in [
                      ('smile_before.jpg', '미소 (치료 전)'),
                      ('smile_after.jpg', '미소 미리보기'),
                    ]) ...[
                      if (f != 'smile_before.jpg') const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l, style: const TextStyle(fontSize: 12.5)),
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: AspectRatio(
                                aspectRatio: 4 / 3,
                                child: ColoredBox(
                                  color: const Color(0xFF0D1622),
                                  child: InteractiveViewer(
                                    maxScale: 6,
                                    child: _Img(r, f, fit: BoxFit.contain),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: AppColors.gray200),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      for (final (k, v) in info)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 84,
                                child: Text(
                                  k,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.gray500,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  v,
                                  style: const TextStyle(fontSize: 13.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
