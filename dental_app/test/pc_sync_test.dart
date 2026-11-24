import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dental_app/qa/qa_remote.dart';
import 'package:dental_app/records/records.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List jpg(int r) => Uint8List.fromList(
  img.encodeJpg(
    img.Image(width: 40, height: 30)..clear(img.ColorRgb8(r, 90, 90)),
  ),
);

void main() {
  test('💾 PC 폴더 저장: 환자이름 › 날짜 상담 폴더, 원본·결과·미소·상담내용', () async {
    final tmp = await Directory.systemTemp.createTemp('bna_pcsync');
    PatientRecords.instance
      ..overrideDir = tmp
      ..records.clear();
    final r = await PatientRecords.instance.add(
      name: '홍/길동',
      treatments: const ['라미네이트', '미백'],
      teeth: const [11, 21],
      shade: 'A1',
      memo: '다음 주',
      photoType: '정면',
      before: jpg(100),
      results: [(bytes: jpg(200), label: '홍길동 1번 (B)', engine: 'B', check: '')],
      smile: jpg(150),
      smileAfter: jpg(240),
      at: DateTime(2026, 11, 24, 14, 5),
    );
    final f = pcSyncFolder(r);
    expect(f, ['홍_길동', '2026-11-24 14시05분 상담 (라미네이트, 미백)']);
    final p = await pcSyncPayload(r);
    final names = [for (final x in p['files']! as List) (x as Map)['n']];
    expect(names, [
      '원본 (치료 전).jpg',
      '1번 시뮬레이션 (B).jpg',
      '미소 (치료 전).jpg',
      '미소 미리보기 (시뮬레이션).jpg',
    ]);
    final first = (p['files']! as List).first as Map;
    expect(img.decodeJpg(base64Decode(first['b'] as String)), isNotNull);
    expect(p['memo'] as String, contains('치료 부위: #11 #21'));
    expect(p['memo'] as String, contains('치료완성'));
    expect(p['sig'], '1|true');
  });
}
