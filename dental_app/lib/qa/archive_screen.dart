import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app_theme.dart';
import 'archive.dart';
import '../simulator/sim_import.dart';

/// 📚 프롬프트 보관함
class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key, this.share});

  /// 시험용: 백업 파일 공유 대신
  final Future<void> Function(List<String> paths)? share;

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  final ar = PromptArchive.instance;
  String _folder = kAllFolder;

  @override
  void initState() {
    super.initState();
    if (!ar.loaded) ar.load();
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _applyDefault(ArchiveCase c) async {
    final tx = c.treatments;
    if (tx.isEmpty) return _toast('치료 종류가 없는 케이스라 기본값으로 적용할 수 없습니다.');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text('${tx.join('·')} 기본 설정으로 적용할까요?'),
        content: Text(
          '앞으로 시뮬레이터에서 [${tx.join('] / [')}] 버튼을 켜면\n'
          '• 추가 요청: ${c.request.isEmpty ? '(비움)' : c.request}\n'
          '• 적용 강도: ${c.strength}%\n'
          '이 자동으로 채워집니다. (이전 기본값은 덮어씁니다)',
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('적용'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final t in tx) {
      await TreatmentDefaults.instance.set(t, c.request, c.strength);
    }
    _toast('✓ ${tx.join('·')} 버튼의 기본 설정으로 적용했습니다 (강도 ${c.strength}%)');
  }

  /// 🖼 이 케이스의 원본·결과를 시뮬레이터 메인 화면으로 (새 환자 사진 + 결과 1번)
  Future<void> _import(ArchiveCase c) async {
    final ar = PromptArchive.instance;
    final o = await ar.imageFile(c.id, 'original');
    final r = await ar.imageFile(c.id, 'result');
    if (!await o.exists() || !await r.exists()) return;
    final msg = await SimImport.run(
      original: await o.readAsBytes(),
      result: await r.readAsBytes(),
      tag: '보관함·${c.engine.split(' ').take(2).join(' ')}',
      treatments: c.treatments,
    );
    if (mounted && SimImport.handler == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _backup(ArchiveCase c) async {
    final paths = await ar.exportCase(c);
    if (widget.share != null) {
      await widget.share!(paths);
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      // 카톡 '나와의 채팅'·구글 드라이브·이메일 등으로 컴퓨터에 보내기
      await SharePlus.instance.share(
        ShareParams(
          files: [for (final p in paths) XFile(p)],
          text: '${c.title} · B&A 프롬프트 보관함 백업',
        ),
      );
    }
    if (mounted) _toast('백업 파일을 만들었습니다: HTML 리포트 + JSON (${paths.length}개)');
  }

  Future<void> _delete(ArchiveCase c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('이 케이스를 지울까요?'),
        content: Text(c.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (ok == true) await ar.remove(c);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ar,
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= 900;
        final list = ar.inFolder(_folder);
        final folders = Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final f in archiveFolders)
              ChoiceChip(
                selected: _folder == f,
                showCheckmark: false,
                selectedColor: AppColors.blue,
                backgroundColor: Colors.white,
                side: BorderSide(
                  color: _folder == f ? AppColors.blue : AppColors.gray200,
                ),
                onSelected: (_) => setState(() => _folder = f),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${f == kAllFolder ? '🗂' : '📁'} $f',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _folder == f ? Colors.white : AppColors.ink,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: _folder == f ? Colors.white : AppColors.blueSoft,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        '${ar.count(f)}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.blueDeep,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
        return Scaffold(
          backgroundColor: AppColors.gray50,
          appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: const Text(
              '📚 프롬프트 보관함',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: AppColors.blueDeep,
              ),
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  folders,
                  const SizedBox(height: 12),
                  if (!ar.loaded)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (list.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.gray200),
                      ),
                      child: Text(
                        _folder == kAllFolder
                            ? '아직 저장된 케이스가 없습니다.\n시뮬레이터 위쪽 [🤖 자동 QA]로 테스트한 뒤 [💾 보관함에 저장]을 누르면 여기에 치료별로 정리됩니다.'
                            : '\'$_folder\' 폴더에 저장된 케이스가 없습니다.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppColors.gray500,
                          height: 1.6,
                        ),
                      ),
                    )
                  else
                    LayoutBuilder(
                      builder: (context, c) {
                        final cols = wide && c.maxWidth >= 1000 ? 2 : 1;
                        final w = (c.maxWidth - (cols - 1) * 12) / cols;
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            for (final k in list)
                              SizedBox(
                                width: w,
                                child: _CaseCard(
                                  c: k,
                                  onCopy: () {
                                    Clipboard.setData(
                                      ClipboardData(text: k.prompt),
                                    );
                                    _toast('프롬프트를 복사했습니다');
                                  },
                                  onApply: () => _applyDefault(k),
                                  onBackup: () => _backup(k),
                                  onImport: () => _import(k),
                                  onDelete: () => _delete(k),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CaseCard extends StatelessWidget {
  const _CaseCard({
    required this.c,
    required this.onCopy,
    required this.onApply,
    required this.onBackup,
    required this.onImport,
    required this.onDelete,
  });
  final ArchiveCase c;
  final VoidCallback onCopy, onApply, onBackup, onDelete, onImport;

  String _date(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}.${two(d.month)}.${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.gray200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    c.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '지우기',
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: AppColors.gray500,
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final f in c.folders)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.blueSoft,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '📁 $f',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.blueDeep,
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.passed
                        ? AppColors.mint.withValues(alpha: 0.14)
                        : const Color(0xFFFFF4E5),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    '${c.passed ? '🎉 ' : ''}${c.badge}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: c.passed
                          ? AppColors.mint
                          : const Color(0xFFB25E00),
                    ),
                  ),
                ),
                Text(
                  _date(c.date),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.gray500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 3종 비교 미리보기 (탭하면 크게)
            Row(
              children: [
                for (final (i, k, label) in [
                  (0, 'original', '① 원본'),
                  (1, 'target', '② 실제 정답지'),
                  (2, 'result', '③ AI 최종 결과'),
                ]) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _Thumb(c: c, kind: k, label: label, index: i),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '엔진: ${c.engine}  ·  권장 적용 강도: ${c.strength}%',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            if (c.timeline.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '점수 기록: ${c.timeline}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.gray500,
                  ),
                ),
              ),
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  '황금 프롬프트 전문 보기',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppColors.blue,
                  ),
                ),
                children: [
                  if (c.request.isNotEmpty) ...[
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '채택된 추가 요청',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.blueDeep,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        c.request,
                        style: const TextStyle(fontSize: 12.5, height: 1.5),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.gray100,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(
                      c.prompt,
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('프롬프트 복사'),
                ),
                FilledButton.icon(
                  onPressed: onApply,
                  icon: const Icon(Icons.push_pin_outlined, size: 18),
                  label: const Text('이 치료의 기본 설정으로 적용'),
                ),
                FilledButton.tonalIcon(
                  onPressed: onImport,
                  icon: const Icon(Icons.input_rounded, size: 18),
                  label: const Text('🖼 메인 화면으로 가져오기'),
                ),
                OutlinedButton.icon(
                  onPressed: onBackup,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('데이터 백업 다운로드'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.c,
    required this.kind,
    required this.label,
    required this.index,
  });
  final ArchiveCase c;
  final String kind, label;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: Material(
            color: const Color(0xFF0D1622),
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => showDialog<void>(
                context: context,
                builder: (_) => _CompareDialog(c: c, start: index),
              ),
              child: FutureBuilder<Uint8List?>(
                future: _load(c, kind),
                builder: (context, s) => s.data == null
                    ? (s.connectionState == ConnectionState.done
                          ? const Center(
                              child: Text(
                                '정답지 없음\n(자체 평가)',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.gray500,
                                ),
                              ),
                            )
                          : const SizedBox.expand())
                    : Image.memory(
                        s.data!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Future<Uint8List?> _load(ArchiveCase c, String kind) async {
  final f = await PromptArchive.instance.imageFile(c.id, kind);
  return await f.exists() ? f.readAsBytes() : null;
}

/// 크게 비교: 3장 나란히(넓은 화면) 또는 넘겨 보기, 손가락으로 확대
class _CompareDialog extends StatefulWidget {
  const _CompareDialog({required this.c, required this.start});
  final ArchiveCase c;
  final int start;
  @override
  State<_CompareDialog> createState() => _CompareDialogState();
}

class _CompareDialogState extends State<_CompareDialog> {
  late final _pc = PageController(initialPage: widget.start);
  static const _kinds = [
    ('original', '① 원본 사진'),
    ('target', '② 실제 정답지'),
    ('result', '③ AI 최종 합격 결과물'),
  ];

  Widget _img(String kind, String label) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      Expanded(
        child: InteractiveViewer(
          maxScale: 6,
          child: FutureBuilder<Uint8List?>(
            future: _load(widget.c, kind),
            builder: (context, s) => s.data == null
                ? (s.connectionState == ConnectionState.done
                      ? const Center(
                          child: Text(
                            '정답지 없이 AI 자체 평가로 채점한 케이스입니다',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : const SizedBox.expand())
                : Image.memory(s.data!, fit: BoxFit.contain),
          ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF0D1622),
      child: Stack(
        children: [
          Positioned.fill(
            top: 48,
            child: wide
                ? Row(
                    children: [
                      for (final (k, l) in _kinds) Expanded(child: _img(k, l)),
                    ],
                  )
                : PageView(
                    controller: _pc,
                    children: [for (final (k, l) in _kinds) _img(k, l)],
                  ),
          ),
          Positioned(
            left: 12,
            top: 8,
            right: 12,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    wide ? widget.c.title : '${widget.c.title} · 옆으로 넘겨 비교',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '닫기',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
