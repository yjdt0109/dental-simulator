import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../app_theme.dart';
import '../privacy/mouth_finder.dart';
import '../simulator/sim_models.dart' show kShades, shadeById;
import 'custom_library_store.dart';
import 'tooth_library.dart';

// -----------------------------------------------------------------------------
// 📐 6전치 라이브러리로 만들기 (AI 변환과 따로) — 2026.11.27-l 개선
//   · 한 손가락: 라이브러리(또는 고른 치아) 옮기기 / 두 손가락: 사진 확대·이동 / ＋ − ⤢ 버튼
//   · 보일 치아 고르기(13~23 중 몇 개만), 치아 하나씩 옮기기·폭·길이
//   · 기본 라이브러리 5종(그림) + 📁 내 라이브러리 (실제 치아 PNG · STL 렌더링)
//   · [완성] → 합성 사진 + 치아 윤곽 마스크 (AI 로 다듬어도 이 윤곽 밖으로는 못 나가게)
// -----------------------------------------------------------------------------

typedef LibraryResult = ({
  Uint8List image,
  Uint8List mask, // 치아 윤곽 (흰색 = 라이브러리 치아), PNG 회색조
  bool aiBlend,
  List<Offset>? lips,
  String form,
});

/// 테스트용: 입술 찾기 결과를 바로 넣기 (null 이면 진짜로 찾음)
List<Offset>? Function()? debugLibraryLips;

