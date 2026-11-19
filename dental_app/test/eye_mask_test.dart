import 'package:dental_app/privacy/eye_mask.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('눈 가리기 띠: 띠 안은 검게, 바깥은 원본 그대로', () {
    final src = img.Image(width: 200, height: 200)
      ..clear(img.ColorRgb8(230, 200, 180));
    final out = img.decodeJpg(
      drawBarsForTest(src, [
        [(40.0, 60.0), (160.0, 60.0), (160.0, 90.0), (40.0, 90.0)],
      ]),
    )!;
    expect(out.getPixel(100, 75).r, lessThan(40));
    expect(out.getPixel(100, 150).r, greaterThan(200));
  });
}
