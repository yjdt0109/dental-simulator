import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../ai/ai_service.dart';
import '../ai/pipeline.dart' show PipelineError;
import '../ai/smile.dart';
import '../ai/smile_match.dart';
import '../app_theme.dart';
import '../privacy/mouth_finder.dart';
import '../records/record_photo_picker.dart';
import 'compare_viewer.dart';
import 'sim_models.dart';

/// 😊 미소 미리보기: 환자 미소 사진 올리기 → 입술 사이 치아 영역 → 변환 치아 입히기 → 비교
class SmilePreviewScreen extends StatefulWidget {
  const SmilePreviewScreen({
    super.key,
    required this.photo,
    this.after,
    this.afterLabel = '',
    this.pick,
    this.pickRecords,
    this.make,
    this.matcher,
  });
  final PatientPhoto photo;
  final Uint8List? after; // 입힐 변환 결과 (아직 변환 전이면 null → 보철 사진 정밀 매칭만)
  final String afterLabel;

  /// 시험용
  final Future<Uint8List?> Function(ImageSource src)? pick;
  final Future<List<PickedPhoto>?> Function()? pickRecords;
  final Future<Uint8List> Function(
    Uint8List smile,
    Uint8List after,
    Object region,
  )?
  make;

  /// 시험용: 보철 사진 정밀 매칭 체이닝 바꿔 끼우기
  final Future<MatchResult> Function(
    Uint8List smile,
    Uint8List prosth,
    void Function(String) onStep,
  )?
  matcher;

  @override
  State<SmilePreviewScreen> createState() => _SmilePreviewScreenState();
}

class _SmilePreviewScreenState extends State<SmilePreviewScreen> {
  PatientPhoto get p => widget.photo;
  bool _making = false;
  String? _msg;
  double _pos = 0.5;

  // 🦷 보철 사진 정밀 매칭
  Uint8List? _prosth; // 2번: 개구기 보철 사진
  String _prosthLabel = '';
  bool _matching = false;
  String _matchStep = '';
  MatchResult? _match;
  int _show = 3; // 1 정렬 합성 · 2 FLUX 1차 · 3 최종

  Future<void> _pickProsth(ImageSource src) async {
    Uint8List? bytes;
    if (widget.pick != null) {
      bytes = await widget.pick!(src);
    } else {
      final f = await ImagePicker().pickImage(
        source: src,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 92,
      );
      bytes = await f?.readAsBytes();
    }
    if (bytes == null || !mounted) return;
    setState(() {
      _prosth = bytes;
      _prosthLabel = '보철 사진';
      _match = null;
    });
  }

  Future<void> _runMatch() async {
    final smile = p.smile, prosth = _prosth;
    if (smile == null || prosth == null || _matching) return;
    setState(() {
      _matching = true;
      _match = null;
      _matchStep = '시작합니다…';
    });
    void step(String m) {
      if (mounted) setState(() => _matchStep = m);
    }

    try {
      final r = widget.matcher != null
          ? await widget.matcher!(smile, prosth, step)
          : await matchProsthesis(smile: smile, prosth: prosth, onStep: step);
      if (!mounted) return;
      setState(() {
        _match = r;
        _show = 3;
        p.smileAfter = r.finalImage;
        p.smileFrom = '보철 사진 정밀 매칭';
        p.noteSmile();
        _pos = 0.5;
        _matchStep =
            '완성! ${r.align.summary}${r.notes.isEmpty ? '' : '\n${r.notes.join('\n')}'}';
      });
    } on PipelineError catch (e) {
      setState(() => _matchStep = '⚠ ${e.message}');
    } on AiError catch (e) {
      setState(() => _matchStep = '⚠ ${e.message}');
    } catch (e) {
      setState(() => _matchStep = '⚠ 정밀 매칭에 실패했습니다 ($e)');
    } finally {
      if (mounted) setState(() => _matching = false);
    }
  }

