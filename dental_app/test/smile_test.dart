import 'dart:ui' show Offset, Rect;

import 'package:dental_app/ai/smile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('입술 사이 다각형 마스크 · 넓히기 · 범위 · 입 주변 자르기', () {
    final poly = [
      const Offset(0.4, 0.6),
      const Offset(0.6, 0.6),
      const Offset(0.6, 0.66),
      const Offset(0.4, 0.66),
    ];
    final m = polygonMask(400, 300, poly);
    expect(m.getPixel(200, 189).r, 255);
    expect(m.getPixel(200, 170).r, 0);
    final b = maskBounds(m)!;
    expect(b.left, closeTo(0.4, 0.01));
    expect(b.top, closeTo(0.6, 0.01));
    expect(dilate(m, 3).getPixel(200, 177).r, 255);
    final c = mouthCrop(b);
    expect(c.contains(b.center), isTrue);
    expect(c.width, greaterThan(b.width * 2));
    expect(
      maskBounds(img.Image(width: 10, height: 10, numChannels: 1)),
      isNull,
    );
  });

  test('붙이기: 치아 영역만 AI 결과, 입술·얼굴은 원본 그대로', () {
    final src = img.Image(width: 400, height: 300)
      ..clear(img.ColorRgb8(200, 150, 130)); // 피부
    img.fillRect(
      src,
      x1: 160,
      y1: 170,
      x2: 240,
      y2: 210,
      color: img.ColorRgb8(180, 60, 70),
    ); // 입술
    img.fillRect(
      src,
      x1: 170,
      y1: 182,
      x2: 230,
      y2: 198,
      color: img.ColorRgb8(150, 140, 110),
    ); // 누런 치아
    final region = polygonMask(400, 300, [
      const Offset(170 / 400, 182 / 300),
      const Offset(230 / 400, 182 / 300),
      const Offset(230 / 400, 198 / 300),
      const Offset(170 / 400, 198 / 300),
    ]);
    const crop = Rect.fromLTRB(0.3, 0.5, 0.7, 0.8);
    // AI 가 잘라낸 부분 전체를 하얗게 바꿨다고 가정 (입술까지 잘못 칠함)
    final ai = img.Image(width: 160, height: 90)
      ..clear(img.ColorRgb8(250, 250, 245));
    final out = img.decodeJpg(
      pasteSmile((src, img.encodeJpg(ai), crop, region)),
    )!;
    expect(out.getPixel(200, 190).r, greaterThan(235)); // 치아는 하얗게
    final lip = out.getPixel(200, 174);
    expect((lip.r - 180).abs() + (lip.g - 60).abs(), lessThan(14)); // 입술 원본
    final skin = out.getPixel(130, 190);
    expect((skin.g - 150).abs(), lessThan(8)); // 피부 원본
  });
}
