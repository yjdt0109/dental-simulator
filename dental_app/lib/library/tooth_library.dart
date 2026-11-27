import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// -----------------------------------------------------------------------------
// 📐 6전치 라이브러리 (2026.11.27-k)
//   상악 13·12·11·21·22·23 을 정면에서 본 모양을 코드로 그림 (벡터 → 아무리 키워도 선명).
//   모양 5종 + 배열(황금비율 1.618 : 1 : 0.618, 잇몸 꼭대기·절단끝 높이 차, 스마일 곡선).
//   나중에 STL 라이브러리를 정면 사진으로 렌더링하면 [ToothForm] 대신 그 그림을 쓰면 됨.
// -----------------------------------------------------------------------------

/// 치아 모양 (중절치 기준, 측절치·견치는 같은 성격으로 비례 조정)
class ToothForm {
  const ToothForm({
    required this.id,
    required this.name,
    required this.desc,
    required this.cervicalW,
    required this.maxAt,
    required this.mesialR,
    required this.distalR,
    required this.wl,
    this.mamelons = false,
    this.flatEdge = true,
  });
  final String id, name, desc;

  /// 잇몸 쪽(치경부) 폭 / 최대 폭 — 작을수록 삼각형
  final double cervicalW;

  /// 가장 넓은 곳의 높이 (0 잇몸 ~ 1 절단끝)
  final double maxAt;

  /// 절단 모서리 둥글기 (치아 폭 비율): 가운데 쪽 / 바깥쪽
  final double mesialR, distalR;

  /// 중절치 폭 / 길이 (보통 0.75~0.85)
  final double wl;

  /// 절단끝 발육엽(맘멜론) — 젊은 치아
  final bool mamelons;

  /// 절단끝이 곧은지 (false 면 살짝 둥근 아치)
  final bool flatEdge;
}

const kToothForms = [
  ToothForm(
    id: 'square',
    name: '사각형',
    desc: '각진 모서리 · 남성적 · 단단한 인상',
    cervicalW: 0.80,
    maxAt: 0.55,
    mesialR: 0.05,
    distalR: 0.10,
    wl: 0.84,
  ),
  ToothForm(
    id: 'oval',
    name: '난원형',
    desc: '둥근 모서리 · 부드러운 인상',
    cervicalW: 0.66,
    maxAt: 0.60,
    mesialR: 0.18,
    distalR: 0.28,
    wl: 0.78,
    flatEdge: false,
  ),
  ToothForm(
    id: 'triangle',
    name: '삼각형',
    desc: '잇몸 쪽이 좁고 절단 쪽이 넓음 · 날렵한 인상',
    cervicalW: 0.55,
    maxAt: 0.78,
    mesialR: 0.07,
    distalR: 0.16,
    wl: 0.80,
  ),
  ToothForm(
    id: 'squareoval',
    name: '사각-난원형',
    desc: '가장 자연스러운 기본형',
    cervicalW: 0.72,
    maxAt: 0.62,
    mesialR: 0.10,
    distalR: 0.20,
    wl: 0.80,
  ),
  ToothForm(
    id: 'youthful',
    name: '젊은 형',
    desc: '살짝 긴 중절치 · 절단끝 발육엽 · 생기 있는 인상',
    cervicalW: 0.70,
    maxAt: 0.64,
    mesialR: 0.08,
    distalR: 0.22,
    wl: 0.74,
    mamelons: true,
  ),
];

ToothForm toothFormById(String id) =>
    kToothForms.firstWhere((f) => f.id == id, orElse: () => kToothForms[3]);

/// 사진 위에 놓은 위치·크기 (사진 픽셀 기준)
class LibraryPlacement {
  const LibraryPlacement({
    required this.center,
    required this.width,
    this.length = 1.0,
    this.arc = 0.4,
    this.rotation = 0,
  });

  /// 중절치 두 개의 가운데 (정중선 · 중절치 높이의 가운데)
  final Offset center;

  /// 견치~견치 정면 폭 (픽셀)
  final double width;

  /// 길이 배율 (1 = 모양 기본 비율)
  final double length;