  Widget _matchCard() {
    final can =
        p.smile != null &&
        _prosth != null &&
        !_matching &&
        (DentalAligner.supported || widget.matcher != null);
    final m = _match;
    Widget thumb(int n, String label, Uint8List? b) => Expanded(
      child: InkWell(
        onTap: b == null
            ? null
            : () => setState(() {
                _show = n;
                p.smileAfter = b;
              }),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0D1622),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _show == n
                        ? const Color(0xFF00A88F)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: b == null ? null : Image.memory(b, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 11.5)),
          ],
        ),
      ),
    );
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.gray200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '🦷 보철 사진 정밀 매칭 (얼굴 특징점)',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 4),
            const Text(
              '개구기로 찍은 보철 사진(2번)의 치아를 미소 사진(1번)의 입 안쪽에 맞춰 넣어요. '
              '기기 안에서 눈 중심·코끝으로 두 사진을 정렬한 뒤 → FLUX가 빈 곳·경계를 채우고 → 나노바나나가 조명·그림자를 맞춥니다.',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.gray500,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 96,
                  height: 72,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: const Color(0xFF0D1622),
                      child: _prosth == null
                          ? const Center(
                              child: Text(
                                '2번 사진',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          : Image.memory(_prosth!, fit: BoxFit.cover),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      OutlinedButton(
                        onPressed: _matching
                            ? null
                            : () => _pickProsth(ImageSource.gallery),
                        child: const Text('보철 사진 고르기'),
                      ),
                      OutlinedButton(
                        onPressed: _matching
                            ? null
                            : () => _pickProsth(ImageSource.camera),
                        child: const Text('촬영'),
                      ),
                      if (widget.after != null)
                        OutlinedButton(
                          onPressed: _matching
                              ? null
                              : () => setState(() {
                                  _prosth = widget.after;
                                  _prosthLabel = widget.afterLabel;
                                  _match = null;
                                }),
                          child: Text('지금 결과 쓰기 (${widget.afterLabel})'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_prosthLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '2번: $_prosthLabel',
                style: const TextStyle(fontSize: 12, color: AppColors.gray500),
              ),
            ],
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: can ? _runMatch : null,
              icon: _matching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.center_focus_strong_outlined),
              label: const Text('🎯 정밀 매칭 합성 시작'),
            ),
            if (!DentalAligner.supported && widget.matcher == null)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '안드로이드 태블릿에서만 쓸 수 있어요 (얼굴 특징점을 기기 안에서 찾습니다).',
                  style: TextStyle(fontSize: 12, color: AppColors.error),
                ),
              ),
            if (p.smile == null)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '먼저 위에서 1번 미소 사진을 올려 주세요.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            if (_matchStep.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _matchStep,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.blueDeep,
                ),
              ),
            ],
            if (m != null) ...[
              const SizedBox(height: 10),
              const Text(
                '단계별 결과 (눌러서 아래 비교에 쓰기)',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  thumb(1, '① 정렬 합성', m.composite),
                  const SizedBox(width: 6),
                  thumb(2, '② FLUX 1차', m.stage1),
                  const SizedBox(width: 6),
                  thumb(3, '③ 최종', m.finalImage),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pick(ImageSource src) async {
    var list = <Uint8List>[];
    if (widget.pick != null) {
      final b = await widget.pick!(src);
      if (b != null) list = [b];
    } else if (src == ImageSource.gallery) {
      // 여러 장 고르기 → 모두 비교 목록에 (고른 차례대로), 첫 장으로 미소 미리보기
      final fs = await ImagePicker().pickMultiImage(
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 92,
      );
      for (final f in fs) {
        list.add(await f.readAsBytes());
      }
    } else {
      final f = await ImagePicker().pickImage(
        source: src,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 92,
      );
      if (f != null) list = [await f.readAsBytes()];
    }
    if (list.isEmpty || !mounted) return;
    for (var i = 1; i < list.length; i++) {
      final k = p.extras.where((e) => e.sub == '미소 사진').length + 1;
      p.addExtra(list[i], '😊 미소 $k', sub: '미소 사진');
    }
    await _useSmile(list.first);
    if (list.length > 1 && mounted) {
      setState(() => _msg = '${list.length}장을 비교 목록에 넣었어요. 첫 장으로 미소 미리보기를 해요.');
    }
  }

  /// 🗂 환자 기록에서 사진 여러 장 불러오기 → 비교 목록 (누른 차례대로), 첫 미소 사진으로 미리보기
  Future<void> _pickFromRecords() async {
    final got = widget.pickRecords != null
        ? await widget.pickRecords!()
        : await pickRecordPhotos(context, smileFirst: true);
    if (got == null || got.isEmpty || !mounted) return;
    for (final g in got) {
      p.addExtra(g.bytes, g.label, sub: g.sub);
    }
    final first = got.where((g) => g.smile).firstOrNull ?? got.first;
    await _useSmile(first.bytes);
    if (mounted) {
      setState(() => _msg = '환자 기록에서 ${got.length}장을 비교 목록에 넣었어요.');
    }
  }

  Future<void> _useSmile(Uint8List bytes) async {
    await setSmile(p, bytes);
    if (!mounted) return;
    setState(() => _msg = null);
    await _auto(quiet: true);
  }

  Future<void> _auto({bool quiet = false}) async {
    final set = p.smileSet;
    if (set == null) return;
    if (!MouthFinder.supported) {
      if (!quiet)
        setState(() => _msg = '이 기기에서는 자동 찾기를 쓸 수 없어요. 🪄로 치아를 탭해 주세요.');
      return;
    }
    setState(() => set.busy = true);
    final poly = await MouthFinder.lips(set.photo);
    if (!mounted) return;
    if (poly == null) {
      setState(() {
        set.busy = false;
        _msg = '입술을 찾지 못했어요. 🪄로 보이는 치아를 하나씩 탭해 주세요.';
      });
      return;
    }
    await set.setAuto(poly);
    if (!mounted) return;
    setState(() {
      set.busy = false;
      _msg = '입술 사이를 자동으로 골랐어요. 빠진 치아는 🪄로 탭하고, 넘친 곳은 [빼기] 붓으로 지우세요.';
    });
  }

  Future<void> _make() async {
    final set = p.smileSet, smile = p.smile, after = widget.after;
    if (set == null || smile == null || set.union == null || after == null) {
      return;
    }
    setState(() {
      _making = true;
      _msg = '😊 미소에 입히는 중… (입 주변만 AI로 바꾸고 입술·얼굴은 그대로 둡니다)';
    });
    try {
      final out = widget.make != null
          ? await widget.make!(smile, after, set.union!)
          : await makeSmile(smile: smile, after: after, region: set.union!);
      if (!mounted) return;
      setState(() {
        p.smileAfter = out;
        p.smileFrom = widget.afterLabel;
        p.noteSmile();
        _pos = 0.5;
        _msg = '완성! 메인 비교 화면의 [😊 미소 비교]로도 볼 수 있어요.';
      });
    } on PipelineError catch (e) {
      setState(() => _msg = e.message);
    } on AiError catch (e) {
      setState(() => _msg = e.message);
    } catch (e) {
      setState(() => _msg = '미소에 입히지 못했어요. 다시 시도해 주세요. ($e)');
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final set = p.smileSet;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final has = p.smile != null && set != null;
    final editor = !has
        ? _empty()
        : RoiEditor(
            bytes: p.smile!,
            imageSize: p.smileSize,
            roi: kDefaultRoi,
            onChanged: (_) {},
            showRoi: false,
            samOverlay: set.overlay,
            samBusy: set.busy,
            samCount: set.sels.length + (set.auto == null ? 0 : 1),
            onSamTap: _making
                ? null
                : (pt) async {
                    final f = set.tap(pt);
                    setState(() {});
                    final err = await f;
                    if (mounted) setState(() => _msg = err);
                  },
            onSamBrush: (s) async {
              await set.brush(s);
              if (mounted) setState(() {});
            },
            onSamUndo: set.history.isEmpty
                ? null
                : () async {
                    await set.undo();
                    if (mounted) setState(() {});
                  },
            onSamClear: () async {
              await set.clear();
              if (mounted) setState(() {});
            },
          );
    final panel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.after == null
              ? '아직 변환 전이에요 · 보철 사진 정밀 매칭은 아래에서 바로 할 수 있어요'
              : '입힐 결과: ${widget.afterLabel}',
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: AppColors.blueDeep,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _making ? null : () => _pick(ImageSource.camera),
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(has ? '다시 촬영' : '미소 사진 촬영'),
            ),
            OutlinedButton.icon(
              onPressed: _making ? null : () => _pick(ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(has ? '사진 바꾸기 (여러 장)' : '갤러리에서 고르기 (여러 장)'),
            ),
            OutlinedButton.icon(
              onPressed: _making ? null : _pickFromRecords,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('🗂 환자 기록에서'),
            ),
            if (has)
              OutlinedButton.icon(
                onPressed: _making || set.busy ? null : () => _auto(),
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('🪄 입술 사이 자동 찾기'),
              ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
          onPressed:
              !has || set.union == null || _making || widget.after == null
              ? null
              : _make,
          icon: _making
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.sentiment_very_satisfied_outlined),
          label: Text(p.smileAfter == null ? '😊 미소에 입히기' : '😊 다시 입히기'),
        ),
        if (_msg != null) ...[
          const SizedBox(height: 8),
          Text(
            _msg!,
            style: const TextStyle(fontSize: 13, color: AppColors.blueDeep),
          ),
        ],
        const SizedBox(height: 8),
        const Text(
          '미소 사진은 개구기 없이 살짝 웃는 정면 사진이 좋아요. 치아 영역(민트색) 바깥의 입술·얼굴·배경은 원본 그대로 유지됩니다. 미소 사진은 눈을 가리지 않습니다.',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.gray500,
            height: 1.45,
          ),
        ),
      ],
    );
    final result = p.smileAfter == null || p.smile == null
        ? null
        : SizedBox(
            height: wide ? 420 : 300,
            child: SliderCompare(
              before: p.smile!,
              after: p.smileAfter!,
              fit: BoxFit.contain,
              position: _pos,
              onChanged: (v) => setState(() => _pos = v),
              beforeTitle: '미소',
              beforeSub: '치료 전',
              afterTitle: '미소 미리보기',
              afterSub: p.smileFrom,
            ),
          );
    return Scaffold(
      backgroundColor: AppColors.gray50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('😊 미소 미리보기'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (wide)
            SizedBox(
              height: 460,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: editor),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 340,
                    child: SingleChildScrollView(child: panel),
                  ),
                ],
              ),
            )
          else ...[
            SizedBox(height: 360, child: editor),
            const SizedBox(height: 12),
            panel,
          ],
          const SizedBox(height: 14),
          _matchCard(),
          if (result != null) ...[
            const SizedBox(height: 14),
            const Text(
              '결과 비교 (손잡이를 끌어 보세요)',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            result,
          ],
        ],
      ),
    );
  }

  Widget _empty() => ClipRRect(
    borderRadius: BorderRadius.circular(14),
    child: const ColoredBox(
      color: Color(0xFF0D1622),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            '😊 환자의 미소 사진을 올려 주세요\n(개구기 없이 살짝 웃는 사진)',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.6),
          ),
        ),
      ),
    ),
  );
}

/// 미소 사진 등록 (태블릿·PC 공통)
Future<void> setSmile(PatientPhoto p, Uint8List bytes) async {
  final im = await decodeImageFromList(bytes);
  p.smile = bytes;
  p.smileSize = Size(im.width.toDouble(), im.height.toDouble());
  im.dispose();
  p.smileSet = ToothMaskSet(bytes);
  p.smileAfter = null;
  p.smileFrom = '';
  p.noteSmile(); // 왼쪽 비교 목록에도 (불러온 차례대로)
  await p.smileSet!.prep();
}
