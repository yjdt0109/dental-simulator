import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

// =============================================================================
// 🗂 환자 기록 보관함
//   [저장 및 상담 완료] 를 누르면 태블릿에 저장:
//   patient_records/<날짜 2026-11-18>/<환자이름>/<시각_번호>/ before.jpg · after_1.jpg … · record.json
//   + 검색용 목록 index.json (이름·날짜·치료종류로 찾기)
// =============================================================================

const _week = ['월', '화', '수', '목', '금', '토', '일'];
String _two(int n) => n.toString().padLeft(2, '0');

/// 2026.11.18 (수)
String dayLabel(DateTime d) =>
    '${d.year}.${_two(d.month)}.${_two(d.day)} (${_week[d.weekday - 1]})';

/// 폴더 이름에 쓸 수 없는 글자 제거
String safeFolderName(String s) {
  final t = s.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]+'), '_');
  return t.isEmpty ? '이름없음' : t;
}

class RecordShot {
  const RecordShot({
    required this.file,
    required this.label,
    this.engine = '',
    this.check = '',
  });
  final String file; // after_1.jpg …
  final String label; // 김민수 1번 (B) …
  final String engine;
  final String check; // 무삭제 검사 결과
  Map<String, Object?> toJson() => {
    'file': file,
    'label': label,
    'engine': engine,
    'check': check,
  };
  factory RecordShot.fromJson(Map<String, dynamic> j) => RecordShot(
    file: '${j['file']}',
    label: '${j['label'] ?? ''}',
    engine: '${j['engine'] ?? ''}',
    check: '${j['check'] ?? ''}',
  );
}

class PatientRecord {
  PatientRecord({
    required this.id,
    required this.name,
    required this.savedAt,
    required this.treatments,
    required this.teeth,
    required this.shade,
    required this.memo,
    required this.photoType,
    required this.shots,
    this.clinic = '',
    this.hasSmile = false,
  });
  bool hasSmile; // 😊 미소 사진 (smile_before.jpg, 입혔으면 smile_after.jpg 도)
  final String id;
  final String name;
  final DateTime savedAt;
  final List<String> treatments;
  final List<int> teeth;
  final String? shade;
  final String memo;
  final String photoType; // 정면·스마일 …
  final List<RecordShot> shots; // 변환 결과 (마지막이 최종 After)
  final String clinic;

  String get day =>
      '${savedAt.year}-${_two(savedAt.month)}-${_two(savedAt.day)}';
  String get dayText => dayLabel(savedAt);
  String get time => '${_two(savedAt.hour)}:${_two(savedAt.minute)}';

  /// 날짜 폴더 / 환자이름 폴더 / 시각_번호
  String get folder =>
      '$day/${safeFolderName(name)}/${_two(savedAt.hour)}${_two(savedAt.minute)}_$id';

  /// 검색: 이름 · 날짜(2026.11.18 / 11.18 / 2026-11-18 / 11월 18일) · 치료종류 · 메모
  bool matches(String q) {
    final t = q.trim().toLowerCase();
    if (t.isEmpty) return true;
    final dates = [
      day,
      dayText,
      '${savedAt.year}.${savedAt.month}.${savedAt.day}',
      '${_two(savedAt.month)}.${_two(savedAt.day)}',
      '${savedAt.month}.${savedAt.day}',
      '${savedAt.month}월 ${savedAt.day}일',
      '${savedAt.month}월${savedAt.day}일',
      '${savedAt.year}${_two(savedAt.month)}${_two(savedAt.day)}',
    ];
    final hay = [
      name,
      ...dates,
      ...treatments,
      memo,
      photoType,
    ].join(' ').toLowerCase();
    // 띄어 쓴 여러 단어는 모두 들어 있어야 함 (예: "김민수 라미네이트")
    return t.split(RegExp(r'\s+')).every(hay.contains);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'savedAt': savedAt.toIso8601String(),
    'treatments': treatments,
    'teeth': teeth,
    'shade': shade,
    'memo': memo,
    'photoType': photoType,
    'clinic': clinic,
    'folder': folder,
    'hasSmile': hasSmile,
    'shots': [for (final s in shots) s.toJson()],
  };