  /// 스마일 곡선 (0 곧게 ~ 1 많이 휨): 측절치·견치 절단끝이 올라감
  final double arc;

  /// 기울기 (도)
  final double rotation;

  LibraryPlacement copyWith({
    Offset? center,
    double? width,
    double? length,
    double? arc,
    double? rotation,
  }) => LibraryPlacement(
    center: center ?? this.center,
    width: width ?? this.width,
    length: length ?? this.length,
    arc: arc ?? this.arc,
    rotation: rotation ?? this.rotation,
  );
}

/// 치아 하나의 자리 (회전 전, 사진 픽셀)
class ToothSlot {
  const ToothSlot(this.fdi, this.rect, this.kind, this.mesialRight, this.tilt);
  final int fdi;
  final Rect rect;
  final int kind; // 1 중절치 2 측절치 3 견치
  final bool mesialRight; // 가운데(정중선) 쪽이 오른쪽인지
  final double tilt; // 도
}

/// 6전치 배열 계산: 화면 왼쪽부터 13 12 11 21 22 23 (환자 오른쪽이 화면 왼쪽)
List<ToothSlot> librarySlots(LibraryPlacement pl, ToothForm f) {
  const gold = [0.618, 1.0, 1.618];
  final u = pl.width / (2 * (gold[0] + gold[1] + gold[2]));
  final wc = gold[2] * u;
  final hc = wc / f.wl * pl.length;
  final top = pl.center.dy - hc / 2;
  final incC = pl.center.dy + hc / 2;
  // 잇몸 꼭대기: 측절치가 조금 낮음 / 절단끝: 측절치·견치가 올라감 (스마일 곡선)
  final topK = {1: top, 2: top + 0.07 * hc, 3: top - 0.01 * hc};
  final incK = {
    1: incC,
    2: incC - (0.05 + 0.08 * pl.arc) * hc,
    3: incC - (0.02 + 0.16 * pl.arc) * hc,
  };
  final out = <ToothSlot>[];
  var x = pl.center.dx;
  for (final (kind, fdiR, fdiL) in const [
    (1, 11, 21),
    (2, 12, 22),
    (3, 13, 23),
  ]) {
    final w = gold[3 - kind] * u;
    final r = Rect.fromLTRB(x, topK[kind]!, x + w, incK[kind]!);
    final l = Rect.fromLTRB(
      2 * pl.center.dx - x - w,
      topK[kind]!,
      2 * pl.center.dx - x,
      incK[kind]!,
    );
    final tilt = kind == 3 ? 4.0 : (kind == 2 ? 2.0 : 0.0);
    out.add(ToothSlot(fdiL, r, kind, false, tilt)); // 화면 오른쪽 (21 22 23)
    out.add(ToothSlot(fdiR, l, kind, true, -tilt)); // 화면 왼쪽 (11 12 13)
    x += w;
  }
  // 뒤쪽(견치)부터 그려서 중절치가 맨 앞에
  out.sort((a, b) => b.kind.compareTo(a.kind));
  return out;
}

/// 치아 윤곽 (rect 안, 위 = 잇몸 쪽)
Path toothPath(Rect r, ToothForm f, int kind, bool mesialRight) {
  final w = r.width, h = r.height;
  final cw = (kind == 3 ? f.cervicalW * 0.9 : f.cervicalW) * w;
  final maxY = (kind == 3 ? 0.5 : f.maxAt) * h;
  final rm = (kind == 2 ? f.mesialR * 1.6 : f.mesialR) * w;
  final rd = (kind == 2 ? f.distalR * 1.4 : f.distalR) * w;
  final rR = mesialRight ? rm : rd, rL = mesialRight ? rd : rm;
  final x0 = (w - cw) / 2, x1 = (w + cw) / 2, yc = 0.10 * h;
  final p = Path()
    ..moveTo(x0, yc)
    ..quadraticBezierTo(w / 2, -0.07 * h, x1, yc)
    ..cubicTo(x1 + (w - x1) * 0.7, 0.2 * h, w, maxY * 0.65, w, maxY);
  if (kind == 3) {
    // 견치: 뾰족한 교두
    final tipX = mesialRight ? w * 0.56 : w * 0.44;
    p
      ..lineTo(w, h * 0.80)
      ..quadraticBezierTo(
        w * 0.98,
        h * 0.90,
        tipX + (w - tipX) * 0.35,
        h * 0.95,
      )
      ..quadraticBezierTo(tipX, h * 1.01, tipX - tipX * 0.35, h * 0.95)
      ..quadraticBezierTo(w * 0.02, h * 0.90, 0, h * 0.80);
  } else {
    final sag = f.flatEdge ? 0.0 : 0.025 * h;
    p
      ..lineTo(w, h - rR)
      ..quadraticBezierTo(w, h, w - rR, h)
      ..quadraticBezierTo(w / 2, h + sag, rL, h)
      ..quadraticBezierTo(0, h, 0, h - rL);
  }
  p
    ..lineTo(0, maxY)
    ..cubicTo(0, maxY * 0.65, x0 * 0.3, 0.2 * h, x0, yc)
    ..close();
  return p.shift(r.topLeft);
}

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

