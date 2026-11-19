import 'package:dental_app/utils/formatters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('전화번호 하이픈', () {
    expect(formatKrPhone('021234567'), '02-123-4567');
    expect(formatKrPhone('0212345678'), '02-1234-5678');
    expect(formatKrPhone('0311234567'), '031-123-4567');
    expect(formatKrPhone('01012345678'), '010-1234-5678');
    expect(formatKrPhone('15881234'), '1588-1234');
    expect(validateKrPhone('02-1234-5678'), isNull);
    expect(validateKrPhone('1588-1234'), isNull);
    expect(validateKrPhone('02-12'), isNotNull);
  });
}
