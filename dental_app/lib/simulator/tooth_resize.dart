import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../ai/tooth_select.dart' show warpTooth, scaleToothMasked;
import '../app_theme.dart';
import 'resize_session.dart';

/// 치아 하나의 늘린 양 (사진 너비·높이 대비 비율)
class Grow {
  const Grow({this.left = 0, this.right = 0, this.up = 0, this.down = 0});
  final double left, right, up, down;
  bool get isZero => left == 0 && right == 0 && up == 0 && down == 0;
  Grow copy({double? left, double? right, double? up, double? down}) => Grow(
    left: left ?? this.left,
    right: right ?? this.right,
    up: up ?? this.up,
    down: down ?? this.down,
  );
}

typedef ResizeTooth = ({String label, Rect box, bool upper});

/// 모든 치아 늘이기를 차례로 적용 (isolate 에서 실행)
/// 치아 윤곽(마스크)이 있으면 그 치아 픽셀만 키움 (잇몸·옆 치아 그대로), 없으면 주변까지 부드럽게 늘임
img.Image applyGrows(img.Image src, List<(Rect, Grow, img.Image?)> items) {
  var out = src;
  final w = src.width.toDouble(), h = src.height.toDouble();
  for (final (box, g, mask) in items) {
    if (g.isZero) continue;
    final px = Rect.fromLTRB(
      box.left * w,
      box.top * h,
      box.right * w,
      box.bottom * h,
    );
    if (mask != null) {
      out = scaleToothMasked(
        out,
        mask,
        px,
        left: g.left * w,
        right: g.right * w,
        up: g.up * h,
        down: g.down * h,
      );
      continue;
    }
    out = warpTooth(
      out,
      Rect.fromLTRB(box.left * w, box.top * h, box.right * w, box.bottom * h),
      left: g.left * w,
      right: g.right * w,
      up: g.up * h,
      down: g.down * h,
    );
  }
  return out;
}

Uint8List previewGrows((img.Image, List<(Rect, Grow, img.Image?)>) a) =>
    img.encodeJpg(applyGrows(a.$1, a.$2), quality: 85);

Uint8List fullGrows((Uint8List, List<(Rect, Grow, img.Image?)>) a) {
  final src = img.decodeImage(a.$1)!;
  return img.encodeJpg(applyGrows(src, a.$2), quality: 92);
}

img.Image shrinkPreview(Uint8List b) {
  final d = img.decodeImage(b)!;
  final k = 1000 / math.max(d.width, d.height);
  return k < 1
      ? img.copyResize(
          d,
          width: (d.width * k).round(),
          height: (d.height * k).round(),
        )
      : d;
}

/// 🦷 치아 크기 조절: 변환된 사진에서 치아를 탭해 고르고(SAM) 위·아래·좌·우로 조금씩 키움
/// (사진 늘이기 · AI 비용 없음). 무삭제 라미네이트면 잇몸(마진) 쪽 고정, 작아지는 방향은 막음
class ToothResizeScreen extends StatefulWidget {
  const ToothResizeScreen({
    super.key,
    required this.image,
    required this.imageSize,
    required this.teeth,
    this.noPrep = false,
    this.falKey,
    this.chartTeeth = const [],
    this.masks = const [],
  });
  final List<img.Image?> masks; // teeth 와 같은 순서의 치아 윤곽 (SAM)
  final Uint8List image;
  final Size imageSize;
  final List<ResizeTooth> teeth; // 원본에서 🪄로 고른 치아 (없어도 됨)
  final bool noPrep;
  final String? falKey;
  final List<int> chartTeeth;

  @override
  State<ToothResizeScreen> createState() => _ToothResizeScreenState();
}

class _ToothResizeScreenState extends State<ToothResizeScreen> {
  late final ResizeSession _rs = ResizeSession(
    image: widget.image,
    noPrep: widget.noPrep,
    teeth: widget.teeth,
    chartTeeth: widget.chartTeeth,
    masks: widget.masks,
  );
  Uint8List? _shown;
  Timer? _debounce;
  bool _saving = false;
  GrowSide? _drag;
  bool _panning = false;
  Rect _dest = Rect.zero;
  double _zoom = 1; // 🔍 확대 배율
  Offset _focus = const Offset(0.5, 0.5); // 화면 가운데에 올 사진 위치 (0~1)

