import 'dart:math' as math;

import 'package:flutter/painting.dart' show Offset;

import 'sim_models.dart' show GuideLine;

/// 서비컬 라인 편집 도구 (지우개 · 선 다듬기)
///
/// 좌표는 사진 기준 0~1. [aspect] = 사진 세로 / 가로 (거리 계산을 실제 모양대로 하기 위함)
class LineTools {
  LineTools._();

  static double _dist(Offset a, Offset b, double aspect) {
    final dx = a.dx - b.dx, dy = (a.dy - b.dy) * aspect;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _distToSeg(Offset p, Offset a, Offset b, double aspect) {
    final ax = a.dx, ay = a.dy * aspect, bx = b.dx, by = b.dy * aspect;
    final px = p.dx, py = p.dy * aspect;
    final vx = bx - ax, vy = by - ay;
    final len2 = vx * vx + vy * vy;
    final t = len2 == 0
        ? 0.0
        : (((px - ax) * vx + (py - ay) * vy) / len2).clamp(0.0, 1.0);
    final cx = ax + vx * t - px, cy = ay + vy * t - py;
    return math.sqrt(cx * cx + cy * cy);
  }

  /// 촘촘하게 다시 찍기 (지우개가 선 사이를 건너뛰지 않게)
  static List<Offset> _dense(List<Offset> pts, double step, double aspect) {
    if (pts.length < 2) return [...pts];
    final out = <Offset>[pts.first];
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final n = math.max(1, (_dist(a, b, aspect) / step).ceil());
      for (var k = 1; k <= n; k++) {
        out.add(Offset.lerp(a, b, k / n)!);
      }
    }
    return out;
  }

  /// 지우개: [path] 를 따라 반지름 [r](사진 가로 기준 비율) 안에 있는 선 부분만 지움.
  /// 가운데를 지우면 선이 두 개로 나뉨. 사진은 그대로.
  static List<GuideLine> erase(
    List<GuideLine> lines,
    List<Offset> path,
    double r,
    double aspect,
  ) {
    if (path.isEmpty || lines.isEmpty) return lines;
    final segs = path.length == 1
        ? [(path.first, path.first)]
        : [for (var i = 1; i < path.length; i++) (path[i - 1], path[i])];
    bool hit(Offset p) =>
        segs.any((s) => _distToSeg(p, s.$1, s.$2, aspect) <= r);
    final out = <GuideLine>[];
    for (final l in lines) {
      // 지우개에 닿는 선만 촘촘하게 나눠서 자름 (안 닿은 선은 그대로)
      final dense = _dense(l.pts, r / 3, aspect);
      if (!dense.any(hit)) {
        out.add(l);
        continue;
      }
      var cur = <Offset>[];
      for (final p in dense) {
        if (hit(p)) {
          if (cur.length > 1) {
            out.add(
              GuideLine(
                upper: l.upper,
                incisal: l.incisal,
                pts: _thin(cur, aspect),
              ),
            );
          }
          cur = [];
        } else {
          cur.add(p);
        }
      }
      if (cur.length > 1) {
        out.add(
          GuideLine(
            upper: l.upper,
            incisal: l.incisal,
            pts: _thin(cur, aspect),
          ),
        );
      }
    }
    return out;
  }

  /// 점이 너무 많으면 줄이기 (모양은 거의 그대로)
  static List<Offset> _thin(List<Offset> pts, double aspect) {
    if (pts.length <= 3) return pts;
    final out = <Offset>[pts.first];
    for (var i = 1; i < pts.length - 1; i++) {
      if (_dist(out.last, pts[i], aspect) >= 0.004) out.add(pts[i]);
    }
    out.add(pts.last);
    return out;
  }

