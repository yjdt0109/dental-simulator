import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'records.dart';

/// 환자 기록에서 고른 사진 한 장
typedef PickedPhoto = ({
  Uint8List bytes,
  String label,
  String sub,
  bool smile,
  Uint8List? pair, // 같은 촬영의 짝 (결과 → 원본, 미소 미리보기 → 미소)
});

/// 🗂 환자 기록에서 사진 여러 장 고르기 (누른 차례대로 번호가 붙고, 그 차례대로 돌려줌).
/// [smileFirst]: 미소 사진을 먼저 보여 줌 (미소 미리보기에서 열 때)
Future<List<PickedPhoto>?> pickRecordPhotos(
  BuildContext context, {
  bool smileFirst = false,
}) => Navigator.of(context).push<List<PickedPhoto>>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => RecordPhotoPicker(smileFirst: smileFirst),
  ),
);

class RecordPhotoPicker extends StatefulWidget {
  const RecordPhotoPicker({super.key, this.smileFirst = false});
  final bool smileFirst;

  @override
  State<RecordPhotoPicker> createState() => _RecordPhotoPickerState();
}

class _RecordPhotoPickerState extends State<RecordPhotoPicker> {
  final _q = TextEditingController();
  final _store = PatientRecords.instance;
  PatientRecord? _open;
  List<PickedPhoto> _photos = [];
  bool _loading = false;
  final List<PickedPhoto> _picked = []; // 누른 차례대로

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _openRecord(PatientRecord r) async {
    setState(() {
      _open = r;
      _loading = true;
      _photos = [];
    });
    final f = await readRecordFiles(r);
    if (!mounted || _open != r) return;
    final who = r.name.isEmpty ? '기록' : r.name;
    final day = '${r.dayText} ${r.time}';
    final list = <PickedPhoto>[
      if (f?.smile != null)
        (
          bytes: f!.smile!,
          label: '😊 $who 미소',
          sub: '환자 기록 · $day',
          smile: true,
          pair: null,
        ),
      if (f?.smileAfter != null)
        (
          bytes: f!.smileAfter!,
          label: '😊 $who 미소 미리보기',
          sub: '환자 기록 · $day',
          smile: false,
          pair: f.smile,
        ),
    ];
    final rest = <PickedPhoto>[
      if (f != null)
        (
          bytes: f.before,
          label: '$who 원본',
          sub: '환자 기록 · $day',
          smile: false,
          pair: null,
        ),
      if (f != null)
        for (var i = 0; i < f.results.length; i++)
          (
            bytes: f.results[i].bytes,
            label: r.shots.length > i ? r.shots[i].label : '$who ${i + 1}번',
            sub: '환자 기록 · $day',
            smile: false,
            pair: f.before,
          ),
    ];
    setState(() {
      _loading = false;
      _photos = widget.smileFirst ? [...list, ...rest] : [...rest, ...list];
    });
  }

  void _toggle(PickedPhoto ph) => setState(() {
    final i = _picked.indexWhere((x) => identical(x.bytes, ph.bytes));
    i >= 0 ? _picked.removeAt(i) : _picked.add(ph);
  });

  @override
  Widget build(BuildContext context) {
    final r = _open;
    return Scaffold(
      backgroundColor: AppColors.gray50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        leading: r == null
            ? null
            : IconButton(
                tooltip: '기록 목록으로',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => setState(() => _open = null),
              ),
        title: Text(
          r == null ? '🗂 환자 기록에서 사진 불러오기' : '${r.name} · ${r.dayText}',
        ),
      ),
      body: r == null ? _list() : _grid(),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _picked.isEmpty
                      ? '사진을 누른 차례대로 비교 목록에 들어가요 (여러 기록에서 골라도 돼요)'
                      : '${_picked.length}장 골랐어요',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.gray500,
                  ),
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: _picked.isEmpty
                    ? null
                    : () => Navigator.pop(context, [..._picked]),
                icon: const Icon(Icons.download_done_rounded),
                label: Text('불러오기 (${_picked.length}장)'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list() {
    final list = _store.search(query: _q.text);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _q,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '환자 이름 · 날짜 · 치료 종류',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('저장된 기록이 없어요'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final x = list[i];
                    return Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      child: ListTile(
                        title: Text(
                          x.name.isEmpty ? '(이름 없음)' : x.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${x.dayText} ${x.time} · ${x.treatments.join(', ')}'
                          '${x.hasSmile ? ' · 😊 미소' : ''} · 결과 ${x.shots.length}장',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _openRecord(x),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _grid() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_photos.isEmpty) return const Center(child: Text('사진을 찾지 못했어요'));
    return GridView.extent(
      padding: const EdgeInsets.all(12),
      maxCrossAxisExtent: 260,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 0.95,
      children: [
        for (final ph in _photos)
          Builder(
            builder: (_) {
              final k = _picked.indexWhere((x) => identical(x.bytes, ph.bytes));
              final on = k >= 0;
              return Material(
                color: on ? AppColors.blueSoft : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: on ? AppColors.blue : AppColors.gray200,
                    width: on ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _toggle(ph),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  ph.bytes,
                                  fit: BoxFit.cover,
                                  cacheWidth: 400,
                                ),
                              ),
                              if (on)
                                Positioned(
                                  right: 6,
                                  top: 6,
                                  child: CircleAvatar(
                                    radius: 14,
                                    backgroundColor: AppColors.blue,
                                    child: Text(
                                      '${k + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ph.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
