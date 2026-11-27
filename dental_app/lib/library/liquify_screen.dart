import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../app_theme.dart';

// -----------------------------------------------------------------------------
// 🖐 밀어서 다듬기 (포토샵 '픽셀 유동화 · 뒤틀기' 처럼)
//   붓으로 문지른 방향으로 사진을 밀어 치아 길이를 늘이거나(절단끝을 아래로)
//   잇몸 쪽으로 밀어 짧게 하고, 경계·모서리를 다듬음.
//   사진 위에 촘촘한 그물(격자)을 씌워 그물 점을 옮기는 방식 → 즉시 보임, 원본 화질 그대로 내보냄.
// -----------------------------------------------------------------------------

/// 그물 (격자 점 위치) — 순수 계산이라 테스트 가능
class WarpMesh {
  WarpMesh(this.width, this.height, {int cols = 64})
    : cols = cols,
      rows = math.max(8, (cols * height / width).round()) {
    pos = Float32List((this.cols + 1) * (rows + 1) * 2);
    reset();
  }
  final double width, height;
  final int cols, rows;
  late Float32List pos; // 지금 위치 (사진 픽셀)

  Offset home(int i, int j) => Offset(width * i / cols, height * j / rows);

  void reset() {
    for (var j = 0; j <= rows; j++) {
      for (var i = 0; i <= cols; i++) {
        final h = home(i, j), k = (j * (cols + 1) + i) * 2;
        pos[k] = h.dx;
        pos[k + 1] = h.dy;
      }
    }
  }

  Float32List snapshot() => Float32List.fromList(pos);
  void restoreFrom(Float32List s) => pos = Float32List.fromList(s);

  /// 밀기: [at] 주변 반지름 [r] 안의 점을 [d] 만큼 (가운데일수록 많이) 옮김
  void push(Offset at, Offset d, double r, {double strength = 1}) {
    final r2 = r * r;
    for (var j = 0; j <= rows; j++) {
      for (var i = 0; i <= cols; i++) {
        final k = (j * (cols + 1) + i) * 2;
        final dx = pos[k] - at.dx, dy = pos[k + 1] - at.dy;
        final q = dx * dx + dy * dy;
        if (q >= r2) continue;
        final t = 1 - q / r2;
        final w = t * t * strength;
        // 가장자리 점은 사진 밖으로 못 나가게 그 변 위에서만
        final edgeX = i == 0 || i == cols, edgeY = j == 0 || j == rows;
        if (!edgeX) pos[k] += d.dx * w;
        if (!edgeY) pos[k + 1] += d.dy * w;
      }
    }
  }

  /// 되돌리기 붓: 주변 점을 원래 자리 쪽으로
  void restore(Offset at, double r, {double strength = 0.25}) {
    final r2 = r * r;
    for (var j = 0; j <= rows; j++) {
      for (var i = 0; i <= cols; i++) {
        final k = (j * (cols + 1) + i) * 2;
        final dx = pos[k] - at.dx, dy = pos[k + 1] - at.dy;
        final q = dx * dx + dy * dy;
        if (q >= r2) continue;
        final t = 1 - q / r2;
        final w = t * t * strength;
        final h = home(i, j);
        pos[k] += (h.dx - pos[k]) * w;
        pos[k + 1] += (h.dy - pos[k + 1]) * w;
      }
    }
  }

  bool get changed {
    for (var j = 0; j <= rows; j++) {
      for (var i = 0; i <= cols; i++) {
        final k = (j * (cols + 1) + i) * 2, h = home(i, j);
        if ((pos[k] - h.dx).abs() > 0.3 || (pos[k + 1] - h.dy).abs() > 0.3)
          return true;
      }
    }
    return false;
  }

  /// 그리기용 삼각형 (위치 = 지금, 텍스처 = 원래 자리)
  ui.Vertices vertices() {
    final tex = Float32List(pos.length);
    for (var j = 0; j <= rows; j++) {
      for (var i = 0; i <= cols; i++) {
        final k = (j * (cols + 1) + i) * 2, h = home(i, j);
        tex[k] = h.dx;
        tex[k + 1] = h.dy;
      }
    }
    final idx = Uint16List(cols * rows * 6);
    var n = 0;
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
        final a = j * (cols + 1) + i, b = a + 1, c = a + cols + 1, d = c + 1;
        idx[n++] = a;
        idx[n++] = b;
        idx[n++] = c;
        idx[n++] = b;
        idx[n++] = d;
        idx[n++] = c;
      }
    }
    return ui.Vertices.raw(
      ui.VertexMode.triangles,
      pos,
      textureCoordinates: tex,
      indices: idx,
    );
  }
}

void paintWarp(Canvas c, ui.Image im, WarpMesh m) {
  c.drawVertices(
    m.vertices(),
    BlendMode.srcOver,
    Paint()
      ..filterQuality = FilterQuality.high
      ..shader = ImageShader(
        im,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.identity().storage,
        filterQuality: FilterQuality.high,
      ),
  );
}

class LiquifyScreen extends StatefulWidget {
  const LiquifyScreen({super.key, required this.image, this.title = ''});
  final Uint8List image;
  final String title;
  @override
  State<LiquifyScreen> createState() => _LiquifyScreenState();
}

enum _Brush { push, restore }

class _LiquifyScreenState extends State<LiquifyScreen> {
  ui.Image? _img;
  WarpMesh? _mesh;
  final List<Float32List> _undo = [];
  _Brush _brush = _Brush.push;
  double _size = 0.06; // 붓 크기 (사진 짧은 변 비율)
  double _strength = 0.8;
  Offset? _cursor; // 화면 좌표
  bool _busy = false;
  int _pointers = 0;
  final _tc = TransformationController();

