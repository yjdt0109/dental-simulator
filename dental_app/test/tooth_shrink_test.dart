import 'dart:typed_data';
import 'dart:ui';

import 'package:dental_app/ai/tooth_select.dart';
import 'package:dental_app/simulator/resize_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('➖ 치아 절단끝 줄이기: 아래쪽이 입 안 어두운 색으로 채워지고, 위쪽 치아는 그대로', () {
    // 어두운 입 안(30) 위에 흰 치아 (40..80 x 20..100)
    final src = img.Image(width: 120, height: 140)
      ..clear(img.ColorRgb8(30, 20, 20));
    img.fillRect(
      src,
      x1: 40,
      y1: 20,
      x2: 80,
      y2: 100,
      color: img.ColorRgb8(240, 240, 230),
    );
    final mask = img.Image(width: 120, height: 140, numChannels: 1);
    img.fillRect(
      mask,
      x1: 40,
      y1: 20,
      x2: 80,
      y2: 100,
      color: img.ColorRgb8(255, 255, 255),
    );
    final box = const Rect.fromLTRB(40, 20, 81, 101);
    final out = scaleToothMasked(src, mask, box, down: -24); // 약 30% 짧게
    expect(out.getPixel(60, 95).r, lessThan(80)); // 원래 절단끝 자리 → 어두움
    expect(out.getPixel(60, 85).r, lessThan(80));
    expect(out.getPixel(60, 40).r, greaterThan(220)); // 치아 위쪽은 치아
    expect(out.getPixel(60, 70).r, greaterThan(200)); // 줄어든 치아 끝 근처까지 치아
    expect(out.getPixel(10, 10).r, 30); // 바깥은 그대로
  });

  test('➖ 줄이기 잔상 없음: AI 윤곽이 실제 치아보다 작아도 원래 절단끝 자국이 안 남음', () {
    final src = img.Image(width: 120, height: 160)
      ..clear(img.ColorRgb8(30, 20, 20));
    img.fillRect(
      src,
      x1: 40,
      y1: 20,
      x2: 80,
      y2: 100,
      color: img.ColorRgb8(240, 240, 230),
    );
    // 윤곽(마스크)이 실제 치아보다 3px 작음
    final mask = img.Image(width: 120, height: 160, numChannels: 1);
    img.fillRect(
      mask,
      x1: 43,
      y1: 23,
      x2: 77,
      y2: 97,
      color: img.ColorRgb8(255, 255, 255),
    );
    final box = const Rect.fromLTRB(43, 23, 78, 98);
    final out = scaleToothMasked(src, mask, box, down: -20);
    for (final y in [90, 95, 98, 100]) {
      for (final x in [45, 60, 75]) {
        expect(out.getPixel(x, y).r, lessThan(90), reason: '($x,$y) 잔상');
      }
    }
    expect(out.getPixel(60, 50).r, greaterThan(220));
  });

  test('크기 조절 세션: 줄이기 −30% 까지 허용', () {
    final s = ResizeSession(
      image: Uint8List(0),
      teeth: [
        (
          label: '상악 1',
          box: const Rect.fromLTRB(0.4, 0.2, 0.6, 0.6),
          upper: true,
        ),
      ],
    );
    for (var i = 0; i < 20; i++) {
      s.stepTooth(0, GrowSide.down, -1);
    }
    expect(s.pct(0, GrowSide.down), -30);
    expect(s.stepTooth(0, GrowSide.down, -1), isFalse);
  });
}
