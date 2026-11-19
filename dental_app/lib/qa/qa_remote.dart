import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ai/ai_service.dart';
import '../ai/pipeline.dart';
import '../cast/cast_service.dart';
import '../records/records.dart';
import '../simulator/sim_import.dart';
import 'archive.dart';
import 'qa_agent.dart';
import 'qa_session.dart';

/// 🤖 자동 QA · 📚 보관함을 상담 PC 에서도 쓰게 하는 연결
///   태블릿 → PC : rooms/{방}/qa (진행 상황), qaImg (정답지·최근 결과 사진),
///                 archive (보관함 목록 + 작은 사진), archiveFull (백업 파일 내용)
///   PC → 태블릿 : cmds 의 qaTarget / qaCompare / qaStart / qaStop / qaSave /
///                 archApply / archDel / archFull
class QaRemote {
  QaRemote._();
  static final instance = QaRemote._();

  /// 시험용: 실제 Firebase 대신 기록
  Future<void> Function(String path, Object? value)? putOverride;
  Future<void> _put(String path, Object? v) =>
      (putOverride ?? CastService.instance.put)(path, v);

  bool _started = false;
  Timer? _qaTimer, _arTimer, _recTimer;
  String? _lastQa, _lastAr, _lastRec;
  int _imgKey = -1;
  bool _wasConnected = false;

  /// 시뮬레이터가 지금 화면 조건으로 QA 조건을 만들어 줌 (사진이 없으면 null)
  QaSetup? Function(Uint8List? target)? setupOf;

  /// 지금 화면의 원본 사진
  Uint8List? Function()? originalOf;

  /// 현재 선택된 엔진
  Engine Function() engineOf = () => PipelineSettings.instance.engine;

  void start() {
    if (_started) return;
    _started = true;
    QaSession.instance.addListener(_qaChanged);
    PromptArchive.instance.addListener(_arChanged);
    PatientRecords.instance.addListener(_recChanged);
    CastService.instance.addListener(_castChanged);
    _castChanged();
  }

  void _castChanged() {
    final on = CastService.instance.connected || putOverride != null;
    if (on && !_wasConnected) {
      // 새로 연결됨 → 전부 다시 보냄
      _lastQa = _lastAr = _lastRec = null;
      _imgKey = -1;
      _qaChanged();
      _arChanged();
      _recChanged();
    }
    _wasConnected = on;
  }

  bool get _on => CastService.instance.connected || putOverride != null;

  void _qaChanged() {
    if (!_on) return;
    _qaTimer ??= Timer(const Duration(milliseconds: 250), () {
      _qaTimer = null;
      publishQa();
    });
  }

  void _recChanged() {
    if (!_on) return;
    _recTimer ??= Timer(const Duration(milliseconds: 500), () {
      _recTimer = null;
      publishRecords();
    });
  }

  /// 🗂 환자 기록 목록 (최근 150건, 작은 사진 2장) → PC 에서 검색·폴더 보기
  Future<void> publishRecords() async {
    final store = PatientRecords.instance;
    await store.ensureLoaded();
    final list = store.search().take(150).toList();
    final key = '${store.records.length}:${list.map((r) => r.id).join(',')}';
    if (key == _lastRec) return;
    _lastRec = key;
    final items = <Map<String, Object?>>[];
    for (final r in list) {
      final th = <String, String>{};
      for (final (k, f) in [
        ('before', 'before.jpg'),
        if (r.shots.isNotEmpty) ('after', r.shots.last.file),
      ]) {
        try {
          final file = await store.file(r, f);
          if (await file.exists()) {
            th[k] = await jpegBase64(
              await file.readAsBytes(),
              maxSide: 220,
              quality: 70,
            );
          }
        } catch (_) {}
      }
      items.add({
        ...r.toJson(),
        'day': r.day,
        'dayText': r.dayText,
        'time': r.time,
        'thumbs': th,
      });
    }
    await _put('records', {'n': store.records.length, 'items': items});
  }

  void _arChanged() {
    if (!_on) return;
    _arTimer ??= Timer(const Duration(milliseconds: 400), () {
      _arTimer = null;
      publishArchive();
    });
  }

  // ---------------------------------------------------------------------------
  // 태블릿 → PC
  // ---------------------------------------------------------------------------
  static Map<String, Object?> runJson(QaRun r, {bool saved = false}) => {
    'e': r.engine.name,
    'tag': r.engine.tag,
    'label': r.engine.label,
    'badge': r.badge,
    'timeline': r.timeline,
    'passed': r.passed,
    'unranked': r.unranked,
    'best': r.bestScore,
    'tries': r.tries,
    'passRound': r.passedAttempt?.round,
    'saved': saved,
    'canSave': (r.passedAttempt ?? r.best)?.result != null,
    'attempts': [
      for (final a in r.attempts)
        {
          'round': a.round,
          'strength': a.params.strength,
          'request': a.params.request,
          'total': a.score?.total,
          'c': a.score == null
              ? null
              : [a.score!.c1, a.score!.c2, a.score!.c3, a.score!.c4],
          'ded': a.score?.deductions,
          'next': a.score?.nextRequest,
          'nextStrength': a.score?.nextStrength,
          'summary': a.score?.summary,
          'error': a.error,
          'passed': a.passed,
        },
    ],
  };

