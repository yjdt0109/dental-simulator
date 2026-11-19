import 'package:flutter/services.dart';

// -----------------------------------------------------------------------------
// 전화번호 자동 하이픈 (02-1234-5678 / 031-123-4567 / 010-1234-5678 / 1588-1234)
// -----------------------------------------------------------------------------
String formatKrPhone(String d) {
  if (d.startsWith('02')) {
    if (d.length <= 2) return d;
    if (d.length <= 5) return '02-${d.substring(2)}';
    if (d.length <= 9) return '02-${d.substring(2, 5)}-${d.substring(5)}';
    return '02-${d.substring(2, 6)}-${d.substring(6)}';
  }
  if (RegExp(r'^1[5-8]').hasMatch(d)) {
    // 병원 대표번호 (15XX, 16XX, 18XX)
    if (d.length <= 4) return d;
    return '${d.substring(0, 4)}-${d.substring(4)}';
  }
  if (d.length <= 3) return d;
  if (d.length <= 6) return '${d.substring(0, 3)}-${d.substring(3)}';
  if (d.length <= 10) {
    return '${d.substring(0, 3)}-${d.substring(3, 6)}-${d.substring(6)}';
  }
  return '${d.substring(0, 3)}-${d.substring(3, 7)}-${d.substring(7)}';
}

int _maxPhoneDigits(String d) {
  if (d.startsWith('02')) return 10;
  if (RegExp(r'^1[5-8]').hasMatch(d)) return 8;
  return 11;
}

String? validateKrPhone(String? v, {String empty = '치과 연락처를 입력해 주세요.'}) {
  final d = (v ?? '').replaceAll(RegExp(r'\D'), '');
  if (d.isEmpty) return empty;
  final ok = d.startsWith('02')
      ? (d.length == 9 || d.length == 10)
      : RegExp(r'^1[5-8]').hasMatch(d)
      ? d.length == 8
      : d.startsWith('0') && (d.length == 10 || d.length == 11);
  return ok ? null : '전화번호를 다시 확인해 주세요. (예: 02-1234-5678)';
}

// 사업자등록번호 자동 하이픈 (000-00-00000)
String formatBizNo(String d) {
  if (d.length <= 3) return d;
  if (d.length <= 5) return '${d.substring(0, 3)}-${d.substring(3)}';
  return '${d.substring(0, 3)}-${d.substring(3, 5)}-${d.substring(5)}';
}

class BizNoFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var d = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (d.length > 10) d = d.substring(0, 10);
    final text = formatBizNo(d);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class KrPhoneFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var d = newValue.text.replaceAll(RegExp(r'\D'), '');
    final max = _maxPhoneDigits(d);
    if (d.length > max) d = d.substring(0, max);
    final text = formatKrPhone(d);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
