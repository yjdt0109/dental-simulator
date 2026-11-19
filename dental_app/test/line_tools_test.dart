import 'dart:math' as math;

import 'package:dental_app/simulator/line_tools.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:flutter_test/flutter_test.dart';

const aspect = 0.75; // 가로 4 : 세로 3 사진

GuideLine line(
  double y0, {
  bool upper = true,
  double from = 0.2,
  double to = 0.8,
  double jitter = 0,
  int seed = 1,
}) {
  final r = math.Random(seed);
  return GuideLine(
    upper: upper,
    pts: [
      for (var x = from; x <= to + 1e-9; x += 0.01)
        Offset(
          x,
          y0 +
              0.02 * math.sin(x * 40).abs() +
              (r.nextDouble() * 2 - 1) * jitter,
        ),
    ],
  );
}

double roughness(List<Offset> p) {
  // 2차 차분 크기 = 울퉁불퉁함
  var s = 0.0;
  for (var i = 1; i < p.length - 1; i++) {
    s += (p[i + 1].dy - 2 * p[i].dy + p[i - 1].dy).abs();
  }
  return s / (p.length - 2);
}

double yAt(List<Offset> p, double x) {
  for (var i = 1; i < p.length; i++) {
    if (p[i].dx >= x) {
      final a = p[i - 1], b = p[i];
      final t = (x - a.dx) / ((b.dx - a.dx).abs() < 1e-9 ? 1 : b.dx - a.dx);
      return a.dy + (b.dy - a.dy) * t;
    }
  }
  return p.last.dy;
}

void main() {
  group('지우개', () {
    test('선 가운데를 지우면 두 개로 나뉘고, 다른 선은 그대로', () {
      final a = line(0.4), b = line(0.7, upper: false);
      final out = LineTools.erase(
        [a, b],
        [const Offset(0.5, 0.35), const Offset(0.5, 0.48)],
        0.02,
        aspect,
      );
      final uppers = out.where((l) => l.upper).toList();
      expect(uppers, hasLength(2)); // 가운데가 잘림
      expect(uppers[0].pts.last.dx, lessThan(0.49));
      expect(uppers[1].pts.first.dx, greaterThan(0.51));
      expect(out.where((l) => !l.upper).single.pts, b.pts); // 하악선은 건드리지 않음
    });
    test('선 끝을 지우면 짧아지고, 전부 지우면 없어짐', () {
      final a = line(0.4);
      final shorter = LineTools.erase(
        [a],
        [const Offset(0.8, 0.3), const Offset(0.8, 0.5)],
        0.03,
        aspect,
      );
      expect(shorter, hasLength(1));
      expect(shorter.single.pts.last.dx, lessThan(0.78));
      final gone = LineTools.erase(
        [a],
        [const Offset(0.15, 0.42), const Offset(0.85, 0.42)],
        0.05,
        aspect,
      );
      expect(gone, isEmpty);
    });
    test('지우개가 선에 안 닿으면 아무것도 안 바뀜', () {
      final a = line(0.4);
      final out = LineTools.erase([a], [const Offset(0.5, 0.9)], 0.02, aspect);
      expect(identical(out.single, a), isTrue);
    });
  });

  group('선 다듬기', () {
    test('울퉁불퉁함은 줄고, 그린 자리에서 크게 벗어나지 않음 (세로 1.2% 이내)', () {
      final drawn = line(0.4, jitter: 0.006, seed: 3);
      final sm = LineTools.smooth([drawn], aspect).single;
      // ignore: avoid_print
      print(
        '울퉁불퉁함 ${roughness(drawn.pts).toStringAsFixed(5)} → ${roughness(sm.pts).toStringAsFixed(5)}',
      );
      expect(roughness(sm.pts), lessThan(roughness(drawn.pts) / 3));
      var maxDev = 0.0;
      for (final p in sm.pts) {
        maxDev = math.max(maxDev, (p.dy - yAt(drawn.pts, p.dx)).abs());
      }
      // ignore: avoid_print
      print('그린 선과 최대 차이: 세로 ${(maxDev * 100).toStringAsFixed(2)}%');
      expect(maxDev, lessThan(0.0125 + 0.006));
      expect(sm.pts.first.dx, closeTo(drawn.pts.first.dx, 0.002)); // 시작·끝 위치 유지
      expect(sm.pts.last.dx, closeTo(drawn.pts.last.dx, 0.002));
    });
    test('가깝게 끊어진 같은 쪽 선은 하나로 이어짐, 멀면 따로', () {
      final left = line(0.4, from: 0.2, to: 0.45),
          right = line(0.4, from: 0.47, to: 0.8);
      expect(LineTools.smooth([left, right], aspect), hasLength(1));
      final far = line(0.4, from: 0.6, to: 0.8);
      expect(
        LineTools.smooth([line(0.4, from: 0.2, to: 0.4), far], aspect),
        hasLength(2),
      );
      // 상악·하악은 서로 이어지지 않음
      expect(
        LineTools.smooth([line(0.4), line(0.42, upper: false)], aspect),
        hasLength(2),
      );
    });
    test('오른쪽에서 왼쪽으로 그린 선도 정상', () {
      final rev = GuideLine(upper: true, pts: line(0.4).pts.reversed.toList());
      final sm = LineTools.smooth([rev], aspect).single;
      expect(sm.pts.first.dx, lessThan(sm.pts.last.dx));
    });
  });
}