/// 치아 하나만 따로 옮기기·크기 (사진 픽셀, 배율). 크기는 잇몸 쪽 가운데를 기준으로
class ToothAdj {
  const ToothAdj({this.dx = 0, this.dy = 0, this.sw = 1, this.sh = 1});
  final double dx, dy, sw, sh;
  bool get isZero => dx == 0 && dy == 0 && sw == 1 && sh == 1;
  ToothAdj copyWith({double? dx, double? dy, double? sw, double? sh}) =>
      ToothAdj(
        dx: dx ?? this.dx,
        dy: dy ?? this.dy,
        sw: sw ?? this.sw,
        sh: sh ?? this.sh,
      );
  Rect apply(Rect r) {
    final w = r.width * sw, h = r.height * sh;
    return Rect.fromLTWH(r.center.dx - w / 2 + dx, r.top + dy, w, h);
  }
}

/// 내 라이브러리 (실제 치아 사진 · STL 렌더링 PNG): 치아 번호 → 배경 투명 이미지 (치아에 딱 맞게 자른 것)
class CustomLibrary {
  CustomLibrary(this.name, this.images);
  final String name;
  final Map<int, ui.Image> images;

  /// 이 치아의 그림 (없으면 반대쪽 같은 치아를 좌우로 뒤집어 씀)
  (ui.Image, bool)? imageFor(int fdi) {
    final im = images[fdi];
    if (im != null) return (im, false);
    final mirror = fdi < 20 ? fdi + 10 : fdi - 10;
    final m = images[mirror];
    return m == null ? null : (m, true);
  }
}

/// 실제로 그려질 치아 자리 (골라 둔 치아 · 치아별 조절 · 내 라이브러리 비율 반영)
List<ToothSlot> placedSlots(
  LibraryPlacement pl,
  ToothForm f, {
  Set<int>? teeth,
  Map<int, ToothAdj> adj = const {},
  CustomLibrary? custom,
}) {
  final out = <ToothSlot>[];
  for (final s in librarySlots(pl, f)) {
    if (teeth != null && !teeth.contains(s.fdi)) continue;
    var r = s.rect;
    final im = custom?.imageFor(s.fdi);
    if (im != null) {
      // 사진 치아는 그 사진의 가로세로 비율 그대로 (길이 배율만)
      final h = r.width * im.$1.height / im.$1.width * pl.length;
      r = Rect.fromLTWH(r.left, r.top, r.width, h);
    }
    r = (adj[s.fdi] ?? const ToothAdj()).apply(r);
    out.add(ToothSlot(s.fdi, r, s.kind, s.mesialRight, s.tilt));
  }
  return out;
}