  @override
  void initState() {
    super.initState();
    decodeImageFromList(widget.image).then((v) {
      if (!mounted) return;
      setState(() {
        _img = v;
        _mesh = WarpMesh(v.width.toDouble(), v.height.toDouble(), cols: 72);
      });
    });
  }

  @override
  void dispose() {
    _img?.dispose();
    _tc.dispose();
    super.dispose();
  }

  double get _radiusPx {
    final im = _img!;
    return math.min(im.width, im.height) * _size;
  }

  Future<void> _done() async {
    final im = _img, m = _mesh;
    if (im == null || m == null || _busy) return;
    if (!m.changed) {
      Navigator.pop(context);
      return;
    }
    setState(() => _busy = true);
    try {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImage(im, Offset.zero, Paint()); // 바탕 (가장자리 빈틈 대비)
      paintWarp(c, im, m);
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
      if (mounted) Navigator.pop(context, jpg);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('저장하지 못했습니다 ($e)')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final im = _img, m = _mesh;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title.isEmpty ? '🖐 밀어서 다듬기' : '🖐 밀어서 다듬기 · ${widget.title}',
        ),
        actions: [
          IconButton(
            tooltip: '한 번 되돌리기',
            onPressed: _undo.isEmpty
                ? null
                : () => setState(() => m!.restoreFrom(_undo.removeLast())),
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: '처음으로',
            onPressed: m == null
                ? null
                : () => setState(() {
                    _undo.add(m.snapshot());
                    m.reset();
                  }),
            icon: const Icon(Icons.restart_alt_rounded),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              onPressed: im == null || _busy ? null : _done,
              icon: const Icon(Icons.check_rounded),
              label: const Text('완성'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: im == null || m == null
                    ? const Center(child: CircularProgressIndicator())
                    : LayoutBuilder(
                        builder: (ctx, box) {
                          final k = math.min(
                            box.maxWidth / im.width,
                            box.maxHeight / im.height,
                          );
                          return InteractiveViewer(
                            transformationController: _tc,
                            panEnabled: false, // 한 손가락 = 붓, 두 손가락 = 확대·이동
                            minScale: 1,
                            maxScale: 8,
                            child: Center(
                              child: SizedBox(
                                width: im.width * k,
                                height: im.height * k,
                                child: Listener(
                                  onPointerDown: (e) {
                                    _pointers++;
                                    if (_pointers == 1) {
                                      _undo.add(m.snapshot());
                                      if (_undo.length > 30) _undo.removeAt(0);
                                    }
                                    setState(() => _cursor = e.localPosition);
                                  },
                                  onPointerUp: (_) => setState(() {
                                    _pointers = math.max(0, _pointers - 1);
                                    _cursor = null;
                                  }),
                                  onPointerCancel: (_) =>
                                      _pointers = math.max(0, _pointers - 1),
                                  onPointerMove: (e) {
                                    if (_pointers != 1 ||
                                        e.kind == PointerDeviceKind.trackpad)
                                      return;
                                    final at = e.localPosition / k;
                                    setState(() {
                                      _cursor = e.localPosition;
                                      if (_brush == _Brush.push) {
                                        m.push(
                                          at - e.localDelta / k,
                                          e.localDelta / k,
                                          _radiusPx,
                                          strength: _strength,
                                        );
                                      } else {
                                        m.restore(at, _radiusPx);
                                      }
                                    });
                                  },
                                  child: CustomPaint(
                                    key: const Key('liquifyCanvas'),
                                    size: Size(im.width * k, im.height * k),
                                    painter: _WarpPainter(
                                      im,
                                      m,
                                      k,
                                      _cursor,
                                      _radiusPx * k,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            _tools(),
          ],
        ),
      ),
    );
  }

  Widget _tools() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_Brush>(
          segments: const [
            ButtonSegment(
              value: _Brush.push,
              label: Text('🖐 밀기'),
              icon: Icon(Icons.open_with_rounded),
            ),
            ButtonSegment(
              value: _Brush.restore,
              label: Text('↺ 원래대로 붓'),
              icon: Icon(Icons.healing_rounded),
            ),
          ],
          selected: {_brush},
          onSelectionChanged: (s) => setState(() => _brush = s.first),
        ),
        Row(
          children: [
            const SizedBox(
              width: 64,
              child: Text('붓 크기', style: TextStyle(fontSize: 13)),
            ),
            Expanded(
              child: Slider(
                value: _size,
                min: 0.015,
                max: 0.2,
                onChanged: (v) => setState(() => _size = v),
              ),
            ),
          ],
        ),
        Row(
          children: [
            const SizedBox(
              width: 64,
              child: Text('세기', style: TextStyle(fontSize: 13)),
            ),
            Expanded(
              child: Slider(
                value: _strength,
                min: 0.2,
                max: 1,
                onChanged: (v) => setState(() => _strength = v),
              ),
            ),
          ],
        ),
        const Text(
          '절단끝을 아래로 밀면 길게, 위(잇몸 쪽)로 밀면 짧게 · 두 손가락으로 확대 · 붓 크기는 치아 반 정도가 좋아요',
          style: TextStyle(fontSize: 12, color: AppColors.gray500),
        ),
      ],
    ),
  );
}

class _WarpPainter extends CustomPainter {
  _WarpPainter(this.im, this.m, this.k, this.cursor, this.r);
  final ui.Image im;
  final WarpMesh m;
  final double k, r;
  final Offset? cursor;

  @override
  void paint(Canvas c, Size s) {
    c.save();
    c.scale(k);
    c.drawImage(im, Offset.zero, Paint());
    paintWarp(c, im, m);
    c.restore();
    final cu = cursor;
    if (cu != null) {
      c.drawCircle(
        cu,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white70,
      );
    }
  }

  @override
  bool shouldRepaint(_WarpPainter o) => true;
}
