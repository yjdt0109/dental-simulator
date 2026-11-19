import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';
import 'line_tools.dart';
import 'sim_models.dart' show GuideLine, MaskStroke;

const _stageColor = Color(0xFF0D1622);
const _beforeColor = Color(0xFF4E5D73);

/// BEFORE / AFTER 라벨
class PhotoBadge extends StatelessWidget {
  const PhotoBadge({
    super.key,
    required this.title,
    required this.sub,
    required this.color,
    this.alignEnd = false,
    this.big = false,
  });
  final String title;
  final String sub;
  final Color color;
  final bool alignEnd;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: alignEnd
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: Colors.white,
              fontSize: big ? 24 : 18,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
              height: 1.2,
            ),
          ),
          Text(
            sub,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: big ? 14 : 12,
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 1) 영역 지정: Before 사진 위 점선 치아 영역 (끌어서 이동, 모서리로 크기 조절)
// -----------------------------------------------------------------------------
class RoiEditor extends StatefulWidget {
  const RoiEditor({
    super.key,
    required this.bytes,
    required this.imageSize,
    required this.roi,
    required this.onChanged,
    this.lines = const [],
    this.onLineAdd,
    this.onLineErase,
    this.onLineUndo,
    this.onLineClear,
    this.onLineSmooth,
    this.showRoi = true,
    this.showIncisal = false,
    this.samOverlay,
    this.onSamTap,
    this.samBusy = false,
    this.samCount = 0,
    this.onSamUndo,
    this.onSamClear,
    this.onSamBrush,
    this.samMarks = const [],
    this.onSamMark,
  });

  /// 🪄 원클릭 치아 자동 선택 (SAM): 사진 위 하이라이트 · 탭 · 손 다듬기 · 기준점
  final Uint8List? samOverlay;
  final ValueChanged<Offset>? onSamTap; // null 이면 SAM 도구 숨김
  final bool samBusy;
  final int samCount;
  final VoidCallback? onSamUndo;
  final VoidCallback? onSamClear;
  final ValueChanged<MaskStroke>? onSamBrush;
  final List<({String label, Offset zenith, Offset incisal})> samMarks;
  final void Function(int index, bool incisal, Offset p)? onSamMark;

  /// 무삭제 라미네이트: [절단선] 펜 보이기
  final bool showIncisal;

  /// 서비컬 라인 편집 (onLineAdd 가 null 이면 그리기 꺼짐)
  final ValueChanged<GuideLine>? onLineAdd;

  /// 지우개: 지나간 길 + 반지름(사진 가로 기준 비율)
  final void Function(List<Offset> path, double r)? onLineErase;
  final VoidCallback? onLineUndo; // null 이면 되돌릴 것 없음
  final VoidCallback? onLineClear;
  final VoidCallback? onLineSmooth;

  /// false: 점선 영역 없이 사진만 (AI 프롬프트 방식)
  final bool showRoi;
  final Uint8List bytes;
  final Size imageSize;
  final Rect roi; // 0~1 비율
  final ValueChanged<Rect> onChanged;

  final List<GuideLine> lines;

  @override
  State<RoiEditor> createState() => _RoiEditorState();
}

/// 확대(두 손가락·마우스 휠·+/− 버튼)와 이동(빈 곳 끌기)을 지원
class _RoiEditorState extends State<RoiEditor> {
  static const _maxZoom = 5.0;
  static const _minZoom = 0.5; // 축소: 사진 전체를 작게 볼 때
  double _s = 1; // 배율
  Offset _o = Offset.zero; // 화면 이동량
  Size _box = Size.zero;
  Rect _dest = Rect.zero; // 1배일 때 사진 위치

  double _startS = 1;
  Offset _startO = Offset.zero, _startF = Offset.zero;

  _Tool _tool = _Tool.upper;
  GuideLine? _live; // 그리는 중인 선
  List<Offset>? _erasing; // 지우개가 지나간 길
  static const _eraserPx = 14.0; // 화면에서 지우개 반지름 (확대하면 더 세밀하게)
  bool _zooming = false;

