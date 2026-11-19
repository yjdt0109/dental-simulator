import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../ai/ai_service.dart';
import '../ai/pipeline.dart' show PipelineError;
import '../ai/tooth_select.dart';
import 'tooth_resize.dart';

/// 크기 조절 방향
enum GrowSide { up, down, left, right }

/// 🦷 변환된 사진의 치아 크기 조절 (태블릿 화면 · 상담 PC 공통)
///   치아를 탭 → SAM 으로 그 치아 상자 찾기 → 위·아래·좌·우 ± (치아 크기의 3%씩)
class ResizeSession {
  ResizeSession({
    required this.image,
    this.noPrep = false,
    List<ResizeTooth> teeth = const [],
    this.chartTeeth = const [],
    List<img.Image?> masks = const [],
  }) : teeth = [...teeth],
       grows = List.filled(teeth.length, const Grow(), growable: true),
       masks = [
         for (var i = 0; i < teeth.length; i++)
           i < masks.length ? masks[i] : null,
       ];

  /// 치아 윤곽 (있으면 그 치아 픽셀만 커짐 → 잇몸·옆 치아 그대로)
  final List<img.Image?> masks;

  /// 치아를 고를 때 탭한 점 (빼기 클릭으로 다시 찾을 때 씀)
  final List<Offset?> taps = [];

  /// ➖ 빼기 클릭: 고른 치아에 옆 치아가 같이 잡혔을 때, 빼고 싶은 곳을 찍으면 그 부분을 빼고 다시 찾음
  Future<String?> negTap(Offset p, {required String? falKey}) async {
    var i = -1;
    for (var k = 0; k < teeth.length; k++) {
      if (teeth[k].box.inflate(0.004).contains(p)) {
        i = k;
        if (k == sel) break;
      }
    }
    if (i < 0) return '빼고 싶은 곳은 고른 치아 상자 안을 찍어 주세요.';
    final tap = i < taps.length ? taps[i] : null;
    if (tap == null)
      return '이 치아는 원본에서 고른 치아라 빼기 클릭을 쓸 수 없어요. [이 치아 빼기] 후 다시 클릭해 주세요.';
    if (falKey == null) return '자동 선택(SAM)에는 Fal.ai API 키가 필요합니다.';
    busy = true;
    try {
      final sm = _small!;
      final raw = await segmentAround(FalSam(falKey), sm, tap, negatives: [p]);
      final s = await compute((a) => analyzeSel(a.$1, a.$2, a.$3), (
        sm,
        raw,
        tap,
      ));
      if (s == null) return '다시 찾지 못했어요. [이 치아 빼기] 후 치아 한가운데를 다시 클릭해 주세요.';
      teeth[i] = (label: teeth[i].label, box: s.box, upper: s.upper);
      masks[i] = s.mask;
      grows[i] = const Grow();
      sel = i;
      return null;
    } on PipelineError catch (e) {
      return e.message;
    } finally {
      busy = false;
    }
  }

  final Uint8List image; // 조절할 변환 결과
  final bool noPrep; // 무삭제: 마진 쪽 고정 · 작아지지 않게
  final List<int> chartTeeth; // 번호 붙이기용
  final List<ResizeTooth> teeth;
  final List<Grow> grows;
  int sel = 0;
  bool busy = false;
  Uint8List? _jpeg; // SAM 에 보내는 크기
  img.Image? _small;

  static const step = 0.03;

  List<(Rect, Grow, img.Image?)> get items => [
    for (var i = 0; i < teeth.length; i++) (teeth[i].box, grows[i], masks[i]),
  ];

  bool get changed => grows.any((g) => !g.isZero);

  bool isMargin(int i, GrowSide s) =>
      teeth[i].upper ? s == GrowSide.up : s == GrowSide.down;

  double get(Grow g, GrowSide s) => switch (s) {
    GrowSide.left => g.left,
    GrowSide.right => g.right,
    GrowSide.up => g.up,
    GrowSide.down => g.down,
  };

  /// 늘린 양을 치아 크기 대비 % 로
  int pct(int i, GrowSide s) {
    final b = teeth[i].box;
    final size = s == GrowSide.left || s == GrowSide.right ? b.width : b.height;
    return (get(grows[i], s) / size * 100).round();
  }

  /// [dir] +1 키우기 / -1 줄이기. 바뀌었으면 true
  bool stepTooth(int i, GrowSide s, int dir) {
    if (i < 0 || i >= teeth.length) return false;
    final b = teeth[i].box;
    final size = s == GrowSide.left || s == GrowSide.right ? b.width : b.height;
    return setGrow(i, s, get(grows[i], s) + dir * size * step);
  }

