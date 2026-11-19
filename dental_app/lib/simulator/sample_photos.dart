import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'sim_models.dart';

/// 촬영실 샘플 환자용 예시 사진을 코드로 그립니다 (실제 환자 사진 아님).
/// [after] 가 true 면 치아 정렬·잇몸 라인 개선 + [tooth] 색으로 그린 시뮬레이션.
const double _w = 1200, _h = 900;
const Size kSampleSize = Size(_w, _h);

const _stain = [
  Color(0xFFD9C68E),
  Color(0xFFDCCB95),
  Color(0xFFE2D29F),
  Color(0xFFD8C384),
  Color(0xFFD3BC7B),
  Color(0xFFDFCD96),
  Color(0xFFD9C68E),
  Color(0xFFD2BE85),
  Color(0xFFD6C28A),
  Color(0xFFDBC991),
];
const _lowerStain = Color(0xFFCDB87D);

final Map<String, Uint8List> _cache = {};

Future<Uint8List> drawSamplePhoto(
  SampleView view, {
  required bool after,
  Color? tooth,
}) async {
  final key = '${view.name}:$after:${tooth?.toARGB32()}';
  final hit = _cache[key];
  if (hit != null) return hit;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, const Rect.fromLTWH(0, 0, _w, _h));
  final tc = tooth ?? const Color(0xFFF5EEDD);
  switch (view) {
    case SampleView.front:
      _front(c, after, tc);
    case SampleView.smile:
      _smile(c, after, tc);
    case SampleView.side:
      _side(c, after, tc);
  }
  final img = await rec.endRecording().toImage(_w.toInt(), _h.toInt());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return _cache[key] = data!.buffer.asUint8List();
}

/// 시뮬레이션 강도: 착색된 치아색 → 목표 셰이드 색 사이를 섞음
Color mixToothColor(Shade shade, int strength) => Color.lerp(
  const Color(0xFFD8C48A),
  shade.tooth,
  (strength / 100).clamp(0, 1),
)!;

void _skin(Canvas c, Color top, Color bottom) {
  c.drawRect(
    const Rect.fromLTWH(0, 0, _w, _h),
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [top, bottom],
      ).createShader(const Rect.fromLTWH(0, 0, _w, _h)),
  );
}

void _oval(Canvas c, double cx, double cy, double rx, double ry, Color color) =>
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2),
      Paint()..color = color,
    );

void _tooth(
  Canvas c,
  double x,
  double y,
  double w,
  double h,
  Color color, {
  double rot = 0,
  bool dark = false,
}) {
  c.save();
  c.translate(x + w / 2, y);
  c.rotate(rot);
  final rect = Rect.fromLTWH(-w / 2, 0, w, h);
  final darker = Color.lerp(color, Colors.black, dark ? 0.16 : 0.07)!;
  c.drawRRect(
    RRect.fromRectAndRadius(rect, Radius.circular((w * 0.28).clamp(0, 22))),
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color, darker],
      ).createShader(rect),
  );
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(-w / 2 + w * 0.14, h * 0.1, w * 0.22, h * 0.55),
      const Radius.circular(8),
    ),
    Paint()..color = Colors.white.withValues(alpha: 0.32),
  );
  c.restore();
}

void _watermark(Canvas c, String text) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.8),
        fontSize: 28,
        fontWeight: FontWeight.w600,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, Offset(_w - 30 - tp.width, _h - 30 - tp.height));
}

void _clipMouth(
  Canvas c,
  double cx,
  double cy,
  double rx,
  double ry, {
  double rot = 0,
}) {
  c.save();
  c.translate(cx, cy);
  c.rotate(rot);
  c.clipPath(
    Path()..addOval(
      Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
    ),
  );
  c.rotate(-rot);
  c.translate(-cx, -cy);
}

// 김민수: 정면, 덧니·틀어짐 + 착색
void _front(Canvas c, bool after, Color tc) {
  _skin(c, const Color(0xFFE9CDBB), const Color(0xFFD8B49E));
  _oval(c, 600, 470, 470, 255, const Color(0xFFB5525C));
  _oval(c, 600, 480, 400, 188, const Color(0xFF5A1F2A));
  _clipMouth(c, 600, 480, 400, 188);
  c.drawRect(
    const Rect.fromLTWH(150, 280, 900, 88),
    Paint()..color = const Color(0xFFD9737F),
  );
  const ws = [70.0, 80.0, 92.0, 104.0, 104.0, 92.0, 80.0, 70.0];
  const hs = [120.0, 140.0, 158.0, 175.0, 175.0, 158.0, 140.0, 120.0];
  const dy = [6.0, -4.0, 14.0, 0.0, 18.0, -8.0, 8.0, 4.0];
  const rot = [0.05, -0.08, 0.1, -0.03, 0.07, -0.1, 0.04, 0.0];
  const gap = [6.0, 16.0, 2.0, 20.0, 4.0, 14.0, 6.0, 0.0];
  var x = 600 - (ws.reduce((a, b) => a + b) + 42) / 2;
  for (var i = 0; i < 8; i++) {
    _tooth(
      c,
      x,
      350 + (after ? 0 : dy[i]),
      ws[i],
      hs[i],
      after ? tc : _stain[i],
      rot: after ? 0 : rot[i],
    );
    x += ws[i] + (after ? 6 : gap[i]);
  }
  const lrot = [0.05, -0.06, 0.0, 0.08, -0.05, 0.04, -0.07, 0.0];
  for (var i = 0; i < 8; i++) {
    _tooth(
      c,
      340 + i * 66.0,
      548,
      58,
      70,
      after ? tc : _lowerStain,
      rot: after ? 0 : lrot[i],
      dark: true,
    );
  }
  c.restore();
  _watermark(c, after ? '예시 · 시뮬레이션' : '예시 · 김민수 님 정면');
}