/// 테스트용: 내 라이브러리로 불러올 파일 (null 이면 갤러리에서 고름)
List<(String, Uint8List)>? debugLibraryImport;

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
  double _preview = 1;
  ToothForm _form = kToothForms[3];
  late String _shade = widget.shade ?? 'A1';
  late LibraryPlacement _pl;
  final Set<int> _teeth = {...kLibOrder6};
  final Map<int, ToothAdj> _adj = {};
  int? _sel; // 조절할 치아 (null = 전체)
  List<String> _customNames = const [];
  CustomLibrary? _custom;

  // 보기 (확대·이동): 화면 = pan + (o0 + 사진 × k) × z
  double _z = 1;
  Offset _pan = Offset.zero;
  Size _vw = Size.zero;
  bool _autoZoomed = false;

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
    _loadNames();
  }

  Future<void> _loadNames() async {
    final n = await CustomLibraryStore.names();
    if (mounted) setState(() => _customNames = n);
  }

  Future<void> _findLips() async {
    final poly = debugLibraryLips != null
        ? debugLibraryLips!()
        : await MouthFinder.lips(widget.image);
    if (!mounted) return;
    if (poly == null || poly.length < 3) {
      setState(() => _clip = false);
      return;
    }
    final b = _bounds(poly);
    final s = widget.imageSize;
    final w = b.width * s.width * 0.8;
    final hc = w / 6.472 * 1.618 / _form.wl;
    setState(() {
      _lips = poly;
      _pl = _pl.copyWith(
        center: Offset(b.center.dx * s.width, b.top * s.height + hc * 0.4),
        width: w,
      );
    });
    _zoomToMouth();
  }

  static Rect _bounds(List<Offset> poly) {
    var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0;
    for (final p in poly) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  // ---- 보기 계산 ----
  double get _k {
    final s = widget.imageSize;
    if (_vw.isEmpty) return 1;
    return math.min(_vw.width / s.width, _vw.height / s.height);
  }

  Offset get _o0 {
    final s = widget.imageSize;
    return Offset(
      (_vw.width - s.width * _k) / 2,
      (_vw.height - s.height * _k) / 2,
    );
  }

  Offset _toImage(Offset screen) => ((screen - _pan) / _z - _o0) / _k;

  void _zoomAt(Offset focal, double z) {
    final ip = _toImage(focal);
    _z = z.clamp(1.0, 10.0);
    _pan = focal - (_o0 + ip * _k) * _z;
  }

  /// 입 주변을 화면의 70% 폭으로 크게
  void _zoomToMouth() {
    final l = _lips;
    if (l == null || _vw.isEmpty || _autoZoomed) return;
    _autoZoomed = true;
    final b = _bounds(l);
    final s = widget.imageSize;
    final mw = b.width * s.width * _k;
    final z = (0.7 * _vw.width / math.max(1, mw)).clamp(1.0, 6.0);
    final mc = Offset(b.center.dx * s.width, b.center.dy * s.height);
    setState(() {
      _z = z;
      _pan = Offset(_vw.width / 2, _vw.height / 2) - (_o0 + mc * _k) * _z;
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

  void _paint(
    Canvas c, {
    bool mask = false,
    int? highlight,
    double opacity = 1,
  }) => paintLibrary(
    c,
    _pl,
    _form,
    _shadeColor,
    clip: _clipPath(),
    teeth: _teeth,
    adj: _adj,
    custom: _custom,
    mask: mask,
    highlight: highlight,
    opacity: opacity,
  );

  Future<Uint8List> _render(int w, int h, bool mask) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    if (mask) {
      c.drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = Colors.black,
      );
    } else {
      c.drawImage(_img!, Offset.zero, Paint());
    }
    _paint(c, mask: mask);
    final out = await rec.endRecording().toImage(w, h);
    final bd = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    out.dispose();
    return compute((a) {
      final im = img.Image.fromBytes(
        width: a.$1,
        height: a.$2,
        bytes: a.$3.buffer,
        numChannels: 4,
      );
      if (!a.$4) return img.encodeJpg(im, quality: 93);
      final g = img.Image(width: a.$1, height: a.$2, numChannels: 1);
      for (final p in im) {
        g.setPixelR(p.x, p.y, p.r);
      }
      return img.encodePng(g);
    }, (w, h, bd!, mask));
  }

  /// [완성]: 원본 크기로 합성 + 치아 윤곽 마스크
  Future<void> _done() async {
    final im = _img;
    if (im == null || _busy) return;
    if (_teeth.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('보일 치아를 하나 이상 골라 주세요')));
      return;
    }
    setState(() => _busy = true);
    try {
      final jpg = await _render(im.width, im.height, false);
      final mask = await _render(im.width, im.height, true);
      if (!mounted) return;
      Navigator.pop<LibraryResult>(context, (
        image: jpg,
        mask: mask,
        aiBlend: _ai,
        lips: _clip ? _lips : null,
        form: _custom?.name ?? _form.name,
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('합성하지 못했습니다 ($e)')));
      }
    }
  }

  // ---- 내 라이브러리 ----
  Future<void> _import() async {
    List<(String, Uint8List)> files;
    if (debugLibraryImport != null) {
      files = debugLibraryImport!;
    } else {
      final picked = await ImagePicker().pickMultiImage(
        requestFullMetadata: false,
      );
      if (picked.isEmpty) return;
      files = [for (final x in picked) (x.name, await x.readAsBytes())];
    }
    if (!mounted) return;
    final ctrl = TextEditingController(
      text: '내 라이브러리 ${_customNames.length + 1}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('라이브러리 이름'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    try {
      final got = await CustomLibraryStore.import(safe, files);
      await _loadNames();
      await _pickCustom(safe);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('📁 \'$safe\' 저장 (치아 ${got.join('·')})')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('불러오지 못했어요: ${e is StateError ? e.message : e}'),
          ),
        );
      }
    }
  }

  Future<void> _pickCustom(String name) async {
    final lib = await CustomLibraryStore.load(name);
    if (!mounted || lib == null) return;
    setState(() => _custom = lib);
  }

  Future<void> _deleteCustom(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('\'$name\' 지울까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await CustomLibraryStore.delete(name);
    if (_custom?.name == name) _custom = null;
    await _loadNames();
  }

  // ---- 끌기 ----
  Offset? _lastFocal;
  double _startZ = 1;
  Offset _startImgPt = Offset.zero;
  bool _twoFinger = false;

  void _onScaleStart(ScaleStartDetails d) {
    _lastFocal = d.localFocalPoint;
    _startZ = _z;
    _startImgPt = _toImage(d.localFocalPoint);
    _twoFinger = d.pointerCount > 1;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount > 1 || _twoFinger) {
      // 두 손가락: 사진 확대·이동
      if (!_twoFinger) {
        _twoFinger = true;
        _startZ = _z;
        _startImgPt = _toImage(d.localFocalPoint);
      }
      setState(() {
        _z = (_startZ * d.scale).clamp(1.0, 10.0);
        _pan = d.localFocalPoint - (_o0 + _startImgPt * _k) * _z;
      });
      _lastFocal = d.localFocalPoint;
      return;
    }
    final last = _lastFocal ?? d.localFocalPoint;
    final dl = (d.localFocalPoint - last) / (_k * _z);
    _lastFocal = d.localFocalPoint;
    setState(() {
      final sel = _sel;
      if (sel == null) {
        _pl = _pl.copyWith(center: _pl.center + dl);
      } else {
        final a = _adj[sel] ?? const ToothAdj();
        _adj[sel] = a.copyWith(dx: a.dx + dl.dx, dy: a.dy + dl.dy);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.imageSize;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final viewer = LayoutBuilder(
      builder: (ctx, box) {
        final vs = Size(box.maxWidth, box.maxHeight);
        if (vs != _vw) {
          _vw = vs;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _zoomToMouth();
          });
        }
        final k = _k, o0 = _o0;
        return ClipRect(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: (_) => _twoFinger = false,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  child: Transform(
                    transform: Matrix4.identity()
                      ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
                      ..scaleByDouble(_z, _z, 1, 1)
                      ..translateByDouble(o0.dx, o0.dy, 0, 1),
                    child: SizedBox(
                      width: s.width * k,
                      height: s.height * k,
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
                              (c) =>
                                  _paint(c, highlight: _sel, opacity: _preview),
                              k,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Column(
                    children: [
                      _zoomBtn(
                        Icons.add,
                        '확대',
                        () => setState(
                          () => _zoomAt(
                            Offset(_vw.width / 2, _vw.height / 2),
                            _z * 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _zoomBtn(
                        Icons.remove,
                        '축소',
                        () => setState(
                          () => _zoomAt(
                            Offset(_vw.width / 2, _vw.height / 2),
                            _z / 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _zoomBtn(
                        Icons.fit_screen_rounded,
                        '사진 전체',
                        () => setState(() {
                          _z = 1;
                          _pan = Offset.zero;
                        }),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_sel == null ? '한 손가락: 전체 옮기기' : '한 손가락: $_sel번만 옮기기'} · 두 손가락: 사진 확대 · ${(_z * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('📐 6전치 라이브러리'),
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
                  SizedBox(width: 360, child: _panel()),
                ],
              )
            : Column(
                children: [
                  Expanded(
                    child: ColoredBox(color: Colors.black, child: viewer),
                  ),
                  SizedBox(height: 340, child: _panel()),
                ],
              ),
      ),
    );
  }

  Widget _zoomBtn(IconData i, String tip, VoidCallback on) => Material(
    color: Colors.white,
    shape: const CircleBorder(),
    elevation: 2,
    child: IconButton(tooltip: tip, onPressed: on, icon: Icon(i)),
  );

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
        width: 78,
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
        width: 48,
        child: Text(shown, style: const TextStyle(fontSize: 12)),
      ),
    ],
  );

  Widget _title(String t) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 6),
    child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800)),
  );

  Widget _libCard({
    required bool on,
    required Widget pic,
    required String name,
    VoidCallback? tap,
    VoidCallback? long,
  }) => InkWell(
    onTap: tap,
    onLongPress: long,
    borderRadius: BorderRadius.circular(10),
    child: Container(
      width: 100,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: on ? AppColors.blue : AppColors.gray200,
          width: on ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          SizedBox(height: 50, child: pic),
          const SizedBox(height: 4),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: on ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _panel() {
    final s = widget.imageSize;
    final sel = _sel;
    final a = sel == null ? null : (_adj[sel] ?? const ToothAdj());
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
      children: [
        _title('라이브러리'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final f in kToothForms)
              _libCard(
                on: _custom == null && _form.id == f.id,
                pic: CustomPaint(
                  size: const Size(92, 50),
                  painter: LibraryThumbPainter(f, _shadeColor),
                ),
                name: f.name,
                tap: () => setState(() {
                  _form = f;
                  _custom = null;
                }),
              ),
            for (final n in _customNames)
              _libCard(
                on: _custom?.name == n,
                pic: const Center(
                  child: Icon(
                    Icons.photo_library_rounded,
                    color: AppColors.blue,
                  ),
                ),
                name: n,
                tap: () => _pickCustom(n),
                long: () => _deleteCustom(n),
              ),
            _libCard(
              on: false,
              pic: const Center(
                child: Icon(
                  Icons.add_photo_alternate_rounded,
                  color: AppColors.blue,
                ),
              ),
              name: '＋ 내 라이브러리',
              tap: _import,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _custom != null
              ? '📁 ${_custom!.name} · 실제 치아 사진 (길게 누르면 지우기)'
              : '${_form.desc} · 실제 치아 사진은 [＋ 내 라이브러리] 로 (배경 투명 PNG)',
          style: const TextStyle(fontSize: 12, color: AppColors.gray500),
        ),
        _title('보일 치아 (눌러서 빼기·넣기)'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in kLibOrder6)
              FilterChip(
                label: Text('$t'),
                selected: _teeth.contains(t),
                onSelected: (v) => setState(() {
                  v ? _teeth.add(t) : _teeth.remove(t);
                  if (!v && _sel == t) _sel = null;
                }),
              ),
          ],
        ),
        _title('조절할 치아'),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              label: const Text('전체'),
              selected: sel == null,
              onSelected: (_) => setState(() => _sel = null),
            ),
            for (final t in kLibOrder6)
              if (_teeth.contains(t))
                ChoiceChip(
                  label: Text('$t'),
                  selected: sel == t,
                  onSelected: (_) => setState(() => _sel = t),
                ),
          ],
        ),
        const SizedBox(height: 4),
        if (sel == null) ...[
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
        ] else ...[
          _slider(
            '$sel번 폭',
            a!.sw,
            0.6,
            1.5,
            (v) => setState(() => _adj[sel] = a.copyWith(sw: v)),
            '${(a.sw * 100).round()}%',
          ),
          _slider(
            '$sel번 길이',
            a.sh,
            0.6,
            1.5,
            (v) => setState(() => _adj[sel] = a.copyWith(sh: v)),
            '${(a.sh * 100).round()}%',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: a.isZero
                  ? null
                  : () => setState(() => _adj.remove(sel)),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: Text('$sel번 원래대로'),
            ),
          ),
        ],
        _slider(
          '미리보기',
          _preview,
          0.2,
          1,
          (v) => setState(() => _preview = v),
          '${(_preview * 100).round()}%',
        ),
        if (_custom == null)
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
          subtitle: const Text(
            '질감·조명·그림자만. 치아 모양·길이는 라이브러리 윤곽 그대로 (윤곽 밖으로 못 나감)',
          ),
        ),
      ],
    );
  }
}

class _LibOverlay extends CustomPainter {
  const _LibOverlay(this.draw, this.k);
  final void Function(Canvas) draw;
  final double k;

  @override
  void paint(Canvas c, Size s) {
    c.save();
    c.scale(k);
    draw(c);
    c.restore();
  }

  @override
  bool shouldRepaint(_LibOverlay o) => true;
}