  bool setGrow(int i, GrowSide s, double v) {
    final b = teeth[i].box;
    final size = s == GrowSide.left || s == GrowSide.right ? b.width : b.height;
    if (noPrep && isMargin(i, s)) return false; // 무삭제: 마진 고정
    // 줄이기는 치아 크기의 30% 까지 (줄어든 자리는 치아 바깥 배경으로 채움), 키우기는 50% 까지
    // 무삭제 라미네이트는 치아를 깎지 않으므로 줄이기 없음
    v = v.clamp(noPrep ? 0.0 : -size * 0.3, size * 0.5);
    final g = grows[i];
    if (get(g, s) == v) return false;
    grows[i] = switch (s) {
      GrowSide.left => g.copy(left: v),
      GrowSide.right => g.copy(right: v),
      GrowSide.up => g.copy(up: v),
      GrowSide.down => g.copy(down: v),
    };
    return true;
  }

  /// 사진 (x, y)(0~1) 탭: 이미 고른 치아면 그 치아 선택, 아니면 SAM 으로 새 치아 찾기
  Future<String?> tap(Offset p, {required String? falKey}) async {
    for (var i = 0; i < teeth.length; i++) {
      if (teeth[i].box.inflate(0.004).contains(p)) {
        sel = i;
        return null;
      }
    }
    if (falKey == null) return '치아 자동 선택(SAM)에는 Fal.ai API 키가 필요합니다.';
    busy = true;
    try {
      if (_small == null) {
        final src = await AiService.decodePhoto(image);
        _jpeg = await AiService.photoJpeg(src);
        _small = img.decodeJpg(_jpeg!);
      }
      final sm = _small!;
      final raw = await segmentAround(FalSam(falKey), sm, p);
      final s = await compute((a) => analyzeSel(a.$1, a.$2, a.$3), (
        sm,
        raw,
        p,
      ));
      if (s == null) return '치아가 아닌 곳 같아요. 치아 한가운데를 다시 탭해 주세요.';
      addTooth(s.box, s.upper, mask: s.mask, tap: p);
      return null;
    } on PipelineError catch (e) {
      return e.message;
    } finally {
      busy = false;
    }
  }

  void addTooth(Rect box, bool upper, {img.Image? mask, Offset? tap}) {
    teeth.add((label: '', box: box, upper: upper));
    grows.add(const Grow());
    masks.add(mask);
    while (taps.length < teeth.length - 1) {
      taps.add(null);
    }
    taps.add(tap);
    _relabel();
    sel = teeth.length - 1;
  }

  void _relabel() {
    // 번호: 차트에서 고른 같은 악궁 치아 수와 같으면 FDI, 아니면 '치아 n'
    for (final upper in [true, false]) {
      final idx =
          [
            for (var i = 0; i < teeth.length; i++)
              if (teeth[i].upper == upper) i,
          ]..sort(
            (a, b) => teeth[a].box.center.dx.compareTo(teeth[b].box.center.dx),
          );
      final arch = upper
          ? [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28]
          : [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38];
      final chosen = arch.where(chartTeeth.contains).toList();
      for (var k = 0; k < idx.length; k++) {
        final t = teeth[idx[k]];
        teeth[idx[k]] = (
          label: chosen.length == idx.length
              ? '#${chosen[k]}'
              : '${upper ? '상악' : '하악'} ${k + 1}',
          box: t.box,
          upper: t.upper,
        );
      }
    }
  }

  void removeTooth(int i) {
    if (i < 0 || i >= teeth.length) return;
    teeth.removeAt(i);
    grows.removeAt(i);
    masks.removeAt(i);
    if (i < taps.length) taps.removeAt(i);
    _relabel();
    sel = sel.clamp(0, teeth.isEmpty ? 0 : teeth.length - 1);
  }

  /// 미리보기 (긴 변 1000px)
  Future<Uint8List> preview() async {
    _prev ??= await compute(shrinkPreview, image);
    final s = _prev!;
    if (!changed) return img.encodeJpg(s, quality: 85);
    return compute(previewGrows, (s, items));
  }

  img.Image? _prev;

  /// 원래 크기로 적용
  Future<Uint8List> apply() => compute(fullGrows, (image, items));

  /// PC 로 보낼 상태
  Map<String, Object?> toJson() => {
    'sel': sel,
    'busy': busy,
    'noPrep': noPrep,
    'teeth': [
      for (var i = 0; i < teeth.length; i++)
        {
          'l': teeth[i].label,
          'b': [
            for (final v in [
              teeth[i].box.left - grows[i].left,
              teeth[i].box.top - grows[i].up,
              teeth[i].box.right + grows[i].right,
              teeth[i].box.bottom + grows[i].down,
            ])
              (v * 1000).round() / 1000,
          ],
          'u': teeth[i].upper,
          'p': {for (final s in GrowSide.values) s.name: pct(i, s)},
        },
    ],
  };
}