  factory PatientRecord.fromJson(Map<String, dynamic> j) => PatientRecord(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    savedAt: DateTime.tryParse('${j['savedAt']}') ?? DateTime.now(),
    treatments: [for (final t in (j['treatments'] as List? ?? const [])) '$t'],
    teeth: [
      for (final t in (j['teeth'] as List? ?? const []))
        if (t is num) t.toInt(),
    ],
    shade: j['shade'] as String?,
    memo: '${j['memo'] ?? ''}',
    photoType: '${j['photoType'] ?? ''}',
    clinic: '${j['clinic'] ?? ''}',
    hasSmile: j['hasSmile'] == true,
    shots: [
      for (final s in (j['shots'] as List? ?? const []))
        if (s is Map) RecordShot.fromJson(s.cast<String, dynamic>()),
    ],
  );
}

/// 날짜 → 환자이름 → 기록들 (최신 날짜·최신 시각이 먼저)
typedef RecordTree =
    List<(String day, List<(String name, List<PatientRecord>)>)>;

RecordTree groupRecords(List<PatientRecord> list) {
  final byDay = <String, Map<String, List<PatientRecord>>>{};
  final sorted = [...list]..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  for (final r in sorted) {
    byDay.putIfAbsent(r.day, () => {}).putIfAbsent(r.name, () => []).add(r);
  }
  return [
    for (final d in byDay.entries)
      (d.key, [for (final n in d.value.entries) (n.key, n.value)]),
  ];
}

class PatientRecords extends ChangeNotifier {
  PatientRecords._();
  static final instance = PatientRecords._();

  @visibleForTesting
  Directory? overrideDir;

  final List<PatientRecord> records = [];
  bool _loaded = false;

  Future<Directory> root() async {
    final d =
        overrideDir ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/patient_records',
        );
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _index() async => File('${(await root()).path}/index.json');