  Map<String, Object?> qaJson() {
    final s = QaSession.instance;
    final ranked = s.runs.length > 1 && !s.running ? rankRuns(s.runs) : null;
    final top = ranked?.firstOrNull;
    final e = engineOf();
    return {
      'v': 1,
      'running': s.running,
      'status': s.status,
      'compareAll': s.compareAll,
      'pass': s.passScore,
      'hasTarget': s.target != null,
      'selfScore': s.setup?.selfScore ?? false,
      'photo': originalOf?.call() != null,
      'ready': AiService.instance.ready,
      'engine': {'e': e.name, 'tag': e.tag, 'label': e.label},
      'scorer': QaSettings.active ?? QaSettings.scorerModel,
      'runs': [
        for (final r in s.runs) runJson(r, saved: s.saved.contains(r.engine)),
      ],
      'rank': ranked == null ? null : [for (final r in ranked) r.engine.name],
      'recommend': top == null || top.unranked
          ? null
          : '${top.engine.tag} (${top.engine.label}) — '
                '${top.passed ? '${top.passedAttempt!.round}회 만에 ${top.passedAttempt!.score!.total}점 합격' : '최고 ${top.bestScore}점'}',
      'imgKey': s.targetVer * 1000 + s.latestVer,
    };
  }

  Future<void> publishQa() async {
    final j = qaJson();
    final key = jsonEncode(j);
    if (key != _lastQa) {
      _lastQa = key;
      await _put('qa', j);
    }
    final s = QaSession.instance;
    final ik = s.targetVer * 1000 + s.latestVer;
    if (ik != _imgKey) {
      _imgKey = ik;
      try {
        final t = s.target, l = s.latest;
        await _put('qaImg', {
          'key': ik,
          if (t != null) 'target': await jpegBase64(t, maxSide: 900),
          if (l != null) 'latest': await jpegBase64(l, maxSide: 900),
        });
      } catch (e) {
        debugPrint('qaImg: $e');
        _imgKey = -1;
      }
    }
  }

  Future<void> publishArchive() async {
    final ar = PromptArchive.instance;
    final list = ar.cases.take(40).toList(); // 너무 많으면 최근 40개
    final key = list.map((c) => c.id).join(',');
    if (key == _lastAr) return;
    _lastAr = key;
    final cases = <Map<String, Object?>>[];
    for (final c in list) {
      final thumbs = <String, String>{};
      for (final k in ['original', 'target', 'result']) {
        try {
          final f = await ar.imageFile(c.id, k);
          if (await f.exists()) {
            thumbs[k] = await jpegBase64(
              await f.readAsBytes(),
              maxSide: 360,
              quality: 72,
            );
          }
        } catch (_) {}
      }
      cases.add({
        ...c.toJson(),
        'folders': c.folders,
        'badge': c.badge,
        'selfScored': c.selfScored,
        'thumbs': thumbs,
      });
    }
    await _put('archive', {
      'n': ar.cases.length,
      'folders': [
        for (final f in archiveFolders) {'name': f, 'count': ar.count(f)},
      ],
      'cases': cases,
    });
  }

