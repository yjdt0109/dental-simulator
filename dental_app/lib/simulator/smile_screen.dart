import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../ai/ai_service.dart';
import '../ai/pipeline.dart' show PipelineError;
import '../ai/smile.dart';
import '../app_theme.dart';
import '../privacy/mouth_finder.dart';
import 'compare_viewer.dart';
import 'sim_models.dart';

/// 😊 미소 미리보기: 환자 미소 사진 올리기 → 입술 사이 치아 영역 → 변환 치아 입히기 → 비교
class SmilePreviewScreen extends StatefulWidget {
  const SmilePreviewScreen({
    super.key,
    required this.photo,
    required this.after,
    required this.afterLabel,
    this.pick,
    this.make,
  });
  final PatientPhoto photo;
  final Uint8List after; // 입힐 변환 결과
  final String afterLabel;

  /// 시험용
  final Future<Uint8List?> Function(ImageSource src)? pick;
  final Future<Uint8List> Function(
    Uint8List smile,
    Uint8List after,
    Object region,
  )?
  make;

  @override
  State<SmilePreviewScreen> createState() => _SmilePreviewScreenState();
}

class _SmilePreviewScreenState extends State<SmilePreviewScreen> {
  PatientPhoto get p => widget.photo;
  bool _making = false;
  String? _msg;
  double _pos = 0.5;

  Future<void> _pick(ImageSource src) async {
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
    final set = p.smileSet, smile = p.smile;
    if (set == null || smile == null || set.union == null) return;
    setState(() {
      _making = true;
      _msg = '😊 미소에 입히는 중… (입 주변만 AI로 바꾸고 입술·얼굴은 그대로 둡니다)';
    });
    try {
      final out = widget.make != null
          ? await widget.make!(smile, widget.after, set.union!)
          : await makeSmile(
              smile: smile,
              after: widget.after,
              region: set.union!,
            );
      if (!mounted) return;
      setState(() {
        p.smileAfter = out;
        p.smileFrom = widget.afterLabel;
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
          '입힐 결과: ${widget.afterLabel}',
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
              label: Text(has ? '사진 바꾸기' : '갤러리에서 고르기'),
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
          onPressed: !has || set.union == null || _making ? null : _make,
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
  await p.smileSet!.prep();
}
