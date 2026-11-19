import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 직접 등록한 사진의 미백 시뮬레이션.
/// 지정한 치아 영역(roi, 0~1 비율) 안에서 "밝고, 붉지 않고, 채도가 과하지 않은" 픽셀만
/// CIE Lab 색공간에서 목표 셰이드 쪽으로 밝기·노란기를 옮깁니다.
/// 치아 모양·배열은 바꾸지 않습니다 (그건 AI 이미지 편집 연동 단계).
/// 치아를 찾지 못하면 null.
Future<Uint8List?> whitenPhoto(
  Uint8List src, {
  required Rect roi,
  required double targetL,
  required double targetB,
  required int strength,
}) async {
  // 1) 디코드 (긴 변 1600px 이하로 줄여 태블릿 메모리 보호)
  final buffer = await ui.ImmutableBuffer.fromUint8List(src);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  final scale = math.min(1.0, 1600 / math.max(desc.width, desc.height));
  final w = (desc.width * scale).round(), h = (desc.height * scale).round();
  final codec = await desc.instantiateCodec(targetWidth: w, targetHeight: h);
  final frame = await codec.getNextFrame();
  final raw = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (raw == null) return null;

  // 2) 픽셀 보정은 별도 isolate 에서 (화면이 멈추지 않게)
  final out = await compute(
    _process,
    _Job(
      raw.buffer.asUint8List(),
      w,
      h,
      roi.left,
      roi.top,
      roi.width,
      roi.height,
      targetL,
      targetB,
      strength / 100,
    ),
  );
  if (out == null) return null;

  // 3) 다시 PNG 로
  final img = await _fromPixels(out, w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  return png?.buffer.asUint8List();
}

Future<ui.Image> _fromPixels(Uint8List px, int w, int h) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

class _Job {
  _Job(
    this.px,
    this.w,
    this.h,
    this.rx,
    this.ry,
    this.rw,
    this.rh,
    this.targetL,
    this.targetB,
    this.st,
  );
  final Uint8List px;
  final int w, h;
  final double rx, ry, rw, rh, targetL, targetB, st;
}

final Float64List _lin = Float64List.fromList(
  List.generate(256, (i) {
    final c = i / 255;
    return c <= 0.04045
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }),
);

double _f(double t) =>
    t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
double _fi(double t) {
  final t3 = t * t * t;
  return t3 > 0.008856 ? t3 : (t - 16 / 116) / 7.787;
}

int _gam(double c) {
  c = c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
  return c <= 0
      ? 0
      : c >= 1
      ? 255
      : (c * 255 + 0.5).toInt();
}

double _smooth(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// 픽셀 보정 본체 (테스트에서도 직접 호출)
@visibleForTesting
Uint8List? whitenPixels(
  Uint8List px,
  int w,
  int h,
  Rect roi,
  double targetL,
  double targetB,
  double st,
) => _process(
  _Job(
    px,
    w,
    h,
    roi.left,
    roi.top,
    roi.width,
    roi.height,
    targetL,
    targetB,
    st,
  ),
);

Uint8List? _process(_Job j) {
  final px = Uint8List.fromList(j.px);
  final w = j.w, h = j.h;
  final x0 = (w * j.rx).floor().clamp(0, w - 1),
      y0 = (h * j.ry).floor().clamp(0, h - 1);
  final bw = (w * j.rw).round().clamp(1, w - x0),
      bh = (h * j.rh).round().clamp(1, h - y0);
  final n = bw * bh;
  final ls = Float32List(n),
      as_ = Float32List(n),
      bs = Float32List(n),
      m = Float32List(n);
  double sw = 0, sl = 0, sa = 0, sb = 0;
  for (var y = 0; y < bh; y++) {
    final ny = ((y + 0.5) / bh - 0.5) * 2;
    for (var x = 0; x < bw; x++) {
      final k = y * bw + x, p = ((y0 + y) * w + x0 + x) * 4;
      final r = _lin[px[p]], g = _lin[px[p + 1]], b = _lin[px[p + 2]];
      final fx = _f((r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047);
      final fy = _f(r * 0.2126 + g * 0.7152 + b * 0.0722);
      final fz = _f((r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883);
      final L = 116 * fy - 16, a = 500 * (fx - fy), bb = 200 * (fy - fz);
      ls[k] = L;
      as_[k] = a;
      bs[k] = bb;
      final nx = ((x + 0.5) / bw - 0.5) * 2;
      final roiW =
          1 - _smooth(0.7, 1, math.pow(nx, 4) + math.pow(ny, 4).toDouble());
      final score =
          roiW *
          _smooth(38, 58, L) *
          (1 - _smooth(5, 11, a)) *
          (1 - _smooth(34, 52, math.sqrt(a * a + bb * bb)));
      m[k] = score;
      sw += score;
      sl += score * L;
      sa += score * a;
      sb += score * bb;
    }
  }
  if (sw < n * 0.01) return null; // 치아를 찾지 못함
  final lr = sl / sw, ar = sa / sw, br = sb / sw, st = j.st;
  final dL = math.max(0, j.targetL - lr) * st;
  final dB = math.min(0, j.targetB - br) * st;
  final dA = -math.max(0, ar) * 0.6 * st;
  for (var y = 0; y < bh; y++) {
    for (var x = 0; x < bw; x++) {
      final k = y * bw + x, s = m[k];
      if (s < 0.01) continue;
      final L = ls[k] + s * (dL - (ls[k] - lr) * 0.12 * st);
      final a = as_[k] + s * dA;
      final b = bs[k] + s * (dB - (bs[k] - br) * 0.35 * st);
      final fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
      final X = 0.95047 * _fi(fx), Y = _fi(fy), Z = 1.08883 * _fi(fz);
      final p = ((y0 + y) * w + x0 + x) * 4;
      px[p] = _gam(3.2406 * X - 1.5372 * Y - 0.4986 * Z);
      px[p + 1] = _gam(-0.9689 * X + 1.8758 * Y + 0.0415 * Z);
      px[p + 2] = _gam(0.0557 * X - 0.2040 * Y + 1.0570 * Z);
    }
  }
  return px;
}
