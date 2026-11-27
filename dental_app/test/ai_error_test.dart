import 'package:dental_app/ai/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('App Check 오류(firebase_app_check · Too many attempts)는 토큰 등록 안내로', () {
    final e = AiError.from(
      Exception('[firebase_app_check/unknown] Too many attempts.'),
    );
    expect(e.message, contains('App Check'));
    expect(e.message, contains('디버그 토큰'));
    expect(e.message, contains('껐다 켜'));
  });
  test('App Check 일반 오류는 잠시 막힘 문구 없이', () {
    final e = AiError.from(Exception('UNAUTHENTICATED'));
    expect(e.message, contains('디버그 토큰'));
    expect(e.message, isNot(contains('껐다 켜')));
  });
}
