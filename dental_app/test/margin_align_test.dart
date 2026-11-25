import 'dart:math' as math;
import 'dart:ui';

import 'package:dental_app/ai/align_fix.dart';
import 'package:dental_app/ai/tooth_select.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

ToothSel tooth(int w, int h, int x0, int x1, int y0, int y1) {
  final m = img.Image(width: w, height: h, numChannels: 1);
  img.fillRect(
    m,
    x1: x0,
    y1: y0,
    x2: x1,
    y2: y1,
    color: img.ColorRgb8(255, 255, 255),
  );
  return ToothSel(
    mask: m,
    tap: Offset((x0 + x1) / 2 / w, (y0 + y1) / 2 / h),
    box: Rect.fromLTRB(x0 / w, y0 / h, (x1 + 1) / w, (y1 + 1) / h),
    upper: true,
    zenith: Offset((x0 + x1) / 2 / w, y0 / h),
    incisal: Offset((x0 + x1) / 2 / w, y1 / h),
  );
}

void main() {
  test('③ 마진 고정형 영역: 잇몸 쪽은 그대로, 절단 쪽·치아 사이 틈은 열림', () {
    const w = 200, h = 160;
    // 위 앞니 2개 (40~79, 90~129), 사이 틈 80~89, 왼쪽 치아는 짧음(깨짐)
    final a = tooth(w, h, 40, 79, 40, 90), b = tooth(w, h, 90, 129, 40, 110);
    final union = img.Image(width: w, height: h, numChannels: 1);
    for (final t in [a, b]) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (t.mask.getPixel(x, y).r > 127) union.setPixelR(x, y, 255);
        }
      }
    }
    final r = marginLockedRegion(union, [a, b]);
    bool on(int x, int y) => r.getPixel(x, y).r > 127;
    expect(on(60, 39), isFalse); // 잇몸(서비컬 위)은 고정
    expect(on(60, 30), isFalse);
    expect(on(60, 100), isTrue); // 짧은(깨진) 치아도 옆 치아 길이까지 늘릴 수 있음
    expect(on(110, 118), isTrue); // 절단 쪽 25% 정도 더
    expect(on(110, 150), isFalse); // 너무 멀리는 아님
    expect(on(85, 60), isTrue); // 두 치아 사이 틈
    expect(on(20, 60), isFalse); // 바깥쪽(옆에 고른 치아 없음)은 거의 안 늘림
    expect(on(150, 60), isFalse);
  });

  test('② AI 결과가 밀리고 커져도 원본 위치로 되돌림', () {
    const w = 240, h = 180;
    final rnd = math.Random(3);
    final src = img.Image(width: w, height: h);
    for (var i = 0; i < 160; i++) {
      final x = rnd.nextInt(w - 20),
          y = rnd.nextInt(h - 20),
          s = 6 + rnd.nextInt(18);
      img.fillRect(
        src,
        x1: x,
        y1: y,
        x2: x + s,
        y2: y + s,
        color: img.ColorRgb8(
          rnd.nextInt(255),
          rnd.nextInt(255),
          rnd.nextInt(255),
        ),
      );
    }
    // AI 가 1.03배 키우고 (+7, -5) 밀었다고 가정
    final ai = img.Image(width: w, height: h);
    const sc = 1.03, mx = 7.0, my = -5.0;
    final cx = (w - 1) / 2, cy = (h - 1) / 2;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = src.getPixelInterpolate(
          ((x - cx - mx) / sc + cx).clamp(0, w - 1.0),
          ((y - cy - my) / sc + cy).clamp(0, h - 1.0),
        );
        ai.setPixelRgb(x, y, p.r, p.g, p.b);
      }
    }
    double err(img.Image a) {
      var s = 0.0, n = 0;
      for (var y = 20; y < h - 20; y += 3) {
        for (var x = 20; x < w - 20; x += 3) {
          s += (a.getPixel(x, y).r - src.getPixel(x, y).r).abs();
          n++;
        }
      }
      return s / n;
    }

    final r = alignAiToSource(src, ai);
    expect(err(r.image), lessThan(err(ai) * 0.5));
    expect(r.scale, closeTo(1 / 1.03, 0.011)); // 1.03배 커진 걸 되돌리는 배율
    // 바뀐 게 없으면 그대로
    final same = alignAiToSource(src, src.clone());
    expect(same.scale, 1);
    expect(same.dx, 0);
  });
}