// 이지은: 스마일, 잇몸 과다 노출 + 짧은 치아 → 잇몸성형·라미네이트
void _smile(Canvas c, bool after, Color tc) {
  _skin(c, const Color(0xFFEDD3C3), const Color(0xFFDDBBA6));
  _oval(c, 600, 450, 520, 230, const Color(0xFFC2606B));
  _oval(c, 600, 470, 470, 170, const Color(0xFF4E1A24));
  _clipMouth(c, 600, 470, 470, 170);
  final gumH = after ? 46.0 : 112.0; // 서비컬 라인: 잇몸 노출 감소
  final gum = Paint()..color = const Color(0xFFE07D88);
  c.drawRect(Rect.fromLTWH(100, 280, 1000, 20 + gumH), gum);
  final edge = Path()..moveTo(100, 300 + gumH);
  for (var i = 0; i <= 10; i++) {
    edge.quadraticBezierTo(
      160 + i * 90.0,
      300 + gumH + 16,
      205 + i * 90.0,
      300 + gumH,
    );
  }
  edge
    ..lineTo(1100, 280)
    ..lineTo(100, 280)
    ..close();
  c.drawPath(edge, gum);
  const ws = [58.0, 66.0, 76.0, 88.0, 98.0, 98.0, 88.0, 76.0, 66.0, 58.0];
  const base = [
    96.0,
    112.0,
    122.0,
    136.0,
    148.0,
    148.0,
    136.0,
    122.0,
    112.0,
    96.0,
  ];
  const uneven = [0.0, 10.0, -6.0, 12.0, 0.0, 8.0, -10.0, 6.0, 4.0, 0.0];
  final top = 296 + gumH;
  var x = 600 - (ws.reduce((a, b) => a + b) + 45) / 2;
  for (var i = 0; i < 10; i++) {
    _tooth(
      c,
      x,
      top,
      ws[i],
      after ? base[i] + 34 : base[i] - 18 + uneven[i],
      after ? tc : _stain[i],
    );
    x += ws[i] + 5;
  }
  for (var i = 0; i < 10; i++) {
    _tooth(
      c,
      330 + i * 56.0,
      560,
      50,
      60,
      after ? tc : _lowerStain,
      dark: true,
    );
  }
  c.restore();
  _watermark(c, after ? '예시 · 시뮬레이션' : '예시 · 이지은 님 스마일');
}

// 박철수: 측면, 앞니 돌출 + 착색 → 교정
void _side(Canvas c, bool after, Color tc) {
  _skin(c, const Color(0xFFE6C7B3), const Color(0xFFD1AC95));
  c.save();
  c.translate(620, 450);
  c.rotate(-0.05);
  c.drawOval(
    Rect.fromCenter(center: Offset.zero, width: 1000, height: 480),
    Paint()..color = const Color(0xFFB04F5B),
  );
  c.translate(0, 5);
  c.drawOval(
    Rect.fromCenter(center: Offset.zero, width: 900, height: 360),
    Paint()..color = const Color(0xFF4A1A24),
  );
  c.restore();
  _clipMouth(c, 620, 455, 450, 180, rot: -0.05);
  final gum = Path()
    ..moveTo(190, 330)
    ..quadraticBezierTo(620, 250, 1060, 300)
    ..lineTo(1060, 360)
    ..quadraticBezierTo(620, 310, 190, 390)
    ..close();
  c.drawPath(gum, Paint()..color = const Color(0xFFD46F7C));
  const off = [0.0, 0.0, 0.0, 4.0, 10.0, 22.0, 44.0, 70.0];
  const offY = [0.0, 0.0, 0.0, 0.0, 4.0, 10.0, 22.0, 30.0];
  const rots = [-.02, -.02, -.03, 0.04, 0.1, 0.18, 0.28, 0.36];
  for (var i = 0; i < 8; i++) {
    final t = i / 7, w = 52 + t * 70, h = 96 + t * 92;
    _tooth(
      c,
      230 + t * 700 + (after ? 0 : off[i]),
      360 - t * 40 + (after ? 0 : offY[i]),
      w,
      h,
      after ? tc : _stain[i],
      rot: after ? -0.04 : rots[i],
      dark: t < 0.4,
    );
  }
  for (var i = 0; i < 8; i++) {
    final t = i / 7;
    _tooth(
      c,
      250 + t * 620,
      560 - t * 20,
      46 + t * 54,
      70 + t * 46,
      after ? tc : _lowerStain,
      dark: true,
    );
  }
  c.restore();
  _watermark(c, after ? '예시 · 시뮬레이션' : '예시 · 박철수 님 측면');
}