/// 6전치 그리기 (사진 픽셀 좌표의 캔버스에). [clip] 이 있으면 그 안에서만 (입술 안쪽).
/// [teeth]: 그릴 치아만 (null = 6개 모두), [adj]: 치아별 조절, [custom]: 내 라이브러리 사진,
/// [mask]: 치아 모양만 흰색으로 (AI 결과를 이 안에서만 쓰기 위한 윤곽), [highlight]: 고른 치아 테두리
void paintLibrary(
  Canvas c,
  LibraryPlacement pl,
  ToothForm f,
  Color shade, {
  Path? clip,
  double opacity = 1,
  Set<int>? teeth,
  Map<int, ToothAdj> adj = const {},
  CustomLibrary? custom,
  bool mask = false,
  int? highlight,
}) {
  c.save();
  if (clip != null) c.clipPath(clip);
  if (opacity < 1) {
    c.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
  }
  c.translate(pl.center.dx, pl.center.dy);
  c.rotate(pl.rotation * math.pi / 180);
  c.translate(-pl.center.dx, -pl.center.dy);
  for (final s in placedSlots(pl, f, teeth: teeth, adj: adj, custom: custom)) {
    final r = s.rect;
    c.save();
    c.translate(r.center.dx, r.top);
    c.rotate(s.tilt * math.pi / 180);
    c.translate(-r.center.dx, -r.top);
    final im = custom?.imageFor(s.fdi);
    if (im != null) {
      _paintImageTooth(c, r, im.$1, im.$2, mask);
    } else {
      final path = toothPath(r, f, s.kind, s.mesialRight);
      if (mask) {
        c.drawPath(path, Paint()..color = Colors.white);
      } else {
        _paintVectorTooth(c, r, path, s, f, shade);
      }
    }
    if (highlight == s.fdi && !mask) {
      c.drawRect(
        r.inflate(r.width * 0.04),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, r.width * 0.025)
          ..color = const Color(0xFF1E88FF),
      );
    }
    c.restore();
  }
  if (opacity < 1) c.restore();
  c.restore();
}

void _paintImageTooth(Canvas c, Rect r, ui.Image im, bool flip, bool mask) {
  final src = Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble());
  final p = Paint()..filterQuality = FilterQuality.high;
  if (mask) {
    p.colorFilter = const ColorFilter.mode(Colors.white, BlendMode.srcIn);
  }
  if (flip) {
    c.save();
    c.translate(r.center.dx, 0);
    c.scale(-1, 1);
    c.translate(-r.center.dx, 0);
  }
  c.drawImageRect(im, src, r, p);
  if (flip) c.restore();
}

