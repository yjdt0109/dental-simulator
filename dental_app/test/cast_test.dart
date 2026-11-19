import 'package:dental_app/cast/cast_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('QR 내용에서 방 번호 꺼내기', () {
    expect(
      CastService.roomFromQr(
        'https://bna.netlify.app/#pair-ABCDEFGHJKLMNPQRSTUVWXYZ',
      ),
      'ABCDEFGHJKLMNPQRSTUVWXYZ',
    );
    expect(CastService.roomFromQr('pair-short'), isNull); // 너무 짧으면 거부
    expect(CastService.roomFromQr('https://example.com'), isNull);
  });
}
