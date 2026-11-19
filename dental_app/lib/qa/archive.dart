import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../simulator/sim_models.dart' show kTreatments;

// =============================================================================
// 📚 프롬프트 보관함: 합격한 황금 프롬프트 + 3종 비교 사진을 치료별 폴더로 자동 정리
//   이 태블릿의 앱 전용 폴더에 저장 (사진은 긴 변 1280px JPEG)
// =============================================================================

const kAllFolder = '전체 보기';
const kUnsorted = '미분류';

/// 폴더 목록: 전체 보기 + 우측 패널의 모든 치료 항목
List<String> get archiveFolders => [kAllFolder, ...kTreatments];

class ArchiveCase {
  ArchiveCase({
    required this.id,
    required this.title,
    required this.treatments,
    required this.tries,
    required this.passed,
    required this.score,
    required this.date,
    required this.engine,
    required this.strength,
    required this.request,
    required this.prompt,
    this.timeline = '',
    this.criteria = const {},
    this.selfScored = false,
  });
  final bool selfScored; // 정답지 없이 AI 자체 평가

  final String id;
  String title;
  final List<String> treatments; // 테스트 당시 선택된 치료 → 자동 폴더
  final int tries; // 합격까지 시도 횟수 (불합격이면 전체 시도 횟수)
  final bool passed;
  final int score;
  final DateTime date;
  final String engine; // '옵션 A' …
  final int strength; // 권장 적용 강도
  final String request; // 채택된 '추가 요청' (기본값으로 적용할 부분)
  final String prompt; // 최종 채택된 전체 지시문
  final String timeline; // 1회차 74점 ➡️ 2회차 83점 ➡️ …
  final Map<String, int> criteria; // c1~c4

  /// 저장 위치 폴더들 (치료가 여러 개면 각 폴더에 모두 보임)
  List<String> get folders => treatments.isEmpty ? [kUnsorted] : treatments;

  String get badge =>
      passed ? '$tries회차 만에 합격 · $score점' : '$tries회 시도 · 최고 $score점';

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'treatments': treatments,
    'tries': tries,
    'passed': passed,
    'score': score,
    'date': date.toIso8601String(),
    'engine': engine,
    'strength': strength,
    'request': request,
    'prompt': prompt,
    'timeline': timeline,
    'criteria': criteria,
    'selfScored': selfScored,
  };

  factory ArchiveCase.fromJson(Map<String, dynamic> j) => ArchiveCase(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    treatments: [for (final t in (j['treatments'] as List? ?? const [])) '$t'],
    tries: (j['tries'] as num?)?.toInt() ?? 0,
    passed: j['passed'] == true,
    score: (j['score'] as num?)?.toInt() ?? 0,
    date: DateTime.tryParse('${j['date']}') ?? DateTime.now(),
    engine: j['engine'] as String? ?? '',
    strength: (j['strength'] as num?)?.toInt() ?? 90,
    request: j['request'] as String? ?? '',
    prompt: j['prompt'] as String? ?? '',
    timeline: j['timeline'] as String? ?? '',
    criteria: {
      for (final e in ((j['criteria'] as Map?) ?? const {}).entries)
        '${e.key}': (e.value as num).toInt(),
    },
    selfScored: j['selfScored'] == true,
  );
}

class PromptArchive extends ChangeNotifier {
  PromptArchive._();
  static final PromptArchive instance = PromptArchive._();

  /// 시험에서 임시 폴더로 바꿀 때
  @visibleForTesting
  Directory? overrideDir;

  final List<ArchiveCase> cases = [];
  bool loaded = false;