  Future<void> load() async {
    try {
      final f = await _index();
      records.clear();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is List) {
          for (final x in j) {
            if (x is Map) records.add(PatientRecord.fromJson(x.cast()));
          }
        }
      }
    } catch (e) {
      debugPrint('records load: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<void> _saveIndex() async {
    final f = await _index();
    await f.writeAsString(jsonEncode([for (final r in records) r.toJson()]));
  }

  Future<File> file(PatientRecord r, String name) async =>
      File('${(await root()).path}/${r.folder}/$name');

  /// 저장 → 날짜/환자이름 폴더에 사진·정보
  Future<PatientRecord> add({
    required String name,
    required List<String> treatments,
    required List<int> teeth,
    required String? shade,
    required String memo,
    required String photoType,
    required Uint8List before,
    required List<
      ({Uint8List bytes, String label, String engine, String check})
    >
    results,
    String clinic = '',
    DateTime? at,
    Uint8List? smile,
    Uint8List? smileAfter,
  }) async {
    await ensureLoaded();
    final now = at ?? DateTime.now();
    final rec = PatientRecord(
      id: '${now.millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? '이름없음' : name.trim(),
      savedAt: now,
      treatments: treatments,
      teeth: teeth,
      shade: shade,
      memo: memo.trim(),
      photoType: photoType,
      clinic: clinic,
      hasSmile: smile != null,
      shots: [
        for (var i = 0; i < results.length; i++)
          RecordShot(
            file: 'after_${i + 1}.jpg',
            label: results[i].label,
            engine: results[i].engine,
            check: results[i].check,
          ),
      ],
    );
    final dir = Directory('${(await root()).path}/${rec.folder}');
    await dir.create(recursive: true);
    await File('${dir.path}/before.jpg')
        .writeAsBytes(await compute(_shrink, before));
    for (var i = 0; i < results.length; i++) {
      await File('${dir.path}/${rec.shots[i].file}')
          .writeAsBytes(await compute(_shrink, results[i].bytes));
    }
    if (smile != null) {
      await File('${dir.path}/smile_before.jpg')
          .writeAsBytes(await compute(_shrink, smile));
    }
    if (smile != null && smileAfter != null) {
      await File('${dir.path}/smile_after.jpg')
          .writeAsBytes(await compute(_shrink, smileAfter));
    }
    await File(
      '${dir.path}/record.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(rec.toJson()));
    records.insert(0, rec);
    await _saveIndex();
    notifyListeners();
    return rec;
  }

  /// 😊 미소 사진을 이미 저장된 그 환자 기록 폴더에 넣기 (올릴 때 · 입힐 때마다 덮어씀)
  Future<PatientRecord?> saveSmile(
    String recordId,
    Uint8List smile, {
    Uint8List? after,
  }) async {
    await ensureLoaded();
    final r = records.where((x) => x.id == recordId).firstOrNull;
    if (r == null) return null;
    final dir = Directory('${(await root()).path}/${r.folder}');
    if (!await dir.exists()) await dir.create(recursive: true);
    await File('${dir.path}/smile_before.jpg')
        .writeAsBytes(await compute(_shrink, smile));
    final af = File('${dir.path}/smile_after.jpg');
    if (after != null) {
      await af.writeAsBytes(await compute(_shrink, after));
    } else if (await af.exists()) {
      await af.delete(); // 새 미소 사진 → 예전 결과는 맞지 않음
    }
    r.hasSmile = true;
    await File('${dir.path}/record.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(r.toJson()));
    await _saveIndex();
    notifyListeners();
    return r;
  }

  Future<void> remove(PatientRecord r) async {
    records.removeWhere((x) => x.id == r.id);
    try {
      final d = Directory('${(await root()).path}/${r.folder}');
      if (await d.exists()) await d.delete(recursive: true);
      // 비어 버린 환자이름·날짜 폴더 정리
      for (final p in [d.parent, d.parent.parent]) {
        if (await p.exists() && await p.list().isEmpty) await p.delete();
      }
    } catch (_) {}
    await _saveIndex();
    notifyListeners();
  }

  /// 검색 (이름·날짜·치료종류 아무거나 + 날짜·치료 필터)
  List<PatientRecord> search({String query = '', DateTime? day, String? tx}) =>
      [
        for (final r in records)
          if (r.matches(query) &&
              (day == null ||
                  (r.savedAt.year == day.year &&
                      r.savedAt.month == day.month &&
                      r.savedAt.day == day.day)) &&
              (tx == null || r.treatments.contains(tx)))
            r,
      ]..sort((a, b) => b.savedAt.compareTo(a.savedAt));
}

/// 긴 변 1600px JPEG
Uint8List _shrink(Uint8List b) {
  final d = img.decodeImage(b);
  if (d == null) return b;
  final o = img.bakeOrientation(d);
  final k = 1600 / (o.width > o.height ? o.width : o.height);
  final r = k < 1
      ? img.copyResize(
          o,
          width: (o.width * k).round(),
          height: (o.height * k).round(),
        )
      : o;
  return img.encodeJpg(r, quality: 88);
}

/// 기록 → 시뮬레이터로 불러올 내용 (파일 읽기)
Future<
  ({
    Uint8List before,
    List<({Uint8List bytes, String engine, String check})> results,
    Uint8List? smile,
    Uint8List? smileAfter,
  })?
>
readRecordFiles(PatientRecord r) async {
  final s = PatientRecords.instance;
  Future<Uint8List?> read(String f) async {
    final file = await s.file(r, f);
    return await file.exists() ? file.readAsBytes() : null;
  }

  final before = await read('before.jpg');
  if (before == null) return null;
  final results = <({Uint8List bytes, String engine, String check})>[];
  for (final sh in r.shots) {
    final b = await read(sh.file);
    if (b != null) results.add((bytes: b, engine: sh.engine, check: sh.check));
  }
  return (
    before: before,
    results: results,
    smile: r.hasSmile ? await read('smile_before.jpg') : null,
    smileAfter: r.hasSmile ? await read('smile_after.jpg') : null,
  );
}