  // ---------------------------------------------------------------------------
  // PC → 태블릿 (처리했으면 true)
  // ---------------------------------------------------------------------------
  Future<bool> handle(String? t, Object? v) async {
    final s = QaSession.instance;
    switch (t) {
      case 'qaTarget':
        final o = originalOf?.call();
        if (o == null || v is! String || v.length > 12000000) return true;
        try {
          s.setTarget(base64Decode(v));
        } catch (_) {}
        return true;
      case 'qaTargetClear':
        s.setTarget(null);
        return true;
      case 'qaPass':
        if (v is num) s.setPassScore(v.round());
        return true;
      case 'qaCompare':
        s.setCompareAll(v == true);
        return true;
      case 'qaStart':
        final o = originalOf?.call();
        if (o == null || s.running) return true;
        final setup = setupOf?.call(s.target); // 정답지 없으면 AI 자체 평가
        if (setup == null) return true;
        if (v is Map && v['scorer'] is String) {
          final m = (v['scorer'] as String).trim();
          if (m != QaSettings.scorerModel) await QaSettings.save(m);
        }
        unawaited(
          s.start(
            setup,
            s.compareAll ? [Engine.a, Engine.b, Engine.c] : [engineOf()],
          ),
        );
        return true;
      case 'qaImport': // PC 🖼 메인 화면으로 가져오기
        final run = s.runs.where((r) => r.engine.name == v).firstOrNull;
        final best = run == null ? null : (run.passedAttempt ?? run.best);
        final st = s.setup;
        if (best?.result != null && st != null) {
          await SimImport.run(
            original: st.original,
            result: best!.result!,
            tag: 'QA·${run!.engine.short}',
            name: st.patientName,
            treatments: st.treatments,
          );
        }
        return true;
      case 'archImport':
        final c = _case(v);
        if (c != null) {
          final o = await PromptArchive.instance.imageFile(c.id, 'original');
          final r = await PromptArchive.instance.imageFile(c.id, 'result');
          if (await o.exists() && await r.exists()) {
            await SimImport.run(
              original: await o.readAsBytes(),
              result: await r.readAsBytes(),
              tag: '보관함·${c.engine.split(' ').take(2).join(' ')}',
              treatments: c.treatments,
            );
          }
        }
        return true;
      case 'qaStop':
        s.stop();
        return true;
      case 'qaSave':
        final run = s.runs.where((r) => r.engine.name == v).firstOrNull;
        if (run != null) await s.save(run);
        return true;
      case 'archApply':
        final c = _case(v);
        if (c != null) {
          for (final tx in c.treatments) {
            await TreatmentDefaults.instance.set(tx, c.request, c.strength);
          }
          await _put('archiveMsg', {
            'id': c.id,
            'text':
                '✓ ${c.treatments.isEmpty ? kUnsorted : c.treatments.join('·')} 기본 설정으로 적용했습니다 (강도 ${c.strength}%)',
            'at': DateTime.now().millisecondsSinceEpoch,
          });
        }
        return true;
      case 'recFull':
        final r = PatientRecords.instance.records
            .where((x) => x.id == '$v')
            .firstOrNull;
        if (r == null) return true;
        Future<String> b64(String f) async {
          final file = await PatientRecords.instance.file(r, f);
          return await file.exists()
              ? jpegBase64(await file.readAsBytes(), maxSide: 1280)
              : '';
        }
        await _put('recordFull', {
          'id': r.id,
          'before': await b64('before.jpg'),
          if (r.hasSmile) 'smile': await b64('smile_before.jpg'),
          if (r.hasSmile) 'smileAfter': await b64('smile_after.jpg'),
          'shots': [
            for (final s in r.shots)
              {'label': s.label, 'check': s.check, 'img': await b64(s.file)},
          ],
          'at': DateTime.now().millisecondsSinceEpoch,
        });
        return true;
      case 'recLoad': // PC 🖼 시뮬레이터로 불러오기
        final id = v is Map ? '${v['id']}' : '$v';
        final r = PatientRecords.instance.records
            .where((x) => x.id == id)
            .firstOrNull;
        if (r == null) return true;
        final f = await readRecordFiles(r);
        if (f == null) return true;
        await CaseLoader.run(
          LoadedCase(
            before: f.before,
            results: f.results,
            name: r.name,
            treatments: r.treatments,
            teeth: r.teeth,
            shade: r.shade,
            memo: r.memo,
            photoType: r.photoType,
            smile: f.smile,
            smileAfter: f.smileAfter,
            smileFrom: r.shots.isEmpty ? '' : r.shots.last.label,
            recordId: r.id,
          ),
        );
        return true;
      case 'recPhoto': // PC 🗂 기록 사진 한 장만 시뮬레이터로 {id, f}
        if (v is Map && v['id'] != null && v['f'] is String) {
          final f = '${v['f']}';
          if (RegExp(r'^[A-Za-z0-9_]+\.jpg$').hasMatch(f)) {
            await RecordPhotoLoader.run('${v['id']}', f);
          }
        }
        return true;
      case 'recDel':
        final r = PatientRecords.instance.records
            .where((x) => x.id == '$v')
            .firstOrNull;
        if (r != null) await PatientRecords.instance.remove(r);
        return true;
      case 'archDel':
        final c = _case(v);
        if (c != null) await PromptArchive.instance.remove(c);
        return true;
      case 'archFull':
        final c = _case(v);
        if (c != null) {
          final b = await PromptArchive.instance.backupOf(c);
          await _put('archiveFull', {
            'id': c.id,
            'name': b.name,
            'html': b.html,
            'json': b.json,
            'at': DateTime.now().millisecondsSinceEpoch,
          });
        }
        return true;
    }
    return false;
  }

  ArchiveCase? _case(Object? id) =>
      PromptArchive.instance.cases.where((c) => c.id == '$id').firstOrNull;

  @visibleForTesting
  void resetForTest() {
    _lastQa = _lastAr = _lastRec = null;
    _imgKey = -1;
  }
}
