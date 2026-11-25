import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// ② AI 결과 위치 자동 맞춤
/// AI(나노바나나 등)는 사진을 몇 픽셀 밀거나 조금 키워서 돌려줄 때가 있음 →
/// 바뀌지 않았어야 할 곳(얼굴·입술·개구기·배경)을 기준으로 밀림·확대를 찾아 원본에 맞게 되돌림.
/// [ai] 는 이미 [src] 와 같은 크기. 맞출 필요가 없으면 [ai] 를 그대로 돌려줌.
({img.Image image, double scale, double dx, double dy}) alignAiToSource(
  img.Image src,
  img.Image ai,
) {
  final w = src.width, h = src.height;
  if (ai.width != w || ai.height != h || w < 16 || h < 16) {
    return (image: ai, scale: 1, dx: 0, dy: 0);
  }
  // 작게 줄여 회색조로 비교 (긴 변 160px)
  final k = 160 / math.max(w, h);
  final sw = math.max(8, (w * k).round()), sh = math.max(8, (h * k).round());
  List<double> gray(img.Image im) {
    final s = img.copyResize(
      im,
      width: sw,
      height: sh,
      interpolation: img.Interpolation.average,
    );
    return [
      for (var y = 0; y < sh; y++)
        for (var x = 0; x < sw; x++)
          () {
            final p = s.getPixel(x, y);
            return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
          }(),
    ];
  }

  final gs = gray(src), ga = gray(ai);
  final cx = (sw - 1) / 2, cy = (sh - 1) / 2;
  // 바뀐 치아 부분 영향을 줄이려고 차이를 40 에서 자름
  double cost(double s, double dx, double dy) {
    var sum = 0.0, n = 0;
    for (var y = 2; y < sh - 2; y += 2) {
      for (var x = 2; x < sw - 2; x += 2) {
        final ax = ((x - cx - dx) / s + cx).round();
        final ay = ((y - cy - dy) / s + cy).round();
        if (ax < 0 || ay < 0 || ax >= sw || ay >= sh) continue;
        final d = (gs[y * sw + x] - ga[ay * sw + ax]).abs();
        sum += d > 40 ? 40 : d;
        n++;
      }
    }
    return n == 0 ? 1e9 : sum / n;
  }

  final c0 = cost(1, 0, 0);
  var best = (s: 1.0, dx: 0.0, dy: 0.0, c: c0);
  final r = (math.max(sw, sh) * 0.05).ceil(); // ±5% 까지 밀림
  for (var si = -4; si <= 4; si++) {
    final s = 1 + si * 0.01; // ±4% 까지 크기
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        final c = cost(s, dx.toDouble(), dy.toDouble());
        if (c < best.c)
          best = (s: s, dx: dx.toDouble(), dy: dy.toDouble(), c: c);
      }
    }
  }
  // 반 픽셀 단위로 한 번 더 다듬기
  for (final ddx in [-0.5, 0.0, 0.5]) {
    for (final ddy in [-0.5, 0.0, 0.5]) {
      final c = cost(best.s, best.dx + ddx, best.dy + ddy);
      if (c < best.c) {
        best = (s: best.s, dx: best.dx + ddx, dy: best.dy + ddy, c: c);
      }
    }
  }
  // 확실히 좋아질 때만 (3% 이상) 고침
  if (best.c >= c0 * 0.97 || (best.s == 1 && best.dx == 0 && best.dy == 0)) {
    return (image: ai, scale: 1, dx: 0, dy: 0);
  }
  final fx = best.dx / k, fy = best.dy / k; // 원래 크기 픽셀
  final fcx = (w - 1) / 2, fcy = (h - 1) / 2;
  final out = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final ax = ((x - fcx - fx) / best.s + fcx).clamp(0.0, w - 1.0);
      final ay = ((y - fcy - fy) / best.s + fcy).clamp(0.0, h - 1.0);
      final p = ai.getPixelInterpolate(
        ax,
        ay,
        interpolation: img.Interpolation.linear,
      );
      out.setPixelRgb(x, y, p.r, p.g, p.b);
    }
  }
  return (image: out, scale: best.s, dx: fx, dy: fy);
}