  /// 선 다듬기: 손떨림만 부드럽게 펴고, 가까이 끊어진 같은 쪽(상악/하악) 선은 하나로 이어 줌.
  /// 그린 위치에서 크게 벗어나지 않음 (최대 [maxShift] = 사진 세로의 1.2%).
  static List<GuideLine> smooth(
    List<GuideLine> lines,
    double aspect, {
    double maxShift = 0.012,
  }) {
    final out = <GuideLine>[];
    for (final (upper, incisal) in [
      (true, false),
      (false, false),
      (true, true),
      (false, true),
    ]) {
      final group = [
        for (final l in lines)
          if (l.upper == upper && l.incisal == incisal && l.pts.length > 1)
            _leftToRight(l),
      ]..sort((a, b) => a.pts.first.dx.compareTo(b.pts.first.dx));
      // 끝과 끝이 가까우면(가로 4% 이내) 이어 붙이기
      final joined = <List<Offset>>[];
      for (final l in group) {
        if (joined.isNotEmpty &&
            _dist(joined.last.last, l.pts.first, aspect) < 0.04) {
          joined.last.addAll(l.pts);
        } else {
          joined.add([...l.pts]);
        }
      }
      for (final pts in joined) {
        out.add(
          GuideLine(
            upper: upper,
            incisal: incisal,
            pts: _smoothOne(pts, aspect, maxShift),
          ),
        );
      }
    }
    return out;
  }

  static GuideLine _leftToRight(GuideLine l) => l.pts.first.dx <= l.pts.last.dx
      ? l
      : GuideLine(
          upper: l.upper,
          incisal: l.incisal,
          pts: l.pts.reversed.toList(),
        );

  static List<Offset> _smoothOne(
    List<Offset> pts,
    double aspect,
    double maxShift,
  ) {
    // 1) 길이 기준으로 고르게 다시 찍기 (가로 0.5% 간격)
    const step = 0.005;
    final dense = _dense(pts, step / 4, aspect);
    final even = <Offset>[dense.first];
    var acc = 0.0;
    for (var i = 1; i < dense.length; i++) {
      acc += _dist(dense[i - 1], dense[i], aspect);
      if (acc >= step) {
        even.add(dense[i]);
        acc = 0;
      }
    }
    if ((even.last - dense.last).distance > 1e-6) even.add(dense.last);
    if (even.length < 5) return pts;
    // 2) 가우시안으로 부드럽게 (치아마다 둥근 잇몸선 모양은 남도록 시그마 = 가로 1.5%)
    const sigma = 3.0; // 점 3개 = 1.5%
    const rad = 9;
    final wts = [
      for (var k = -rad; k <= rad; k++)
        math.exp(-(k * k) / (2 * sigma * sigma)),
    ];
    Offset at(int i) {
      // 양 끝은 거울처럼 접어서 끝이 짧아지지 않게
      final n = even.length;
      if (i < 0) return even[0] * 2 - even[-i];
      if (i >= n) return even[n - 1] * 2 - even[2 * (n - 1) - i];
      return even[i];
    }

    final sm = <Offset>[];
    for (var i = 0; i < even.length; i++) {
      var sx = 0.0, sy = 0.0, sw = 0.0;
      for (var k = -rad; k <= rad; k++) {
        final p = at(i + k), w = wts[k + rad];
        sx += p.dx * w;
        sy += p.dy * w;
        sw += w;
      }
      var q = Offset(sx / sw, sy / sw);
      // 3) 그린 자리에서 너무 멀어지지 않게
      final d = q - even[i];
      if (d.dy.abs() > maxShift) {
        q = Offset(q.dx, even[i].dy + maxShift * d.dy.sign);
      }
      if (d.dx.abs() > maxShift) {
        q = Offset(even[i].dx + maxShift * d.dx.sign, q.dy);
      }
      sm.add(
        Offset(
          (q.dx.clamp(0.0, 1.0) * 1000).round() / 1000,
          (q.dy.clamp(0.0, 1.0) * 1000).round() / 1000,
        ),
      );
    }
    sm[0] = Offset(
      (even.first.dx * 1000).round() / 1000,
      sm[0].dy,
    ); // 시작·끝 가로 위치는 그대로
    sm[sm.length - 1] = Offset(
      (even.last.dx * 1000).round() / 1000,
      sm.last.dy,
    );
    return sm;
  }
}