void _paintVectorTooth(
  Canvas c,
  Rect r,
  Path path,
  ToothSlot s,
  ToothForm f,
  Color shade,
) {
  const enamelBlue = Color(0xFFB4BECB);
  const cervYellow = Color(0xFFD9B98A);
  // 뒤쪽 치아는 조금 어둡게 (깊이감)
  final base = _mix(
    shade,
    Colors.black,
    s.kind == 3 ? 0.10 : (s.kind == 2 ? 0.04 : 0),
  );
  // 그림자 (치아 사이 깊이)
  c.drawPath(
    path.shift(Offset(0, r.height * 0.01)),
    Paint()
      ..color = const Color(0x55000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.width * 0.04),
  );
  c.save();
  c.clipPath(path);
  // ① 위→아래: 잇몸 쪽 노란기 · 몸통 · 절단끝 반투명(푸른 회색)
  c.drawRect(
    r.inflate(2),
    Paint()
      ..shader = ui.Gradient.linear(
        r.topCenter,
        r.bottomCenter,
        [
          _mix(base, cervYellow, 0.45),
          _mix(base, cervYellow, 0.12),
          base,
          _mix(base, Colors.white, 0.10),
          _mix(base, enamelBlue, 0.55),
        ],
        const [0, 0.25, 0.55, 0.82, 1],
      ),
  );
  // ② 볼록한 면 (가운데 밝고 가장자리로 갈수록 넘어감)
  c.drawRect(
    r.inflate(2),
    Paint()
      ..shader = ui.Gradient.radial(
        Offset(
          r.left + r.width * (s.mesialRight ? 0.56 : 0.44),
          r.top + r.height * 0.42,
        ),
        r.width * 0.75,
        [
          const Color(0x1AFFFFFF),
          const Color(0x00FFFFFF),
          const Color(0x33402818),
        ],
        const [0, 0.55, 1],
      ),
  );
  // ③ 좌우 굴곡 그림자 + 선각(line angle) — 견치는 바깥쪽이 더 어두움
  final outer = s.kind == 3 ? 0.42 : 0.26;
  final inner = s.kind == 3 ? 0.12 : 0.20;
  c.drawRect(
    r.inflate(2),
    Paint()
      ..shader = ui.Gradient.linear(
        r.centerLeft,
        r.centerRight,
        [
          Color.fromRGBO(60, 40, 30, s.mesialRight ? outer : inner),
          Color.fromRGBO(60, 40, 30, (s.mesialRight ? outer : inner) * 0.25),
          const Color(0x00000000),
          const Color(0x00000000),
          Color.fromRGBO(60, 40, 30, (s.mesialRight ? inner : outer) * 0.25),
          Color.fromRGBO(60, 40, 30, s.mesialRight ? inner : outer),
        ],
        const [0, 0.14, 0.24, 0.76, 0.86, 1],
      ),
  );
  // ④ 잇몸 쪽 그늘
  c.drawRect(
    Rect.fromLTWH(r.left, r.top - 2, r.width, r.height * 0.16),
    Paint()
      ..shader = ui.Gradient.linear(
        r.topCenter,
        Offset(r.center.dx, r.top + r.height * 0.16),
        [const Color(0x55603A20), const Color(0x00603A20)],
      ),
  );
  // ⑤ 법랑질 가로 결 (아주 옅게)
  final perik = Paint()
    ..color = const Color(0x06000000)
    ..strokeWidth = math.max(0.6, r.height * 0.004)
    ..maskFilter = MaskFilter.blur(
      BlurStyle.normal,
      math.max(0.5, r.height * 0.004),
    );
  for (var t = 0.25; t < 0.75; t += 0.09) {
    final y = r.top + r.height * t;
    c.drawLine(Offset(r.left, y), Offset(r.right, y + r.height * 0.01), perik);
  }
  // ⑥ 빛 반사 (세로 띠)
  final hx = s.mesialRight ? r.left + r.width * 0.58 : r.left + r.width * 0.42;
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(hx, r.top + r.height * 0.45),
        width: r.width * 0.16,
        height: r.height * 0.55,
      ),
      Radius.circular(r.width * 0.08),
    ),
    Paint()
      ..color = const Color(0x55FFFFFF)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.width * 0.06),
  );
  // ⑦ 발육엽 (젊은 형)
  if (f.mamelons && s.kind != 3) {
    for (final fx in const [0.33, 0.66]) {
      c.drawLine(
        Offset(r.left + r.width * fx, r.top + r.height * 0.62),
        Offset(r.left + r.width * fx, r.bottom - r.height * 0.03),
        Paint()
          ..color = const Color(0x22FFFFFF)
          ..strokeWidth = r.width * 0.07
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.width * 0.04),
      );
    }
  }
  // ⑧ 절단끝 헤일로 (가장자리의 얇고 밝은 선)
  c.drawLine(
    Offset(r.left + r.width * 0.12, r.bottom - r.height * 0.012),
    Offset(r.right - r.width * 0.12, r.bottom - r.height * 0.012),
    Paint()
      ..color = const Color(0x40FFFFFF)
      ..strokeWidth = math.max(1, r.height * 0.018)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.height * 0.008),
  );
  c.restore();
  // ⑨ 윤곽 (치아 사이 경계)
  c.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, r.width * 0.018)
      ..color = _mix(
        base,
        const Color(0xFF6B5040),
        0.6,
      ).withValues(alpha: 0.45),
  );
}

/// 라이브러리 미리보기 그림 (모양 고르기 칩용)
class LibraryThumbPainter extends CustomPainter {
  const LibraryThumbPainter(this.form, this.shade);
  final ToothForm form;
  final Color shade;
  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = const Color(0xFF5A2A30));
    paintLibrary(
      c,
      LibraryPlacement(
        center: Offset(s.width / 2, s.height * 0.48),
        width: s.width * 0.92,
        arc: 0.4,
      ),
      form,
      shade,
    );
  }

  @override
  bool shouldRepaint(LibraryThumbPainter o) =>
      o.form != form || o.shade != shade;
}