  Future<Directory> _dir() async {
    final base = overrideDir ?? await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/prompt_archive');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _index() async => File('${(await _dir()).path}/index.json');

  Future<void> load() async {
    try {
      final f = await _index();
      cases
        ..clear()
        ..addAll(
          await f.exists()
              ? [
                  for (final j in jsonDecode(await f.readAsString()) as List)
                    ArchiveCase.fromJson(j as Map<String, dynamic>),
                ]
              : const <ArchiveCase>[],
        );
      cases.sort((a, b) => b.date.compareTo(a.date));
    } catch (e) {
      debugPrint('archive load: $e');
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _saveIndex() async {
    final f = await _index();
    await f.writeAsString(jsonEncode([for (final c in cases) c.toJson()]));
  }

  /// 폴더별 케이스
  List<ArchiveCase> inFolder(String folder) => folder == kAllFolder
      ? cases
      : cases.where((c) => c.folders.contains(folder)).toList();

  int count(String folder) => inFolder(folder).length;

  /// 사진 파일 경로: kind = original / target / result
  Future<File> imageFile(String id, String kind) async =>
      File('${(await _dir()).path}/$id/$kind.jpg');

  /// 저장 (폴더는 치료 종류로 자동)
  Future<ArchiveCase> add({
    required String title,
    required List<String> treatments,
    required int tries,
    required bool passed,
    required int score,
    required String engine,
    required int strength,
    required String request,
    required String prompt,
    required String timeline,
    required Map<String, int> criteria,
    required Uint8List original,
    required Uint8List? target,
    bool selfScored = false,
    required Uint8List result,
  }) async {
    final id = '${DateTime.now().millisecondsSinceEpoch}';
    final dir = Directory('${(await _dir()).path}/$id');
    await dir.create(recursive: true);
    for (final (kind, bytes) in [
      ('original', original),
      ('target', target),
      ('result', result),
    ]) {
      if (bytes == null) continue; // 정답지 없이 자체 평가
      await File('${dir.path}/$kind.jpg')
          .writeAsBytes(await compute(_shrink, bytes));
    }
    final c = ArchiveCase(
      id: id,
      title: title,
      treatments: [
        for (final t in kTreatments)
          if (treatments.contains(t)) t,
      ],
      tries: tries,
      passed: passed,
      score: score,
      date: DateTime.now(),
      engine: engine,
      strength: strength,
      request: request,
      prompt: prompt,
      timeline: timeline,
      criteria: criteria,
      selfScored: selfScored,
    );
    cases.insert(0, c);
    await _saveIndex();
    notifyListeners();
    return c;
  }

  Future<void> remove(ArchiveCase c) async {
    cases.remove(c);
    try {
      final d = Directory('${(await _dir()).path}/${c.id}');
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
    await _saveIndex();
    notifyListeners();
  }

  /// 백업 내용: 파일 이름(확장자 없음), HTML 리포트, JSON
  Future<({String name, String html, String json})> backupOf(
    ArchiveCase c,
  ) async {
    final imgs = <String, String>{};
    for (final k in ['original', 'target', 'result']) {
      final f = await imageFile(c.id, k);
      imgs[k] = await f.exists() ? base64Encode(await f.readAsBytes()) : '';
    }
    final safe = c.title.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return (
      name: 'BnA_${safe}_${c.id}',
      html: buildReportHtml(c, imgs),
      json: const JsonEncoder.withIndent('  ')
          .convert({...c.toJson(), 'images_base64_jpeg': imgs}),
    );
  }

  /// 백업 파일 2개(HTML 리포트 + JSON) 만들기 → 경로
  Future<List<String>> exportCase(ArchiveCase c) async {
    final out = Directory(
      '${(await getTemporaryDirectoryOr()).path}/bna_backup',
    );
    if (!await out.exists()) await out.create(recursive: true);
    final b = await backupOf(c);
    final json = File('${out.path}/${b.name}.json');
    await json.writeAsString(b.json);
    final html = File('${out.path}/${b.name}.html');
    await html.writeAsString(b.html);
    return [html.path, json.path];
  }

  @visibleForTesting
  Directory? overrideTemp;
  Future<Directory> getTemporaryDirectoryOr() async =>
      overrideTemp ?? await getTemporaryDirectory();
}

Uint8List _shrink(Uint8List b) {
  final d = img.decodeImage(b);
  if (d == null) return b;
  final o = img.bakeOrientation(d);
  final k = 1280 / (o.width > o.height ? o.width : o.height);
  final r = k < 1
      ? img.copyResize(
          o,
          width: (o.width * k).round(),
          height: (o.height * k).round(),
        )
      : o;
  return img.encodeJpg(r, quality: 85);
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 3종 비교 리포트 (한 파일, 사진 포함 → 컴퓨터에서 바로 열림)
String buildReportHtml(ArchiveCase c, Map<String, String> imgs) {
  String fig(String k, String label) => (imgs[k] ?? '').isEmpty
      ? '<figure><div style="aspect-ratio:4/3;border-radius:10px;background:#EEF2F7;display:grid;place-items:center;color:#66768C">정답지 없음 (AI 자체 평가)</div><figcaption>${_esc(label)}</figcaption></figure>'
      : '<figure><img src="data:image/jpeg;base64,${imgs[k]}" alt="${_esc(label)}"><figcaption>${_esc(label)}</figcaption></figure>';
  final crit = c.criteria;
  return '''<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_esc(c.title)} · B&amp;A 프롬프트 보관함</title>
<style>body{font-family:"Noto Sans KR","Malgun Gothic",sans-serif;margin:24px;color:#17243A;background:#F3F6FA}
.card{background:#fff;border:1px solid #DDE4EE;border-radius:16px;padding:20px;max-width:1100px;margin:auto}
h1{margin:0 0 6px;color:#004C99;font-size:22px}.tags span{display:inline-block;background:#E8F1FB;color:#004C99;border-radius:99px;padding:2px 10px;margin:2px;font-size:13px;font-weight:700}
.badge{background:${c.passed ? '#E6F6F4;color:#16A394' : '#FFF4E5;color:#B25E00'};border-radius:10px;padding:6px 12px;font-weight:800;display:inline-block;margin:8px 0}
.imgs{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px;margin:14px 0}figure{margin:0}img{width:100%;border-radius:10px;background:#0D1622}
figcaption{font-weight:700;font-size:14px;margin-top:4px}pre{white-space:pre-wrap;background:#F7FAFE;border:1px solid #DDE4EE;border-radius:10px;padding:12px;font-size:13px;line-height:1.6}
table{border-collapse:collapse}td{padding:4px 12px 4px 0;font-size:14px}</style></head><body><div class="card">
<h1>${_esc(c.title)}</h1><div class="tags">${c.folders.map((t) => '<span>${_esc(t)}</span>').join()}</div>
<div class="badge">${_esc(c.badge)}</div>${c.selfScored ? ' <span style="color:#66768C;font-size:13px">· 정답지 없이 AI 자체 평가 점수</span>' : ''}
<table><tr><td>저장 날짜</td><td>${c.date.toString().substring(0, 16)}</td></tr><tr><td>엔진</td><td>${_esc(c.engine)}</td></tr>
<tr><td>권장 적용 강도</td><td>${c.strength}%</td></tr><tr><td>점수 기록</td><td>${_esc(c.timeline)}</td></tr>
${crit.isEmpty ? '' : '<tr><td>기준별 점수</td><td>공간·아치 ${crit['c1']} · 교합 ${crit['c2']} · 형태·색 보존 ${crit['c3']} · 잇몸·조직 보존 ${crit['c4']} (각 25점)</td></tr>'}</table>
<div class="imgs">${fig('original', '① 원본 사진')}${fig('target', '② 실제 정답지')}${fig('result', '③ AI 최종 결과물')}</div>
<h3>채택된 추가 요청</h3><pre>${_esc(c.request.isEmpty ? '(없음)' : c.request)}</pre>
<h3>황금 프롬프트 전문</h3><pre>${_esc(c.prompt)}</pre>
<p style="color:#66768C;font-size:12px">B&amp;A 치과 시뮬레이터 · 프롬프트 보관함 백업</p></div></body></html>''';
}

// -----------------------------------------------------------------------------
// 치료별 기본 설정 ([이 치료의 기본 설정으로 적용])
//   그 치료 버튼을 켤 때 '추가 요청'과 적용 강도를 이 값으로 채움
// -----------------------------------------------------------------------------
class TreatmentDefaults {
  TreatmentDefaults._();
  static final TreatmentDefaults instance = TreatmentDefaults._();
  static const _k = 'tx.defaults';
  final Map<String, ({String request, int strength})> map = {};

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_k);
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      map
        ..clear()
        ..addAll({
          for (final e in j.entries)
            e.key: (
              request: '${(e.value as Map)['request'] ?? ''}',
              strength: ((e.value as Map)['strength'] as num?)?.toInt() ?? 90,
            ),
        });
    } catch (e) {
      debugPrint('tx defaults: $e');
    }
  }

  Future<void> set(String treatment, String request, int strength) async {
    map[treatment] = (request: request, strength: strength);
    try {
      await (await SharedPreferences.getInstance()).setString(
        _k,
        jsonEncode({
          for (final e in map.entries)
            e.key: {'request': e.value.request, 'strength': e.value.strength},
        }),
      );
    } catch (_) {}
  }
}
