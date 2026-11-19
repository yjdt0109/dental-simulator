import 'dart:typed_data';

import 'package:dental_app/simulator/sim_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PatientPhoto photo() => PatientPhoto(
  id: 'u1',
  name: '김민수',
  type: '직접 등록',
  time: '방금',
  beforeBytes: Uint8List.fromList([0]),
  imageSize: const Size(10, 10),
);
Uint8List b(int v) => Uint8List.fromList([v]);

void main() {
  test('변환 번호·이전으로·다시 돌아가기·이전으로 후 변환하면 뒤의 번호 삭제', () {
    final p = photo();
    p.remember('After 변환');
    p.addResult(b(1), 'k1');
    p.editing = false;
    p.remember('After 변환');
    p.addResult(b(2), 'k2');
    expect(p.results.length, 2);
    expect(p.compare, [0, 2]); // 새 결과를 원본과 비교
    expect(p.afterBytes, b(2));

    // 2번이 맘에 안 들어 이전으로 → 1번
    expect(p.undo(), 'After 변환');
    expect(p.results.length, 1);
    expect(p.afterBytes, b(1));
    expect(p.future, hasLength(1));
    // 다시 돌아가기 → 2번
    expect(p.redo(), 'After 변환');
    expect(p.results.length, 2);
    expect(p.afterBytes, b(2));
    expect(p.future, isEmpty);
    // 다시 이전으로 → 1번, 그 상태에서 새로 변환하면 예전 2번은 없어지고 새 결과가 2번
    p.undo();
    p.remember('After 변환');
    p.addResult(b(9), 'k9');
    expect(p.results.length, 2);
    expect(p.results[1].bytes, b(9));
    expect(p.future, isEmpty); // 다시 돌아가기 없어짐
    // 끝까지 이전으로 → 원본만
    p.undo();
    p.undo();
    expect(p.results, isEmpty);
    expect(p.afterBytes, isNull);
  });

  test('비교 사진 고르기: 1~2장, 3번째를 고르면 가장 먼저 고른 것이 빠짐', () {
    final p = photo();
    p.addResult(b(1), 'k1');
    p.addResult(b(2), 'k2');
    p.addResult(b(3), 'k3');
    expect(p.compare, [0, 3]);
    p.toggleSel(1); // 원본(먼저 고름)이 빠지고 1번 추가 → 1번 vs 3번
    expect(p.compare, [1, 3]);
    p.toggleSel(3); // 체크 해제 → 1번만 크게
    expect(p.compare, [1]);
    p.toggleSel(1); // 마지막 1장은 해제 안 됨
    expect(p.compare, [1]);
    p.toggleSel(0); // 원본 추가 → 원본 vs 1번 (작은 번호가 왼쪽)
    expect(p.compare, [0, 1]);
    expect(p.bytesOf(1), b(1));
    expect(p.bytesOf(0), b(0));
  });
}