  bool get _drawOn => widget.onLineAdd != null;
  double get _aspect => widget.imageSize.height / widget.imageSize.width;
  double get _eraserR => _eraserPx / _zoomed.width;
  static const _lineTools = {
    _Tool.upper,
    _Tool.lower,
    _Tool.eraser,
    _Tool.incisal,
  };
  static const _samTools = {
    _Tool.sam,
    _Tool.samAdd,
    _Tool.samErase,
    _Tool.mark,
  };
  bool get _samOn => widget.onSamTap != null;
  bool get _painting =>
      (_drawOn && _lineTools.contains(_tool)) ||
      (_samOn && _samTools.contains(_tool));
  Offset? _samDown; // 자동 선택 탭 위치
  MaskStroke? _stroke; // 손으로 더하기/빼기 중인 획
  (int, bool)? _markDrag; // 옮기는 중인 기준점 (치아 번호, 절단끝?)
  static const _brushPx = 12.0;

  Offset _toImage(Offset local) {
    final z = _zoomed;
    return Offset(
      ((local.dx - z.left) / z.width).clamp(0.0, 1.0),
      ((local.dy - z.top) / z.height).clamp(0.0, 1.0),
    );
  }

  @override
  void didUpdateWidget(RoiEditor old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) {
      _s = 1;
      _o = Offset.zero;
    }
    if (old.onLineAdd == null && widget.onLineAdd != null) {
      _tool = _Tool.upper; // 체크하면 바로 상악선 그리기
    }
    if (!widget.showIncisal && _tool == _Tool.incisal) _tool = _Tool.upper;
    if (!_samOn && _samTools.contains(_tool)) _tool = _Tool.upper;
  }

  Rect get _zoomed => Rect.fromLTWH(
    _o.dx + _dest.left * _s,
    _o.dy + _dest.top * _s,
    _dest.width * _s,
    _dest.height * _s,
  );

  /// 사진이 화면 밖으로 너무 나가지 않게
  Offset _clamp(Offset o, double s) {
    double axis(double o, double start, double len, double box) {
      final l = len * s;
      if (l <= box) return (box - l) / 2 - start * s;
      return o.clamp(box - l - start * s, -start * s);
    }

    return Offset(
      axis(o.dx, _dest.left, _dest.width, _box.width),
      axis(o.dy, _dest.top, _dest.height, _box.height),
    );
  }

  void _zoomAt(Offset f, double ns) {
    ns = ns.clamp(_minZoom, _maxZoom);
    setState(() {
      _o = _clamp(f - (f - _o) * (ns / _s), ns);
      _s = ns;
    });
  }

  /// 치아 영역이 화면 가운데 오도록 확대/축소
  void _zoomBtn(double factor) {
    final ns = (_s * factor).clamp(_minZoom, _maxZoom);
    // 사진 좌표계(1배 기준)에서 치아 영역 중심
    final c = Offset(
      _dest.left + widget.roi.center.dx * _dest.width,
      _dest.top + widget.roi.center.dy * _dest.height,
    );
    setState(() {
      _o = _clamp(_box.center(Offset.zero) - c * ns, ns);
      _s = ns;
    });
  }

  Widget _toolBar() {
    final compact = _box.height < 460; // 휴대폰 등 사진 칸이 낮을 때는 아이콘만
    Widget btn(
      IconData icon,
      String label,
      bool on,
      VoidCallback? tap, {
      Color? color,
    }) {
      final fg = on
          ? Colors.white
          : (tap == null ? AppColors.gray200 : (color ?? AppColors.ink));
      return Tooltip(
        message: label,
        child: InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            width: compact ? 40 : 58,
            padding: EdgeInsets.symmetric(vertical: compact ? 7 : 6),
            decoration: BoxDecoration(
              color: on ? (color ?? AppColors.blue) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Icon(icon, size: 20, color: fg),
                if (!compact) ...[
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final has = widget.lines.isNotEmpty;
    const purple = Color(0xFF7B4DFF);
    return Material(
      color: Colors.white.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showRoi)
              btn(
                Icons.crop_free,
                '영역',
                _tool == _Tool.roi,
                () => setState(() => _tool = _Tool.roi),
              ),
            btn(
              Icons.gesture,
              '상악선',
              _tool == _Tool.upper,
              () => setState(() => _tool = _Tool.upper),
              color: _upperColor,
            ),
            btn(
              Icons.gesture,
              '하악선',
              _tool == _Tool.lower,
              () => setState(() => _tool = _Tool.lower),
              color: _lowerColor,
            ),
            if (widget.showIncisal)
              btn(
                Icons.horizontal_rule_rounded,
                '절단선',
                _tool == _Tool.incisal,
                () => setState(() => _tool = _Tool.incisal),
                color: _incisalColor,
              ),
            btn(
              Icons.cleaning_services_outlined,
              '지우개',
              _tool == _Tool.eraser,
              has || _tool == _Tool.eraser
                  ? () => setState(() => _tool = _Tool.eraser)
                  : null,
              color: AppColors.ink,
            ),
            btn(
              Icons.auto_fix_high,
              '선 다듬기',
              false,
              has ? widget.onLineSmooth : null,
              color: purple,
            ),
            btn(Icons.undo, '되돌리기', false, widget.onLineUndo),
            btn(
              Icons.delete_outline,
              '모두 지움',
              false,
              has ? widget.onLineClear : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 📍 가장 가까운 기준점 (화면 28px 안)
  (int, bool)? _nearestMark(Offset local) {
    final z = _zoomed;
    (int, bool)? best;
    var bd = 28.0;
    for (var i = 0; i < widget.samMarks.length; i++) {
      final m = widget.samMarks[i];
      for (final (inc, o) in [(false, m.zenith), (true, m.incisal)]) {
        final d =
            (Offset(z.left + o.dx * z.width, z.top + o.dy * z.height) - local)
                .distance;
        if (d < bd) {
          bd = d;
          best = (i, inc);
        }
      }
    }
    return best;
  }

  /// 🪄 자동 선택 도구 모음 (사진 아래쪽)
  Widget _samBar() {
    final compact = _box.width < 560;
    const mint = Color(0xFF00A88F);
    Widget btn(
      IconData icon,
      String label,
      String tip,
      bool on,
      VoidCallback? tap, {
      Color color = mint,
    }) {
      final fg = on ? Colors.white : (tap == null ? AppColors.gray200 : color);
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 10,
              vertical: 7,
            ),
            decoration: BoxDecoration(
              color: on ? color : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 19, color: fg),
                if (!compact) ...[
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final has = widget.samCount > 0;
    return Material(
      color: Colors.white.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              btn(
                Icons.auto_fix_high,
                '🪄 탭 한 번 자동 선택',
                '🪄 탭 한 번 자동 선택 (SAM) — 치아를 탭하면 윤곽을 자동으로 찾아요 (다시 탭하면 빠짐)',
                _tool == _Tool.sam,
                () => setState(() => _tool = _Tool.sam),
              ),
              btn(
                Icons.brush_outlined,
                '더하기',
                '선택 다듬기: 손으로 칠해 선택 영역 더하기',
                _tool == _Tool.samAdd,
                () => setState(() => _tool = _Tool.samAdd),
              ),
              btn(
                Icons.cleaning_services_outlined,
                '빼기',
                '선택 다듬기: 손으로 문질러 선택 영역 빼기',
                _tool == _Tool.samErase,
                has ? () => setState(() => _tool = _Tool.samErase) : null,
                color: AppColors.error,
              ),
              btn(
                Icons.place_outlined,
                '기준점',
                '📍 치아별 기준점(잇몸 꼭대기·절단끝) 옮기기',
                _tool == _Tool.mark,
                widget.samMarks.isEmpty
                    ? null
                    : () => setState(() => _tool = _Tool.mark),
                color: AppColors.blue,
              ),
              btn(
                Icons.undo,
                '선택 취소',
                '마지막 선택 취소',
                false,
                widget.onSamUndo,
                color: AppColors.ink,
              ),
              btn(
                Icons.delete_outline,
                '선택 초기화',
                '선택 초기화',
                false,
                has ? widget.onSamClear : null,
                color: AppColors.ink,
              ),
              if (has)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '치아 ${widget.samCount}개',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: mint,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _zoomButton(IconData icon, String tip, VoidCallback? onTap) =>
      Material(
        color: Colors.white.withValues(alpha: 0.95),
        shape: const CircleBorder(),
        elevation: 3,
        child: IconButton(
          tooltip: tip,
          onPressed: onTap,
          icon: Icon(icon, size: 22, color: AppColors.ink),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: _stageColor,
        child: LayoutBuilder(
          builder: (context, c) {
            final box = Offset.zero & c.biggest;
            final fitted = applyBoxFit(
              BoxFit.contain,
              widget.imageSize,
              c.biggest,
            ).destination;
            _dest = Alignment.center.inscribe(fitted, box);
            if (_box != c.biggest) {
              _box = c.biggest;
              _o = _clamp(_o, _s);
            }
            final z = _zoomed;
            return Listener(
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) {
                  _zoomAt(
                    e.localPosition,
                    _s * math.exp(-e.scrollDelta.dy / 400),
                  );
                }
              },
              child: Stack(
                children: [
                  // 빈 곳: 끌어서 이동, 두 손가락으로 확대
                  Positioned.fill(
                    child: _ScaleArea(
                      // 선 그리기 중: 손을 대자마자 이 영역이 터치를 차지 → 화면이 위아래로 스크롤되지 않음
                      eager: _painting,
                      onScaleStart: (d) {
                        _startS = _s;
                        _startO = _o;
                        _startF = d.localFocalPoint;
                        _zooming = d.pointerCount > 1;
                        if (_painting && !_zooming) {
                          final ip = _toImage(d.localFocalPoint);
                          setState(() {
                            if (_tool == _Tool.sam) {
                              _samDown = ip;
                            } else if (_tool == _Tool.samAdd ||
                                _tool == _Tool.samErase) {
                              _stroke = MaskStroke(
                                r: _brushPx / _zoomed.width,
                                erase: _tool == _Tool.samErase,
                                pts: [ip],
                              );
                            } else if (_tool == _Tool.mark) {
                              _markDrag = _nearestMark(d.localFocalPoint);
                            } else if (_tool == _Tool.eraser) {
                              _erasing = [_toImage(d.localFocalPoint)];
                            } else {
                              _live = GuideLine(
                                upper: _tool != _Tool.lower,
                                incisal: _tool == _Tool.incisal,
                                pts: [_toImage(d.localFocalPoint)],
                              );
                            }
                          });
                        }
                      },
                      onScaleEnd: (_) {
                        final l = _live, er = _erasing;
                        final tap = _samDown, st = _stroke;
                        _live = null;
                        _erasing = null;
                        _samDown = null;
                        _stroke = null;
                        _markDrag = null;
                        if (tap != null && !_zooming)
                          widget.onSamTap?.call(tap);
                        if (st != null) widget.onSamBrush?.call(st);
                        if (l != null && l.pts.length > 1) {
                          widget.onLineAdd?.call(l);
                        } else if (er != null) {
                          widget.onLineErase?.call(er, _eraserR);
                        }
                        setState(() {});
                      },
                      onScaleUpdate: (d) {
                        if (d.pointerCount > 1 && !_zooming) {
                          // 칠하다가 두 번째 손가락 → 확대로 전환 (칠한 획은 취소)
                          _zooming = true;
                          _live = null;
                          _erasing = null;
                          _samDown = null;
                          _stroke = null;
                          _markDrag = null;
                          _startS = _s;
                          _startO = _o;
                          _startF = d.localFocalPoint;
                          return;
                        }
                        if (_painting && !_zooming) {
                          final p = _toImage(d.localFocalPoint);
                          final md = _markDrag;
                          if (md != null) {
                            widget.onSamMark?.call(md.$1, md.$2, p);
                            return;
                          }
                          setState(() {
                            _live?.pts.add(p);
                            _erasing?.add(p);
                            _stroke?.pts.add(p);
                          });
                          return;
                        }
                        final ns = (_startS * d.scale).clamp(
                          _minZoom,
                          _maxZoom,
                        );
                        setState(() {
                          _o = _clamp(
                            d.localFocalPoint -
                                (_startF - _startO) * (ns / _startS),
                            ns,
                          );
                          _s = ns;
                        });
                      },
                      onDoubleTapDown: _painting
                          ? null
                          : (d) => _startF = d.localPosition,
                      onDoubleTap: _painting
                          ? null
                          : () => _zoomAt(
                              _startF,
                              (_s - 1).abs() > 0.05 ? 1 : 2.5,
                            ),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: z,
                    child: IgnorePointer(
                      child: Image.memory(
                        widget.bytes,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                      ),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: z,
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _LinePainter(
                          // 지우는 중에는 지운 결과를 미리 보여 줌
                          [
                            ...(_erasing == null
                                ? widget.lines
                                : LineTools.erase(
                                    widget.lines,
                                    _erasing!,
                                    _eraserR,
                                    _aspect,
                                  )),
                            ?_live,
                          ],
                          version: 0,
                          eraser: _erasing?.last,
                          eraserR: _eraserPx,
                        ),
                      ),
                    ),
                  ),
                  if (widget.samOverlay != null)
                    Positioned.fromRect(
                      rect: z,
                      child: IgnorePointer(
                        child: Image.memory(
                          widget.samOverlay!,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                  if (_samOn && (widget.samMarks.isNotEmpty || _stroke != null))
                    Positioned.fromRect(
                      rect: z,
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _SamPainter(
                            marks: widget.samMarks,
                            stroke: _stroke,
                            showMarks: _samTools.contains(_tool),
                          ),
                        ),
                      ),
                    ),
                  if (widget.showRoi)
                    Positioned.fromRect(
                      rect: z,
                      child: IgnorePointer(
                        ignoring: _painting,
                        child: Opacity(
                          opacity: _painting ? 0.45 : 1,
                          child: _RoiLayer(
                            roi: widget.roi,
                            size: z.size,
                            onChanged: widget.onChanged,
                          ),
                        ),
                      ),
                    ),
                  if (_drawOn) Positioned(left: 12, top: 84, child: _toolBar()),
                  if (_samOn)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: _samBar(),
                      ),
                    ),
                  if (widget.samBusy)
                    const Positioned(
                      top: 16,
                      left: 0,
                      right: 0,
                      child: Center(child: _BusyChip('🪄 치아 윤곽 찾는 중…')),
                    ),
                  const Positioned(
                    left: 16,
                    top: 16,
                    child: IgnorePointer(
                      child: PhotoBadge(
                        title: '원본',
                        sub: '치료 전',
                        color: _beforeColor,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Column(
                      children: [
                        _zoomButton(
                          Icons.add,
                          '확대',
                          _s >= _maxZoom ? null : () => _zoomBtn(1.5),
                        ),
                        const SizedBox(height: 8),
                        _zoomButton(
                          Icons.remove,
                          '축소',
                          _s <= _minZoom + 0.01
                              ? null
                              : () => _zoomBtn(1 / 1.5),
                        ),
                        const SizedBox(height: 8),
                        _zoomButton(
                          Icons.fit_screen,
                          '원래 크기',
                          (_s - 1).abs() < 0.01
                              ? null
                              : () => setState(() {
                                  _s = 1;
                                  _o = _clamp(Offset.zero, 1);
                                }),
                        ),
                        if ((_s - 1).abs() > 0.01) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${_s.toStringAsFixed(1)}배',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

enum _Tool { roi, upper, lower, eraser, incisal, sam, samAdd, samErase, mark }

/// 손을 대는 순간 바로 터치를 차지하는 확대/이동 인식기 (바깥 스크롤보다 먼저)
class _EagerScaleRecognizer extends ScaleGestureRecognizer {
  _EagerScaleRecognizer({super.debugOwner});
  bool eager = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (eager) resolvePointer(event.pointer, GestureDisposition.accepted);
  }
}

class _ScaleArea extends StatelessWidget {
  const _ScaleArea({
    required this.eager,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onScaleEnd,
    this.onDoubleTapDown,
    this.onDoubleTap,
  });
  final bool eager;
  final GestureScaleStartCallback onScaleStart;
  final GestureScaleUpdateCallback onScaleUpdate;
  final GestureScaleEndCallback onScaleEnd;
  final GestureTapDownCallback? onDoubleTapDown;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _EagerScaleRecognizer:
            GestureRecognizerFactoryWithHandlers<_EagerScaleRecognizer>(
              () => _EagerScaleRecognizer(debugOwner: this),
              (r) => r
                ..eager = eager
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = onScaleStart
                ..onUpdate = onScaleUpdate
                ..onEnd = onScaleEnd,
            ),
        if (onDoubleTap != null)
          DoubleTapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
                () => DoubleTapGestureRecognizer(debugOwner: this),
                (r) => r
                  ..onDoubleTapDown = onDoubleTapDown
                  ..onDoubleTap = onDoubleTap,
              ),
      },
    );
  }
}

const _upperColor = Color(0xFF00C853); // 상악선: 초록
const _lowerColor = Color(0xFFFF2D95); // 하악선: 분홍
const _incisalColor = Color(0xFFFFC400); // 절단선: 노랑

/// 서비컬 라인 그리기 (화면에서는 항상 같은 굵기)
class _LinePainter extends CustomPainter {
  _LinePainter(
    this.lines, {
    required this.version,
    this.eraser,
    this.eraserR = 0,
  });
  final List<GuideLine> lines;
  final int version;
  final Offset? eraser; // 지우개 위치 (사진 기준 0~1)
  final double eraserR; // 화면 px

  @override
  void paint(Canvas canvas, Size size) {
    for (final l in lines) {
      final pts = [
        for (final o in l.pts) Offset(o.dx * size.width, o.dy * size.height),
      ];
      if (pts.length < 2) continue;
      final path = Path()..addPolygon(pts, false);
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0x99000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = l.incisal
              ? _incisalColor
              : l.upper
              ? _upperColor
              : _lowerColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final e = eraser;
    if (e != null) {
      final c = Offset(e.dx * size.width, e.dy * size.height);
      canvas.drawCircle(c, eraserR, Paint()..color = const Color(0x33FFFFFF));
      canvas.drawCircle(
        c,
        eraserR,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => true;
}

class _RoiLayer extends StatelessWidget {
  const _RoiLayer({
    required this.roi,
    required this.size,
    required this.onChanged,
  });
  final Rect roi;
  final Size size;
  final ValueChanged<Rect> onChanged;

  static const _min = 0.08;

  Rect _toPx(Rect r) => Rect.fromLTWH(
    r.left * size.width,
    r.top * size.height,
    r.width * size.width,
    r.height * size.height,
  );

  void _move(Offset d) {
    final dx = d.dx / size.width, dy = d.dy / size.height;
    onChanged(
      Rect.fromLTWH(
        (roi.left + dx).clamp(0.0, 1 - roi.width),
        (roi.top + dy).clamp(0.0, 1 - roi.height),
        roi.width,
        roi.height,
      ),
    );
  }

  void _resize(Offset d, bool left, bool top) {
    final dx = d.dx / size.width, dy = d.dy / size.height;
    var l = roi.left, t = roi.top, r = roi.right, b = roi.bottom;
    if (left) {
      l = (l + dx).clamp(0.0, r - _min);
    } else {
      r = (r + dx).clamp(l + _min, 1.0);
    }
    if (top) {
      t = (t + dy).clamp(0.0, b - _min);
    } else {
      b = (b + dy).clamp(t + _min, 1.0);
    }
    onChanged(Rect.fromLTRB(l, t, r, b));
  }

  @override
  Widget build(BuildContext context) {
    final px = _toPx(roi);
    Widget handle(bool left, bool top) => Positioned(
      left: (left ? px.left : px.right) - 22,
      top: (top ? px.top : px.bottom) - 22,
      width: 44,
      height: 44,
      child: MouseRegion(
        cursor: left == top
            ? SystemMouseCursors.resizeUpLeftDownRight
            : SystemMouseCursors.resizeUpRightDownLeft,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanUpdate: (e) => _resize(e.delta, left, top),
          child: Center(
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.blue, width: 3),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x4D000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(child: CustomPaint(painter: _RoiPainter(px))),
        ),
        Positioned.fromRect(
          rect: px,
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onPanUpdate: (e) => _move(e.delta),
              child: Align(
                alignment: const Alignment(0, -0.85),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.blue,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    '치아 영역',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        handle(true, true),
        handle(false, true),
        handle(true, false),
        handle(false, false),
      ],
    );
  }
}

class _RoiPainter extends CustomPainter {
  _RoiPainter(this.r);
  final Rect r;

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(
      r,
      Radius.elliptical(r.width * 0.38, r.height * 0.38),
    );
    final mask = Path()
      ..fillType = PathFillType
          .evenOdd // 바깥만 어둡게 (영역 안은 원본 그대로)
      ..addRect(Offset.zero & size)
      ..addRRect(rr);
    canvas.drawPath(mask, Paint()..color = const Color(0x80081222));
    // 점선 테두리
    final dash = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    for (final m in (Path()..addRRect(rr)).computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 14) {
        canvas.drawPath(m.extractPath(d, math.min(d + 8, m.length)), dash);
      }
    }
  }

  @override
  bool shouldRepaint(_RoiPainter old) => old.r != r;
}

// -----------------------------------------------------------------------------
// 2) 일반 화면: Before 위 / After 아래
// -----------------------------------------------------------------------------
class StackedCompare extends StatelessWidget {
  const StackedCompare({
    super.key,
    required this.before,
    required this.after,
    required this.fit,
    this.big = false,
    this.beforeTitle = 'BEFORE',
    this.beforeSub = '치료 전',
    this.afterTitle = 'AFTER',
    this.afterSub = '시뮬레이션',
    this.afterOverlay,
  });
  final Uint8List before;
  final Uint8List after;
  final Uint8List? afterOverlay; // 원본 윤곽 겹쳐 보기 (투명 PNG)
  final BoxFit fit;
  final bool big;
  final String beforeTitle, beforeSub, afterTitle, afterSub;

  Widget _pane(Uint8List bytes, Widget badge, {Uint8List? overlay}) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: _stageColor,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(bytes, fit: fit, gaplessPlayback: true),
              if (overlay != null)
                IgnorePointer(
                  child: Image.memory(overlay, fit: fit, gaplessPlayback: true),
                ),
              Positioned(left: 16, top: 16, child: badge),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: _pane(
                before,
                PhotoBadge(
                  title: beforeTitle,
                  sub: beforeSub,
                  color: _beforeColor,
                  big: big,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _pane(
                after,
                PhotoBadge(
                  title: afterTitle,
                  sub: afterSub,
                  color: AppColors.blue,
                  big: big,
                ),
                overlay: afterOverlay,
              ),
            ),
          ],
        ),
        Align(
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.blue, width: 1.5),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x2E00285A),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.arrow_downward_rounded,
                  size: 16,
                  color: AppColors.blue,
                ),
                SizedBox(width: 6),
                Text(
                  '시뮬레이션 결과',
                  style: TextStyle(
                    color: AppColors.blue,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 3) 브리핑 모드: 겹쳐 놓고 가운데 손잡이를 좌우로 끄는 슬라이더
// -----------------------------------------------------------------------------
class SliderCompare extends StatefulWidget {
  const SliderCompare({
    super.key,
    required this.before,
    required this.after,
    required this.fit,
    required this.position,
    required this.onChanged,
    this.beforeTitle = 'BEFORE',
    this.beforeSub = '치료 전',
    this.afterTitle = 'AFTER',
    this.afterSub = '시뮬레이션',
    this.afterOverlay,
  });
  final String beforeTitle, beforeSub, afterTitle, afterSub;
  final Uint8List before;
  final Uint8List after;
  final Uint8List? afterOverlay; // 원본 윤곽 겹쳐 보기
  final BoxFit fit;
  final double position; // 0(전부 After) ~ 1(전부 Before)
  final ValueChanged<double> onChanged;

  @override
  State<SliderCompare> createState() => _SliderCompareState();
}

class _SliderCompareState extends State<SliderCompare> {
  bool _dragging = false;
  final _focus = FocusNode(debugLabel: 'SliderCompare');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _set(double v) => widget.onChanged(v.clamp(0.0, 1.0));

  KeyEventResult _key(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step = HardwareKeyboard.instance.isShiftPressed ? 0.1 : 0.02;
    if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _set(widget.position - step);
    } else if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
      _set(widget.position + step);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth, x = w * widget.position;
        final pct = (widget.position * 100).round();
        return Focus(
          focusNode: _focus,
          onKeyEvent: _key,
          child: MouseRegion(
            cursor: _dragging
                ? SystemMouseCursors.grabbing
                : SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onTapDown: (d) {
                _focus.requestFocus();
                _set(d.localPosition.dx / w);
              },
              onHorizontalDragStart: (d) => setState(() => _dragging = true),
              onHorizontalDragUpdate: (d) => _set(d.localPosition.dx / w),
              onHorizontalDragEnd: (_) => setState(() => _dragging = false),
              onHorizontalDragCancel: () => setState(() => _dragging = false),
              child: Semantics(
                slider: true,
                value: 'Before $pct%',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: _stageColor),
                      Image.memory(
                        widget.after,
                        fit: widget.fit,
                        gaplessPlayback: true,
                      ),
                      if (widget.afterOverlay != null)
                        IgnorePointer(
                          child: Image.memory(
                            widget.afterOverlay!,
                            fit: widget.fit,
                            gaplessPlayback: true,
                          ),
                        ),
                      ClipRect(
                        clipper: _LeftClipper(widget.position),
                        child: Image.memory(
                          widget.before,
                          fit: widget.fit,
                          gaplessPlayback: true,
                        ),
                      ),
                      Positioned(
                        left: 16,
                        top: 16,
                        child: AnimatedOpacity(
                          opacity: widget.position > 0.14 ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: PhotoBadge(
                            title: widget.beforeTitle,
                            sub: widget.beforeSub,
                            color: _beforeColor,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 16,
                        top: 16,
                        child: AnimatedOpacity(
                          opacity: widget.position < 0.86 ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: PhotoBadge(
                            title: widget.afterTitle,
                            sub: widget.afterSub,
                            color: AppColors.blue,
                            alignEnd: true,
                          ),
                        ),
                      ),
                      Positioned(
                        left: x - 0.75,
                        top: 0,
                        bottom: 0,
                        width: 1.5,
                        child: const IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x40000000),
                                  blurRadius: 3,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: x - 17,
                        top: c.maxHeight / 2 - 17,
                        child: IgnorePointer(
                          child: AnimatedScale(
                            scale: _dragging ? 1.08 : 1,
                            duration: const Duration(milliseconds: 150),
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.blue,
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x4000285A),
                                    blurRadius: 8,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.code_rounded,
                                color: AppColors.blue,
                                size: 18,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 16,
                        child: IgnorePointer(
                          child: Center(
                            child: AnimatedOpacity(
                              opacity: _dragging ? 1 : 0,
                              duration: const Duration(milliseconds: 150),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  'Before $pct%  ·  After ${100 - pct}%',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  const _LeftClipper(this.f);
  final double f;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * f, size.height);
  @override
  bool shouldReclip(_LeftClipper old) => old.f != f;
}

class _BusyChip extends StatelessWidget {
  const _BusyChip(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ],
    ),
  );
}

/// 📍 기준점 + 손 다듬기 중인 획
class _SamPainter extends CustomPainter {
  _SamPainter({required this.marks, this.stroke, this.showMarks = true});
  final List<({String label, Offset zenith, Offset incisal})> marks;
  final MaskStroke? stroke;
  final bool showMarks;

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(Offset o) => Offset(o.dx * size.width, o.dy * size.height);
    final st = stroke;
    if (st != null && st.pts.isNotEmpty) {
      final p = Paint()
        ..color = st.erase ? const Color(0x88FF4D4F) : const Color(0x8800D6B4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = st.r * size.width * 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()..moveTo(at(st.pts.first).dx, at(st.pts.first).dy);
      for (final o in st.pts.skip(1)) {
        path.lineTo(at(o).dx, at(o).dy);
      }
      if (st.pts.length == 1)
        path.lineTo(at(st.pts.first).dx + 0.1, at(st.pts.first).dy);
      canvas.drawPath(path, p);
    }
    if (!showMarks) return;
    for (final m in marks) {
      final z = at(m.zenith), i = at(m.incisal);
      canvas.drawLine(
        z,
        i,
        Paint()
          ..color = const Color(0xCCFFFFFF)
          ..strokeWidth = 1.2,
      );
      for (final (o, c) in [
        (z, const Color(0xFF00C853)),
        (i, const Color(0xFFFFC400)),
      ]) {
        canvas.drawCircle(o, 7, Paint()..color = const Color(0xAA000000));
        canvas.drawCircle(o, 5.5, Paint()..color = c);
      }
      final tp = TextPainter(
        text: TextSpan(
          text: m.label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            shadows: [Shadow(blurRadius: 3)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, z - Offset(tp.width / 2, tp.height + 9));
    }
  }

  @override
  bool shouldRepaint(_SamPainter old) => true;
}