  Offset _toImg(Offset local) => Offset(
    (local.dx - _dest.left) / _dest.width,
    (local.dy - _dest.top) / _dest.height,
  );

  void _zoomBy(double k) => setState(() {
    _zoom = (_zoom * k).clamp(1.0, 6.0);
    if (_zoom == 1) _focus = const Offset(0.5, 0.5);
    // 고른 치아가 있으면 그 치아 쪽으로 확대
    if (k > 1 && _rs.teeth.isNotEmpty && _zoom <= 2.0) {
      _focus = _rs.teeth[_rs.sel].box.center;
    }
  });
  String? _msg;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _refresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 90), () async {
      final out = _rs.changed ? await _rs.preview() : null;
      if (mounted) setState(() => _shown = out);
    });
  }

  void _step(GrowSide s, int dir) {
    if (_rs.stepTooth(_rs.sel, s, dir)) {
      setState(() {});
      _refresh();
    }
  }

  Future<void> _apply() async {
    if (!_rs.changed) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    final out = await _rs.apply();
    if (mounted) Navigator.of(context).pop(out);
  }

  Rect _newBox(int i) {
    final b = _rs.teeth[i].box, g = _rs.grows[i];
    return Rect.fromLTRB(
      b.left - g.left,
      b.top - g.up,
      b.right + g.right,
      b.bottom + g.down,
    );
  }

  Offset _toScreen(Offset o) =>
      Offset(_dest.left + o.dx * _dest.width, _dest.top + o.dy * _dest.height);

  Map<GrowSide, Offset> _handles(int i) {
    final r = _newBox(i);
    return {
      GrowSide.left: _toScreen(Offset(r.left, r.center.dy)),
      GrowSide.right: _toScreen(Offset(r.right, r.center.dy)),
      GrowSide.up: _toScreen(Offset(r.center.dx, r.top)),
      GrowSide.down: _toScreen(Offset(r.center.dx, r.bottom)),
    };
  }

  /// 끌기 시작: 손잡이면 크기 조절, 아니면 (확대 중) 사진 이동
  void _onPanStart(Offset local) {
    _drag = null;
    _panning = false;
    if (_rs.teeth.isNotEmpty) {
      for (final e in _handles(_rs.sel).entries) {
        if (widget.noPrep && _rs.isMargin(_rs.sel, e.key)) continue;
        if ((e.value - local).distance < 26) {
          _drag = e.key;
          return;
        }
      }
    }
    _panning = _zoom > 1;
  }

  /// ➖ 길게 누르기: 같이 잡힌 옆 치아 빼기
  Future<void> _onLongPress(Offset local) async {
    if (!_dest.contains(local) || _rs.busy) return;
    final f = _rs.negTap(_toImg(local), falKey: widget.falKey);
    setState(() => _msg = '➖ 그 부분을 빼고 다시 찾는 중…');
    final err = await f;
    if (!mounted) return;
    setState(() => _msg = err ?? '${_rs.teeth[_rs.sel].label} 을(를) 다시 찾았습니다');
    _refresh();
  }

  /// 탭: 고른 치아면 선택, 아니면 🪄 SAM 으로 새 치아
  Future<void> _onDown(Offset local) async {
    if (!_dest.contains(local) || _rs.busy) return;
    final p = _toImg(local);
    setState(() => _msg = null);
    final n = _rs.teeth.length;
    final f = _rs.tap(p, falKey: widget.falKey);
    setState(() {}); // 찾는 중 표시
    final err = await f;
    if (!mounted) return;
    setState(
      () => _msg =
          err ??
          (_rs.teeth.length > n
              ? '${_rs.teeth[_rs.sel].label} 을(를) 골랐습니다'
              : null),
    );
  }

  void _onMove(Offset delta) {
    if (_panning) {
      setState(() {
        _focus = Offset(
          (_focus.dx - delta.dx / _dest.width).clamp(0.0, 1.0),
          (_focus.dy - delta.dy / _dest.height).clamp(0.0, 1.0),
        );
      });
      return;
    }
    final s = _drag;
    if (s == null) return;
    final dx = delta.dx / _dest.width, dy = delta.dy / _dest.height;
    final g = _rs.grows[_rs.sel];
    final v = switch (s) {
      GrowSide.left => g.left - dx,
      GrowSide.right => g.right + dx,
      GrowSide.up => g.up - dy,
      GrowSide.down => g.down + dy,
    };
    if (_rs.setGrow(_rs.sel, s, v)) {
      setState(() {});
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final teeth = _rs.teeth;
    final sel = _rs.sel;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final viewer = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: const Color(0xFF0D1622),
        child: LayoutBuilder(
          builder: (context, c) {
            final fitted = applyBoxFit(
              BoxFit.contain,
              widget.imageSize,
              c.biggest,
            ).destination;
            final base = Alignment.center.inscribe(
              fitted,
              Offset.zero & c.biggest,
            );
            // 🔍 확대: 사진을 _zoom 배로 키우고 _focus 가 화면 가운데에 오게 (빈 곳이 안 보이게 맞춤)
            final zw = base.width * _zoom, zh = base.height * _zoom;
            double place(double box, double len, double focus, double off) {
              if (len <= box) return off;
              return (box / 2 - focus * len).clamp(box - len, 0.0);
            }

            _dest = Rect.fromLTWH(
              _zoom == 1
                  ? base.left
                  : place(c.maxWidth, zw, _focus.dx, base.left),
              _zoom == 1
                  ? base.top
                  : place(c.maxHeight, zh, _focus.dy, base.top),
              zw,
              zh,
            );
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _onDown(d.localPosition),
              onLongPressStart: (d) => _onLongPress(d.localPosition),
              onPanStart: (d) => _onPanStart(d.localPosition),
              onPanUpdate: (d) => _onMove(d.delta),
              onPanEnd: (_) {
                _drag = null;
                _panning = false;
              },
              onPanCancel: () {
                _drag = null;
                _panning = false;
              },
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: _dest,
                    child: Image.memory(
                      _shown ?? widget.image,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                  ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _BoxPainter(
                        boxes: [
                          for (var i = 0; i < teeth.length; i++)
                            Rect.fromPoints(
                              _toScreen(_newBox(i).topLeft),
                              _toScreen(_newBox(i).bottomRight),
                            ),
                        ],
                        labels: [for (final t in teeth) t.label],
                        sel: sel,
                        handles: teeth.isEmpty
                            ? const {}
                            : {
                                for (final e in _handles(sel).entries)
                                  if (!(widget.noPrep &&
                                      _rs.isMargin(sel, e.key)))
                                    e.key.index: e.value,
                              },
                      ),
                    ),
                  ),
                  Positioned(
                    right: 10,
                    top: 10,
                    child: Column(
                      children: [
                        for (final (icon, tip, k) in [
                          (Icons.add, '확대', 1.5),
                          (Icons.remove, '축소', 1 / 1.5),
                          (Icons.fit_screen, '전체 보기', 0.0),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Material(
                              color: Colors.white.withValues(alpha: 0.95),
                              shape: const CircleBorder(),
                              elevation: 3,
                              child: IconButton(
                                tooltip: tip,
                                onPressed: k == 0
                                    ? (_zoom == 1
                                          ? null
                                          : () => setState(() {
                                              _zoom = 1;
                                              _focus = const Offset(0.5, 0.5);
                                            }))
                                    : (k > 1 && _zoom >= 6) ||
                                          (k < 1 && _zoom <= 1)
                                    ? null
                                    : () => _zoomBy(k),
                                icon: Icon(icon, color: AppColors.ink),
                              ),
                            ),
                          ),
                        if (_zoom > 1)
                          Text(
                            '${_zoom.toStringAsFixed(1)}배',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              shadows: [Shadow(blurRadius: 3)],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_rs.busy)
                    const Positioned(
                      top: 12,
                      left: 0,
                      right: 0,
                      child: Center(child: Chip(label: Text('🪄 치아 윤곽 찾는 중…'))),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    Widget row(GrowSide s, String name, IconData icon) {
      final locked = widget.noPrep && _rs.isMargin(sel, s);
      final pct = _rs.pct(sel, s);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.blue),
            const SizedBox(width: 6),
            SizedBox(
              width: 64,
              child: Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton.outlined(
              tooltip: '$name 줄이기',
              onPressed: locked || pct <= 0 ? null : () => _step(s, -1),
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 64,
              child: Text(
                locked ? '고정' : '${pct > 0 ? '+' : ''}$pct%',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            IconButton.outlined(
              tooltip: '$name 키우기',
              onPressed: locked ? null : () => _step(s, 1),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      );
    }

    final panel = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _msg ??
              (teeth.isEmpty
                  ? '🪄 사진에서 크기를 바꿀 치아를 탭하세요 (🔍로 확대하면 더 정확해요)'
                  : '다른 치아를 탭하면 추가 · 옆 치아가 같이 잡히면 그 부분을 길게 누르면 빠져요'),
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.blueDeep,
          ),
        ),
        const SizedBox(height: 8),
        if (teeth.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < teeth.length; i++)
                ChoiceChip(
                  label: Text(
                    '${teeth[i].label}${_rs.grows[i].isZero ? '' : ' ●'}',
                  ),
                  selected: sel == i,
                  onSelected: (_) => setState(() => _rs.sel = i),
                ),
            ],
          ),
          const SizedBox(height: 10),
          row(GrowSide.up, '위', Icons.north),
          row(GrowSide.down, '아래', Icons.south),
          row(GrowSide.left, '왼쪽', Icons.west),
          row(GrowSide.right, '오른쪽', Icons.east),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: _rs.grows[sel].isZero
                    ? null
                    : () {
                        setState(() => _rs.grows[sel] = const Grow());
                        _refresh();
                      },
                child: Text('${teeth[sel].label} 되돌리기'),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _rs.removeTooth(sel));
                  _refresh();
                },
                child: Text('${teeth[sel].label} 빼기'),
              ),
            ],
          ),
        ],
        Text(
          widget.noPrep ? '무삭제 라미네이트: 잇몸(마진) 쪽은 고정되고, 원본보다 작아지지 않게 키우기만 됩니다.' : '사진의 손잡이(●)를 끌거나 ± 버튼으로 3%씩 키우세요. 고른 치아 윤곽만 커지고 잇몸·옆 치아는 그대로예요.',
          style: const TextStyle(fontSize: 12, color: AppColors.gray500),
        ),
      ],
    );
    return Scaffold(
      backgroundColor: AppColors.gray50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('🦷 치아 크기 조절'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
              onPressed: _saving ? null : _apply,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_rounded),
              label: const Text('적용'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: viewer),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 340,
                    child: SingleChildScrollView(child: panel),
                  ),
                ],
              )
            : Column(
                children: [
                  Expanded(child: viewer),
                  const SizedBox(height: 10),
                  Flexible(child: SingleChildScrollView(child: panel)),
                ],
              ),
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter({
    required this.boxes,
    required this.labels,
    required this.sel,
    required this.handles,
  });
  final List<Rect> boxes;
  final List<String> labels;
  final int sel;
  final Map<int, Offset> handles;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < boxes.length; i++) {
      final on = i == sel;
      canvas.drawRect(
        boxes[i],
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = on ? 2 : 1
          ..color = on ? const Color(0xFF00E0B8) : const Color(0x88FFFFFF),
      );
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: TextStyle(
            color: on ? const Color(0xFF00E0B8) : Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            shadows: const [Shadow(blurRadius: 3)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, boxes[i].topLeft - Offset(0, tp.height + 2));
    }
    for (final h in handles.values) {
      canvas.drawCircle(h, 10, Paint()..color = const Color(0xAA000000));
      canvas.drawCircle(h, 8, Paint()..color = const Color(0xFF00E0B8));
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) => true;
}
