import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../app_theme.dart';
import '../privacy/mouth_finder.dart';
import '../simulator/sim_models.dart' show kShades, shadeById;
import 'tooth_library.dart';

// -----------------------------------------------------------------------------
// 📐 6전치 라이브러리로 만들기 (AI 변환과 따로)
//   사진 위에 6전치 라이브러리를 놓고 → 끌어서 옮기기 · 두 손가락으로 크기 → 폭·길이·곡선·기울기 막대
//   → 입술 안쪽만 보이게(입술 자동 찾기) → [완성]: 합성 사진 (+ 선택: AI 로 조명·질감만 자연스럽게)
// -----------------------------------------------------------------------------

typedef LibraryResult = ({
  Uint8List image,
  bool aiBlend,
  List<Offset>? lips,
  String form,
});

/// 테스트용: 입술 찾기 결과를 바로 넣기 (null 이면 진짜로 찾음)
List<Offset>? Function()? debugLibraryLips;

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.image,
    required this.imageSize,
    this.shade,
  });
  final Uint8List image;
  final Size imageSize;
  final String? shade;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  ui.Image? _img;
  List<Offset>? _lips; // 0~1
  bool _clip = true;
  bool _ai = true;
  bool _busy = false;
  double _preview = 1; // 미리보기 투명도 (원래 치아와 비교)
  late ToothForm _form = kToothForms[3];
  late String _shade = widget.shade ?? 'A1';
  late LibraryPlacement _pl;

  @override
  void initState() {
    super.initState();
    final s = widget.imageSize;
    _pl = LibraryPlacement(
      center: Offset(s.width / 2, s.height * 0.5),
      width: s.width * 0.3,
    );
    decodeImageFromList(widget.image).then((v) {
      if (mounted) setState(() => _img = v);
    });
    _findLips();
  }

  Future<void> _findLips() async {
    final poly = debugLibraryLips != null
        ? debugLibraryLips!()
        : await MouthFinder.lips(widget.image);
    if (!mounted || poly == null || poly.length < 3) {
      if (mounted) setState(() => _clip = false);
      return;
    }
    // 입술 사이에 자동으로 맞춰 놓기: 정중선 = 입 가운데, 폭 = 입 폭의 80%, 윗입술 아래 쪽에
    var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0;
    for (final p in poly) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    final s = widget.imageSize;
    final w = (maxX - minX) * s.width * 0.8;
    final hc = w / 6.472 * 1.618 / _form.wl;
    setState(() {
      _lips = poly;
      _pl = _pl.copyWith(
        center: Offset((minX + maxX) / 2 * s.width, minY * s.height + hc * 0.4),
        width: w,
      );
    });
  }

  Path? _clipPath() {
    final l = _lips;
    if (!_clip || l == null) return null;
    final s = widget.imageSize;
    return Path()..addPolygon([
      for (final p in l) Offset(p.dx * s.width, p.dy * s.height),
    ], true);
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  Color get _shadeColor => shadeById(_shade).tooth;

  /// [완성]: 원본 크기로 합성
  Future<void> _done() async {
    final im = _img;
    if (im == null || _busy) return;
    setState(() => _busy = true);
    try {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImage(im, Offset.zero, Paint());
      paintLibrary(c, _pl, _form, _shadeColor, clip: _clipPath());
      final out = await rec.endRecording().toImage(im.width, im.height);
      final bd = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
      out.dispose();
      final jpg = await compute(
        (a) => img.encodeJpg(
          img.Image.fromBytes(
            width: a.$1,
            height: a.$2,
            bytes: a.$3.buffer,
            numChannels: 4,
          ),
          quality: 93,
        ),
        (im.width, im.height, bd!),
      );
      if (!mounted) return;
      Navigator.pop<LibraryResult>(context, (
        image: jpg,
        aiBlend: _ai,
        lips: _clip ? _lips : null,
        form: _form.name,
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('합성하지 못했습니다 ($e)')));
      }
    }
  }

  Offset? _lastFocal;
  double _startW = 0;

  @override
  Widget build(BuildContext context) {
    final s = widget.imageSize;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final viewer = LayoutBuilder(
      builder: (ctx, box) {
        final k = (box.maxWidth / s.width) < (box.maxHeight / s.height)
            ? box.maxWidth / s.width
            : box.maxHeight / s.height;
        return Center(
          child: SizedBox(
            width: s.width * k,
            height: s.height * k,
            child: GestureDetector(
              onScaleStart: (d) {
                _lastFocal = d.localFocalPoint;
                _startW = _pl.width;
              },
              onScaleUpdate: (d) {
                final last = _lastFocal ?? d.localFocalPoint;
                final dl = (d.localFocalPoint - last) / k;
                _lastFocal = d.localFocalPoint;
                setState(() {
                  _pl = _pl.copyWith(
                    center: _pl.center + dl,
                    width: d.pointerCount > 1
                        ? (_startW * d.scale).clamp(s.width * 0.05, s.width)
                        : null,
                  );
                });
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    widget.image,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                  CustomPaint(
                    painter: _LibOverlay(
                      _pl,
                      _form,
                      _shadeColor,
                      _clipPath(),
                      k,
                      _preview,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    final panel = _panel();
    return Scaffold(
      appBar: AppBar(
        title: const Text('📐 6전치 라이브러리로 만들기'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: _img == null || _busy ? null : _done,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_rounded),
              label: const Text('완성'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: wide
            ? Row(
                children: [
                  Expanded(
                    child: ColoredBox(color: Colors.black, child: viewer),
                  ),
                  SizedBox(width: 340, child: panel),
                ],
              )
            : Column(
                children: [
                  Expanded(
                    child: ColoredBox(color: Colors.black, child: viewer),
                  ),
                  SizedBox(height: 330, child: panel),
                ],
              ),
      ),
    );
  }

  Widget _slider(
    String label,
    double v,
    double min,
    double max,
    ValueChanged<double> on,
    String shown,
  ) => Row(
    children: [
      SizedBox(
        width: 74,
        child: Text(label, style: const TextStyle(fontSize: 13)),
      ),
      Expanded(
        child: Slider(
          value: v.clamp(min, max),
          min: min,
          max: max,
          onChanged: on,
        ),
      ),
      SizedBox(
        width: 46,
        child: Text(shown, style: const TextStyle(fontSize: 12)),
      ),
    ],
  );

  Widget _panel() {
    final s = widget.imageSize;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
      children: [
        const Text(
          '끌어서 옮기기 · 두 손가락으로 크기 · 아래 막대로 미세 조정',
          style: TextStyle(fontSize: 12, color: AppColors.gray500),
        ),
        const SizedBox(height: 8),
        const Text('치아 모양', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in kToothForms)
              Padding(
                padding: EdgeInsets.zero,
                child: InkWell(
                  onTap: () => setState(() => _form = f),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: 104,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _form.id == f.id
                            ? AppColors.blue
                            : AppColors.gray200,
                        width: _form.id == f.id ? 2 : 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 54,
                          child: CustomPaint(
                            size: const Size(96, 54),
                            painter: LibraryThumbPainter(f, _shadeColor),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          f.name,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: _form.id == f.id
                                ? FontWeight.w800
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _form.desc,
          style: const TextStyle(fontSize: 12, color: AppColors.gray500),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          children: [
            for (final sh in kShades)
              ChoiceChip(
                label: Text(sh.id),
                selected: _shade == sh.id,
                onSelected: (_) => setState(() => _shade = sh.id),
              ),
          ],
        ),
        _slider(
          '폭',
          _pl.width / s.width,
          0.05,
          1,
          (v) => setState(() => _pl = _pl.copyWith(width: v * s.width)),
          '${(_pl.width / s.width * 100).round()}%',
        ),
        _slider(
          '길이',
          _pl.length,
          0.6,
          1.5,
          (v) => setState(() => _pl = _pl.copyWith(length: v)),
          '${(_pl.length * 100).round()}%',
        ),
        _slider(
          '스마일 곡선',
          _pl.arc,
          0,
          1,
          (v) => setState(() => _pl = _pl.copyWith(arc: v)),
          '${(_pl.arc * 100).round()}',
        ),
        _slider(
          '기울기',
          _pl.rotation,
          -10,
          10,
          (v) => setState(() => _pl = _pl.copyWith(rotation: v)),
          '${_pl.rotation.toStringAsFixed(1)}°',
        ),
        _slider(
          '미리보기',
          _preview,
          0.2,
          1,
          (v) => setState(() => _preview = v),
          '${(_preview * 100).round()}%',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _clip && _lips != null,
          onChanged: _lips == null ? null : (v) => setState(() => _clip = v),
          title: const Text('입술 안쪽에만 보이게'),
          subtitle: Text(
            _lips == null
                ? '입술을 자동으로 찾지 못했어요 (사진 전체에 보임)'
                : '입술 밖으로 나간 부분은 가려요',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _ai,
          onChanged: (v) => setState(() => _ai = v),
          title: const Text('완성 후 AI 로 자연스럽게'),
          subtitle: const Text('모양·위치는 그대로, 조명·질감·그림자만 사진과 맞춰요 (나노바나나)'),
        ),
      ],
    );
  }
}

class _LibOverlay extends CustomPainter {
  const _LibOverlay(
    this.pl,
    this.form,
    this.shade,
    this.clip,
    this.k,
    this.opacity,
  );
  final LibraryPlacement pl;
  final ToothForm form;
  final Color shade;
  final Path? clip;
  final double k, opacity;

  @override
  void paint(Canvas c, Size s) {
    c.save();
    c.scale(k);
    paintLibrary(c, pl, form, shade, clip: clip, opacity: opacity);
    c.restore();
  }

  @override
  bool shouldRepaint(_LibOverlay o) => true;
}
