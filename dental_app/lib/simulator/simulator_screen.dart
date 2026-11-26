import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_service.dart';
import '../ai/prompt_engine.dart';
import '../ai/ai_settings_sheet.dart';
import '../ai/pipeline.dart';
import '../qa/archive.dart';
import '../qa/archive_screen.dart';
import '../qa/qa_agent.dart' show QaSetup;
import '../qa/qa_remote.dart';
import '../qa/qa_session.dart';
import '../qa/qa_screen.dart';
import '../records/records.dart';
import '../records/records_screen.dart';
import '../app_theme.dart';
import '../cast/cast_service.dart';
import '../cast/cast_sheet.dart';
import '../models/clinic_profile.dart';
import '../models/member.dart' show SimMode;
import '../privacy/eye_mask.dart';
import '../screens/login_screen.dart';
import '../widgets/brand_widgets.dart';
import 'compare_viewer.dart';
import 'line_tools.dart';
import '../ai/noprep_guard.dart';
import '../ai/tooth_select.dart';
import 'tooth_resize.dart';
import 'resize_session.dart';
import 'sim_import.dart';
import 'smile_screen.dart';
import '../records/record_photo_picker.dart';
import '../ai/smile.dart' show makeSmile;
import '../ai/smile_match.dart';
import '../ai/final_smile.dart';
import '../privacy/mouth_finder.dart';

import 'package:image/image.dart' as img;

import 'dental_chart.dart';
import 'sample_photos.dart';
import 'sim_models.dart';
import 'whitening.dart';

part 'step_flow.dart';

/// 치과 상담실 전용 비포&애프터 시뮬레이터 메인 화면
/// - 사진: 비교 화면 위 [환자 사진 등록] (카메라 촬영 · 갤러리 선택)
/// - 중앙: 영역 지정 → (변환 후) 일반 화면 위아래 비교 / 브리핑 모드 슬라이더 비교
/// - 우측: 상담 가이드 (치료 항목, 덴탈 차트, 셰이드, After 변환, 상담 완료)
/// 테스트용: true 면 예전 화면으로 시작 (기존 테스트들은 예전 화면 기준)
bool debugStepFlowOff = false;

class SimulatorHomeScreen extends StatefulWidget {
  const SimulatorHomeScreen({
    super.key,
    required this.profile,
    this.mode = SimMode.expert,
    this.openRecords = false,
  });
  final ClinicProfile profile;

  /// 시작 화면 [🗂 시뮬레이터 불러오기]: 열자마자 환자 기록 목록
  final bool openRecords;

  /// 개인회원: general(일반) / 사업자회원: expert(전문가용 PRO)
  final SimMode mode;

  @override
  State<SimulatorHomeScreen> createState() => _SimulatorHomeScreenState();
}

enum _ViewMode { edit, stack, slider }

class _SimulatorHomeScreenState extends State<SimulatorHomeScreen> {
  final _picker = ImagePicker();

  /// 사진 등록 시 눈 자동 가리기 (기본 켜짐, 앱을 껐다 켜도 유지)
  bool _eyeMask = true;
  static const _prefEyeMask = 'privacy.eyeMask';
  final _nameCtrl = TextEditingController();
  final _memoCtrl = TextEditingController();
  final _aiReqCtrl = TextEditingController(text: AiService.instance.request);
  final _headNameFocus = FocusNode(debugLabel: '사진 위 환자 이름');
  final _scroll = ScrollController();

  final List<PatientPhoto> _patients = [];
  PatientPhoto? _cur;
  double _pos = 0.5;
  bool _briefing = false;

  // 🆕 단계형 새 화면 (기본). [예전 화면] 으로 바꿀 수 있음
  bool _newUi = !debugStepFlowOff;
  int _step = 1;
  static const _prefNewUi = 'ui.stepFlow';
  static const _prefEngineB = 'ui.stepFlow.engineB';
  void _ss(VoidCallback fn) => setState(fn);

  void _toggleUi() {
    setState(() => _newUi = !_newUi);
    SharedPreferences.getInstance()
        .then((pr) => pr.setBool(_prefNewUi, _newUi))
        .ignore();
  }

  BoxFit _fit = BoxFit.cover;
  bool _converting = false;
  int _uploadSeq = 0;

  Consult get _c => _cur!.consult;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((pr) {
      final v = pr.getBool(_prefEyeMask);
      if (v != null && mounted) setState(() => _eyeMask = v);
      final u = pr.getBool(_prefNewUi);
      if (u != null && mounted && !debugStepFlowOff) {
        setState(() => _newUi = u);
      }
      // 새 화면 첫 사용: 기본 엔진을 옵션 B 로 (한 번만, 이후엔 사용자가 고른 대로)
      if (pr.getBool(_prefEngineB) != true) {
        pr.setBool(_prefEngineB, true).ignore();
        PipelineSettings.instance.setEngine(Engine.b).ignore();
      }
    }).ignore();
    _loadSamples();
    if (widget.openRecords) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openRecords();
      });
    }
    CastService.instance.addListener(_onCastChanged);
    // PC 에서 손잡이를 움직이거나 메모를 쓰면 태블릿에도 반영
    CastService.instance.onRemotePos = (v) {
      if (mounted && _cur != null) setState(() => _pos = v);
    };
    CastService.instance.onRemoteMemo = (m) {
      if (!mounted || _cur == null || _c.doneAt != null || _c.memo == m) return;
      setState(() {
        _c.memo = m;
        _memoCtrl.value = TextEditingValue(
          text: m,
          selection: TextSelection.collapsed(offset: m.length),
        );
      });
    };
    CastService.instance.onRemoteCmd = _onRemoteCmd;
    // 🤖 자동 QA · 📚 보관함을 상담 PC 에서도
    SimImport.handler = _importResult;
    CaseLoader.handler = _loadCase;
    RecordPhotoLoader.handler = _loadRecordPhoto;
    QaRemote.instance
      ..originalOf = (() => _cur?.beforeBytes)
      ..setupOf = _qaSetup
      ..start();
    CastService.instance.onRemoteBriefing = (on) {
      if (mounted && _cur != null && _briefing != on) _setBriefing(on);
    };
    CastService.instance.init(); // 익명 로그인만 (상담실 PC 연결은 QR 스캔할 때만)
  }

  // ---------------------------------------------------------------------------
  // 상담실 큰 화면(PC)에 현재 상태 보내기
  // 브리핑 모드일 때만 사진을 보내고, 끄면 PC는 대기 화면 + 사진 삭제
  // ---------------------------------------------------------------------------
  bool _castWasConnected = false;
  bool _pushScheduled = false;

  void _onCastChanged() {
    final now = CastService.instance.connected;
    if (now && !_castWasConnected) {
      _slotImgKey = null; // 새로 연결되면 원본 슬롯 사진도 다시 보냄
      _pushCast();
      final c = _cur;
      if (c != null) Future.microtask(() => _smilePublish(c));
    }
    _castWasConnected = now;
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_pushScheduled) return;
    _pushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pushScheduled = false;
      if (mounted) _pushCast();
    });
  }

  void _pushCast() {
    final cs = CastService.instance, p = _cur;
    if (!cs.connected || p == null) return;
    final c = _c;
    // 처음부터 PC에 Before 사진 표시, After 를 만들면 Before/After
    // (브리핑 끔: 위아래 보기, 브리핑 켬: 슬라이더)
    final converted = _mode != _ViewMode.edit;
    final cmp = p.compare;
    final order = p.listOrder;
    final smileOn = _smileView && converted && p.smileAfter != null;
    final left = smileOn
        ? p.smile!
        : converted
        ? p.bytesOf(cmp.first)
        : p.beforeBytes;
    final right = smileOn
        ? p.smileAfter
        : converted && cmp.length == 2
        ? p.bytesOf(cmp[1])
        : null;
    cs.sendImages(
      '${p.id}|${identityHashCode(p.beforeBytes)}|${identityHashCode(left)}|'
      '${identityHashCode(right)}|${identityHashCode(p.results)}|${p.extras.length}',
      left,
      right,
      thumbs: [for (final n in order) p.bytesOf(n)],
    );
    final aiReady = AiService.instance.ready;
    cs.sendState({
      'v': 6,
      'appVer': CastService.appVersion,
      'ack': cs.cmdCount,
      'imgVer': cs.imgVer, // PC 는 이 번호의 사진이 도착할 때까지 '불러오는 중' 표시
      'photoId': p.id,
      'hasAfter': p.afterBytes != null,
      'stale': _stale,
      'converting': _converting,
      'convertMsg': _converting ? _convertMsg : '',
      'strength': c.strength,
      'aiReady': aiReady,
      'useAi': _useAi,
      'engine': PipelineSettings.instance.engine.name,
      'engineEff': _useAi ? _engineNow().engine.name : null,
      'engineNote': _useAi ? _engineNow().note : null,
      'falReady': PipelineSettings.instance.hasFal,
      'vertexReady': PipelineSettings.instance.hasVertex,
      'aiReq': _aiReqCtrl.text,
      'aiReqDefault': _aiReqCtrl.text.trim().isEmpty,
      'aiAuto': _useAi ? _aiSummary().join('\n') : '',
      'aiPrompt': _useAi ? _aiPrompt() : '',
      'undo': p.history.isEmpty ? null : p.history.last.label,
      'redo': p.future.isEmpty ? null : p.future.last.label,
      'notice': _noticeAt == 0 ? null : {'m': _notice, 'at': _noticeAt},
      'base': p.baseIndex == 0 ? '' : _label(p, p.baseIndex),
      'rzOk': _mode != _ViewMode.edit && _rzTargetOf(p) != null,
      'rzOf': (() {
        final n = _rzTargetOf(p);
        return n == null ? '' : _label(p, n);
      })(),
      'ui': {'new': _newUi, 'step': _step, 'blank': p.blank},
      'slots': {
        'cur': p.slot,
        's1': _slot1Bytes(p) != null,
        's2': _slotPhoto(p, 2) != null,
        'final': {'can': _finalReady(p), 'busy': _finalBusy, 'msg': _finalMsg},
      },
      'smileRef': {
        'has': p.smile != null,
        'on': _smileRef,
        'auto': _autoMatch,
        'busy': _mBusy,
      },
      'items': [for (final n in order) _label(p, n)],
      'subs': [for (final n in order) _sub(p, n)],
      'cmp': [for (final n in cmp) order.indexOf(n)],
      'drawLines': _drawLines,
      'samOn': _samOn && c.doneAt == null,
      'sam': p.sam.length,
      'samBusy': _samBusy,
      'samUndo': p.samHistory.isNotEmpty,
      'marks': [
        for (final t in p.sam)
          {
            'l': t.label,
            'z': [
              (t.zenith.dx * 1000).round() / 1000,
              (t.zenith.dy * 1000).round() / 1000,
            ],
            'i': [
              (t.incisal.dx * 1000).round() / 1000,
              (t.incisal.dy * 1000).round() / 1000,
            ],
          },
      ],
      'rz': _rz?.toJson(),
      'smile': {
        'has': p.smile != null,
        'n':
            (p.smileSet?.sels.length ?? 0) + (p.smileSet?.auto == null ? 0 : 1),
        'undo': p.smileSet?.history.isNotEmpty ?? false,
        'busy': (p.smileSet?.busy ?? false) || _smileMaking,
        'made': p.smileAfter != null,
        'view': _smileView && p.smileAfter != null,
        'msg': _smileMsg,
        'auto': MouthFinder.supported,
        'match': {
          'ok': DentalAligner.supported || debugMatchOverride != null,
          'has2': _mFor == p.id && _mProsth != null,
          'label': _mFor == p.id ? _mLabel : '',
          'busy': _mBusy,
          'step': _mFor == p.id ? _mStep : '',
          'made': _mFor == p.id && _mRes != null,
          'pick': _mPick,
          'afters': [
            for (final a in _afterChoices(p)) {'k': a.key, 'l': a.label},
          ],
        },
      },
      'lineUndo': p.lineHistory.isNotEmpty,
      'lines': [
        for (final l in p.lines)
          {
            'u': l.upper ? 1 : 0,
            if (l.incisal) 'i': 1,
            'p': [
              for (final o in l.pts) ...[
                (o.dx * 1000).round() / 1000,
                (o.dy * 1000).round() / 1000,
              ],
            ],
          },
      ],
      'view': !converted ? 'edit' : (_briefing ? 'slider' : 'stack'),
      'briefing': _briefing,
      'pos': double.parse(_pos.toStringAsFixed(3)),
      'name': c.name.trim(),
      'type': p.type,
      'shade': c.shade,
      'tx': c.tx.toList(),
      'teeth': sortTeeth(c.teeth),
      'fit': _fit == BoxFit.contain ? 'contain' : 'cover',
      'memo': c.memo,
      'done': c.doneAt != null,
    });
  }

  @override
  void dispose() {
    if (SimImport.handler == _importResult) SimImport.handler = null;
    if (CaseLoader.handler == _loadCase) CaseLoader.handler = null;
    if (RecordPhotoLoader.handler == _loadRecordPhoto) {
      RecordPhotoLoader.handler = null;
    }
    _nameCtrl.dispose();
    _memoCtrl.dispose();
    _aiReqCtrl.dispose();
    _headNameFocus.dispose();
    _scroll.dispose();
    CastService.instance.removeListener(_onCastChanged);
    CastService.instance.onRemotePos = null;
    CastService.instance.onRemoteMemo = null;
    QaRemote.instance
      ..originalOf = null
      ..setupOf = null;
    CastService.instance.clearImages();
    if (_briefing) _setImmersive(false);
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 데이터
  // ---------------------------------------------------------------------------
  Future<void> _loadSamples() async {
    // 촬영실 PC 연동 전까지 샘플 3명 (코드로 그린 예시 사진)
    final specs = [
      (
        'p1',
        '김민수',
        '정면',
        '3분 전',
        SampleView.front,
        ['교정', '미백'],
        kUpper6,
        'A1',
        true,
      ),
      (
        'p2',
        '이지은',
        '스마일',
        '12분 전',
        SampleView.smile,
        ['라미네이트', '잇몸 성형'],
        [14, 13, 12, 11, 21, 22, 23, 24],
        'BL1',
        false,
      ),
      (
        'p3',
        '박철수',
        '측면',
        '25분 전',
        SampleView.side,
        ['교정'],
        [...kUpper6, ...kLower6],
        'A2',
        false,
      ),
    ];
    for (final s in specs) {
      final bytes = await drawSamplePhoto(s.$5, after: false);
      _patients.add(
        PatientPhoto(
          id: s.$1,
          name: s.$2,
          type: s.$3,
          time: s.$4,
          view: s.$5,
          beforeBytes: bytes,
          imageSize: kSampleSize,
          planTx: s.$6,
          planTeeth: s.$7,
          planShade: s.$8,
          isNew: s.$9,
        ),
      );
    }
    if (!mounted) return;
    _select(_patients.first);
  }

  void _select(PatientPhoto p) {
    setState(() {
      if (_cur != null && _cur != p) _cur!.isNew = false;
      _cur = p;
      _smileView = false;
      QaSession.instance.bindPatient(p); // 다른 환자·새 사진이면 🎯 정답지·QA 결과 비움
      if (_rz != null) {
        _rz = null;
        CastService.instance.put('rzImg', null);
      }
      Future.microtask(() {
        _samCast(p); // PC 하이라이트도 이 사진 것으로
        _smilePublish(p);
      });
      _pos = 0.5;
      _fit = p.isUpload
          ? BoxFit.contain
          : BoxFit.cover; // 직접 등록 사진은 구도가 제각각이라 전체 보기
      _nameCtrl.text = p.consult.name;
      _memoCtrl.text = p.consult.memo;
    });
  }

  String _settingsKey() {
    final r = _cur!.roi;
    return [
      _useAi
          ? 'ai:${_aiReqCtrl.text.trim()}:${sortTeeth(_c.teeth).join(',')}:${_c.tx.join(',')}:'
                '${_useGuide ? linesHash(_cur!.lines) : 0}:${Object.hashAll([for (final t in _cur!.sam) Object.hash(t.tap, t.zenith, t.incisal)])}:${_cur!.samEdits.length}:${_engineNow().engine.name}'
          : 'basic',
      _c.shade,
      _c.strength,
      r.left,
      r.top,
      r.width,
      r.height,
    ].map((v) => v is double ? v.toStringAsFixed(3) : '$v').join('|');
  }

  bool get _converted => _cur?.afterBytes != null;

  /// 지금 선택으로 실제 쓰일 변환 엔진 (교정·서비컬 라인 없음 등은 나노바나나 단독으로 자동 전환)
  ({Engine engine, String? note}) _engineNow() => effectiveEngine(
    PipelineSettings.instance.engine,
    _c.tx,
    (_useGuide && (_cur?.lines.cervical.isNotEmpty ?? false)) ||
        (_cur?.hasSam ?? false),
  );

  /// AI(나노바나나) 사용 여부. AI 준비가 안 됐으면 기본 미백 방식.
  bool _useAiPref = true;

  /// 사진 아래 체크: 서비컬 라인 그리기
  bool _drawLines = false;

  /// [x1, y1, x2, y2, …] → 점 목록
  List<Offset> _ptsFrom(Object? list) {
    if (list is! List) return const [];
    final raw = [
      for (final x in list)
        if (x is num) x.toDouble().clamp(0.0, 1.0),
    ];
    return [
      for (var i = 0; i + 1 < raw.length; i += 2) Offset(raw[i], raw[i + 1]),
    ];
  }

  GuideLine? _lineFrom(Object? v) {
    if (v is! Map) return null;
    final pts = _ptsFrom(v['p']);
    return pts.length > 1
        ? GuideLine(
            upper: v['u'] == true || v['u'] == 1,
            incisal: v['i'] == true || v['i'] == 1,
            pts: pts,
          )
        : null;
  }

  // ---------------------------------------------------------------------------
  // 서비컬 라인 편집: 모든 변경(그리기·지우개·다듬기·모두 지움)은 기록 → [되돌리기]로 하나씩 취소
  // ---------------------------------------------------------------------------
  void _editLines(PatientPhoto p, List<GuideLine> next) {
    setState(() {
      p.lineHistory.add(p.lines);
      if (p.lineHistory.length > 50) p.lineHistory.removeAt(0);
      p.lines = next;
    });
  }

  double _aspectOf(PatientPhoto p) => p.imageSize.height / p.imageSize.width;

  void _lineAdd(PatientPhoto p, GuideLine l) =>
      _editLines(p, [...p.lines, l.incisal ? _incisalArch(p, l) : l]);

  /// 절단선이 상악/하악 중 어느 쪽인지: 가까운 서비컬 라인 쪽 (서비컬이 없으면 사진 위쪽 절반 = 상악)
  GuideLine _incisalArch(PatientPhoto p, GuideLine l) {
    double meanY(Iterable<Offset> o) =>
        o.map((e) => e.dy).reduce((a, b) => a + b) / o.length;
    final y = meanY(l.pts);
    final up = p.lines.cervical.where((c) => c.upper && c.pts.isNotEmpty);
    final lo = p.lines.cervical.where((c) => !c.upper && c.pts.isNotEmpty);
    final dU = up.isEmpty ? null : (y - meanY(up.expand((c) => c.pts))).abs();
    final dL = lo.isEmpty ? null : (y - meanY(lo.expand((c) => c.pts))).abs();
    final upper = dU != null && dL != null
        ? dU <= dL
        : dU != null || (dL == null && y < 0.5);
    return GuideLine(upper: upper, incisal: true, pts: l.pts);
  }

  bool get _noPrep => _cur != null && _c.tx.contains(kNoPrep);

  // ---------------------------------------------------------------------------
  // 🪄 원클릭 치아 자동 선택 (SAM 2)
  // ---------------------------------------------------------------------------
  bool _samBusy = false;
  bool get _samOn => _useAi && PipelineSettings.instance.hasFal;

  Future<void> _samPrep(PatientPhoto p) async {
    if (p.samSmall != null) return;
    final src = await AiService.decodePhoto(p.beforeBytes);
    final jpeg = await AiService.photoJpeg(src);
    p.samJpeg = jpeg;
    p.samSmall = img.decodeJpg(jpeg);
  }

  void _samRemember(PatientPhoto p) {
    p.samHistory.add(([...p.sam], [...p.samEdits]));
    if (p.samHistory.length > 40) p.samHistory.removeAt(0);
  }

  Future<void> _samRefresh(PatientPhoto p) async {
    final sm = p.samSmall;
    if (sm == null || !p.hasSam) {
      if (mounted) {
        setState(() {
          p.samUnion = null;
          p.samOverlay = null;
        });
      }
      _samCast(p);
      return;
    }
    final u = await compute((a) => unionMask(a.$1, a.$2, a.$3, a.$4), (
      sm.width,
      sm.height,
      [for (final t in p.sam) t.mask],
      p.samEdits,
    ));
    final ov = await compute((m) => overlayPng(m), u);
    if (!mounted) return;
    setState(() {
      p.samUnion = u;
      p.samOverlay = ov;
    });
    _samCast(p);
  }

  /// 상담 PC 에도 하이라이트 보내기
  void _samCast(PatientPhoto p) {
    if (!CastService.instance.connected || !identical(p, _cur)) return;
    final ov = p.samOverlay;
    CastService.instance.put(
      'samOv',
      ov == null || !p.hasSam ? null : {'id': p.id, 'png': base64Encode(ov)},
    );
  }

  /// 사진 위 탭 → 그 치아 자동 선택 (이미 고른 치아를 다시 탭하면 빠짐)
  Future<void> _samTap(PatientPhoto p, Offset pt) async {
    if (_samBusy || _c.doneAt != null) return;
    final key = PipelineSettings.instance.falKey;
    if (key == null) {
      _toast('자동 선택(SAM)에는 Fal.ai API 키가 필요합니다. [🔑 API 키 설정]에서 넣어 주세요.');
      return;
    }
    for (final t in p.sam.reversed) {
      final m = t.mask;
      if (maskAt(m, (pt.dx * m.width).floor(), (pt.dy * m.height).floor()) >
          127) {
        _samRemember(p);
        p.sam = [...p.sam]..remove(t);
        labelTeeth(p.sam, sortTeeth(_c.teeth));
        await _samRefresh(p);
        _toast('${t.label} 선택을 뺐습니다.');
        return;
      }
    }
    setState(() => _samBusy = true);
    try {
      await _samPrep(p);
      final sm = p.samSmall!;
      final raw = await segmentAround(FalSam(key), sm, pt);
      final sel = await compute((a) => analyzeSel(a.$1, a.$2, a.$3), (
        sm,
        raw,
        pt,
      ));
      if (!mounted) return;
      if (sel == null) {
        _toast('치아가 아닌 곳을 누른 것 같아요. 치아 한가운데를 다시 탭해 주세요.');
        return;
      }
      _samRemember(p);
      p.sam = [...p.sam, sel];
      labelTeeth(p.sam, sortTeeth(_c.teeth));
      await _samRefresh(p);
    } on PipelineError catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('자동 선택에 실패했습니다. 다시 탭해 주세요. ($e)');
    } finally {
      if (mounted) setState(() => _samBusy = false);
    }
  }

  Future<void> _samBrush(PatientPhoto p, MaskStroke s) async {
    await _samPrep(p);
    _samRemember(p);
    p.samEdits = [...p.samEdits, s];
    await _samRefresh(p);
  }

  void _samUndo(PatientPhoto p) {
    if (p.samHistory.isEmpty) return;
    final (sam, edits) = p.samHistory.removeLast();
    p.sam = sam;
    p.samEdits = edits;
    _samRefresh(p);
  }

  void _samClear(PatientPhoto p) {
    if (!p.hasSam && p.samEdits.isEmpty) return;
    _samRemember(p);
    p.sam = [];
    p.samEdits = [];
    _samRefresh(p);
  }

  /// 📍 기준점 옮기기
  void _samMark(PatientPhoto p, int i, bool incisal, Offset pt) {
    if (i < 0 || i >= p.sam.length) return;
    setState(() {
      if (incisal) {
        p.sam[i].incisal = pt;
      } else {
        p.sam[i].zenith = pt;
      }
    });
  }

  /// 변환할 영역: 고른 치아 (+ 길이가 바뀔 수 있는 치료면 절단 쪽 10% 여유)
  img.Image? _samRegion(PatientPhoto p, Consult c) {
    final u = p.samUnion;
    if (u == null || !p.hasSam) return null;
    // ③ 모양·길이를 바꾸는 치료: 잇몸 쪽 경계만 고정, 절단·옆은 넓게 열기 (치아가 옛 틀에 갇히지 않게)
    const reshape = {'라미네이트', '올세라믹 크라운', '임플란트', '교정'};
    if (c.tx.any(reshape.contains)) return marginLockedRegion(u, p.sam);
    // 무삭제 라미네이트: 깎지 않으니 절단 쪽만 조금 (길게만)
    if (c.tx.contains('무삭제 라미네이트')) {
      return editRegion(u, p.sam, grow: 0.10);
    }
    return u; // 미백 등: 치아 모양 그대로
  }

  /// 🦷 절단선 자동 찾기 (서비컬 라인 기준) → 기존 절단선은 바꿈
  Future<bool> _autoIncisal(PatientPhoto p, {bool quiet = false}) async {
    final cerv = p.lines.cervical.where((l) => l.pts.length > 1).toList();
    if (cerv.isEmpty) {
      if (!quiet) _toast('먼저 서비컬 라인(잇몸선)을 그려 주세요. 그 아래에서 절단선을 찾습니다.');
      return false;
    }
    final im = await AiService.decodePhoto(p.beforeBytes, maxSide: 2000);
    final found = <GuideLine>[];
    for (final c in LineTools.smooth(cerv, _aspectOf(p))) {
      final l = await compute((a) => detectIncisal(a.$1, a.$2), (im, c));
      if (l != null) found.add(l);
    }
    if (!mounted) return false;
    if (found.isEmpty) {
      if (!quiet) {
        _toast('절단선을 자동으로 찾지 못했습니다. 사진 왼쪽 [절단선 🟡]으로 앞니 끝선을 직접 그려 주세요.');
      }
      return false;
    }
    _editLines(p, [...p.lines.cervical, ...found]);
    if (!quiet) {
      _toast('🦷 절단선을 찾았습니다 (노란 선). 틀린 곳은 지우개로 지우고 [절단선]으로 다시 그려 주세요.');
    }
    return true;
  }

  void _lineErase(PatientPhoto p, List<Offset> path, double r) {
    final next = LineTools.erase(p.lines, path, r, _aspectOf(p));
    // 지운 게 없으면 기록하지 않음
    var same = next.length == p.lines.length;
    for (var i = 0; same && i < next.length; i++) {
      same = identical(next[i], p.lines[i]);
    }
    if (!same) _editLines(p, next);
  }

  void _lineSmooth(PatientPhoto p) {
    if (p.lines.isEmpty) return;
    _editLines(p, LineTools.smooth(p.lines, _aspectOf(p)));
  }

  void _lineClear(PatientPhoto p) {
    if (p.lines.isEmpty) return;
    _editLines(p, []);
  }

  void _lineUndo(PatientPhoto p) {
    if (p.lineHistory.isEmpty) return;
    setState(() => p.lines = p.lineHistory.removeLast());
  }

  bool get _useGuide =>
      _drawLines && (_cur?.lines.cervical.isNotEmpty ?? false);
  bool get _useAi => _useAiPref && AiService.instance.ready;
  String _convertMsg = 'After 시뮬레이션 만드는 중…';
  bool get _stale => _converted && _cur!.convKey != _settingsKey();

  _ViewMode get _mode {
    final p = _cur!;
    // 브리핑: 항상 왼쪽 '비교할 사진' 목록에서 골라 비교 (기록 사진도 여기서 추가)
    if (_briefing) return _ViewMode.slider;
    if (p.editing) return _ViewMode.edit;
    // 변환 전이라도 목록에서 불러온 사진을 고르면 그 사진을 보여 줌
    if (p.afterBytes == null && p.compare.every((n) => n == 0)) {
      return _ViewMode.edit;
    }
    return _ViewMode.stack;
  }

  // ---------------------------------------------------------------------------
  // 사진 등록 (카메라 / 갤러리)
  // ---------------------------------------------------------------------------
  Future<void> _choosePhoto() async {
    final canCamera = _picker.supportsImageSource(ImageSource.camera);
    final source = canCamera
        ? await showModalBottomSheet<ImageSource>(
            context: context,
            showDragHandle: true,
            backgroundColor: Colors.white,
            constraints: const BoxConstraints(maxWidth: 480),
            builder: (ctx) => SafeArea(
              child: StatefulBuilder(
                builder: (ctx, setSheet) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (EyeMasker.supported)
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.visibility_off_outlined,
                          color: AppColors.blue,
                        ),
                        title: const Text('눈 자동 가리기'),
                        subtitle: const Text('환자 눈을 검은 띠로 가립니다 (태블릿 안에서만 처리)'),
                        value: _eyeMask,
                        onChanged: (v) {
                          setSheet(() => _eyeMask = v);
                          SharedPreferences.getInstance()
                              .then((pr) => pr.setBool(_prefEyeMask, v))
                              .ignore();
                        },
                      ),
                    ListTile(
                      leading: const Icon(
                        Icons.photo_camera_outlined,
                        color: AppColors.blue,
                      ),
                      title: const Text('카메라로 촬영'),
                      onTap: () => Navigator.pop(ctx, ImageSource.camera),
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.photo_library_outlined,
                        color: AppColors.blue,
                      ),
                      title: const Text('갤러리에서 선택'),
                      onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          )
        : ImageSource.gallery; // PC: 파일 선택 창
    if (source == null) return;
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 92,
      );
      if (file == null) return;
      await _addPhoto(await file.readAsBytes());
    } catch (e) {
      _toast('사진을 불러오지 못했습니다. 카메라·사진 권한을 확인해 주세요.');
    }
  }

  /// 새 환자 사진 등록 (태블릿 카메라·갤러리 또는 PC 상담 모니터에서 보낸 사진)
  /// 🖼 자동 QA·보관함 결과를 메인 화면으로: 같은 원본이면 그 환자의 다음 결과(N번)로,
  /// 아니면 원본+결과를 새 환자 사진으로 추가 → 바로 비교·치아 크기 조절 등 편집 가능
  Future<String> _importResult({
    required Uint8List original,
    required Uint8List result,
    required String tag,
    String name = '',
    List<String> treatments = const [],
  }) async {
    bool same(Uint8List a) =>
        identical(a, original) ||
        (a.length == original.length && listEquals(a, original));
    var p = _patients
        .where(
          (x) => same(x.beforeBytes) || x.history.any((h) => same(h.before)),
        )
        .firstOrNull;
    if (p == null) {
      final im = await decodeImageFromList(original);
      _uploadSeq++;
      p = PatientPhoto(
        id: 'u$_uploadSeq',
        name: name.isEmpty ? '가져온 케이스 $_uploadSeq' : name,
        type: '보관함에서 가져옴',
        time: '방금',
        beforeBytes: original,
        imageSize: Size(im.width.toDouble(), im.height.toDouble()),
      );
      im.dispose();
      p.consult
        ..name = name
        ..tx.addAll(treatments);
      _patients.insert(0, p);
    }
    if (!mounted) return '시뮬레이터 화면이 닫혀 있습니다.';
    final target = p;
    _select(target);
    setState(() {
      target.remember('결과 가져오기');
      target.addResult(result, _settingsKey(), engine: tag);
      target.editing = false;
      _pos = 0.5;
    });
    // 자동 QA·보관함 화면을 닫고 메인 화면으로
    final me = _myRoute;
    if (me != null) Navigator.of(context).popUntil((r) => r == me);
    final msg =
        '🖼 ${target.consult.name.trim().isEmpty ? '' : '${target.consult.name.trim()} 님 '}${target.results.length}번으로 가져왔습니다 · 비교·치아 크기 조절로 편집할 수 있어요';
    _toast(msg);
    return msg;
  }

  /// 🗂 환자 기록을 시뮬레이터로 다시 불러오기 → 비교·미소 미리보기·크기 조절 등 다시 편집
  Future<String> _loadCase(LoadedCase k, {bool openSmile = false}) async {
    final im = await decodeImageFromList(k.before);
    _uploadSeq++;
    final p = PatientPhoto(
      id: 'u$_uploadSeq',
      name: k.name.isEmpty ? '불러온 기록 $_uploadSeq' : k.name,
      type: k.photoType.isEmpty ? '환자 기록' : '${k.photoType} · 환자 기록',
      time: '불러옴',
      beforeBytes: k.before,
      imageSize: Size(im.width.toDouble(), im.height.toDouble()),
    );
    im.dispose();
    p.recordId = k.recordId;
    p.consult
      ..name = k.name
      ..tx.addAll(k.treatments)
      ..teeth.addAll(k.teeth)
      ..shade = k.shade
      ..memo = k.memo;
    if (k.smile != null) {
      await setSmile(p, k.smile!);
      p.smileAfter = k.smileAfter;
      p.smileFrom = k.smileFrom;
      p.noteSmile();
    }
    if (!mounted) return '시뮬레이터 화면이 닫혀 있습니다.';
    _patients.insert(0, p);
    _select(p);
    setState(() {
      _nameCtrl.text = p.consult.name;
      _memoCtrl.text = p.consult.memo;
      for (final r in k.results) {
        p.addResult(r.bytes, _settingsKey(), engine: r.engine, check: r.check);
      }
      p.editing = p.results.isEmpty;
      _smileView = p.smileAfter != null;
      _pos = 0.5;
    });
    final me = _myRoute;
    if (me != null) Navigator.of(context).popUntil((r) => r == me);
    final msg =
        '🗂 ${k.name.isEmpty ? '기록' : '${k.name} 님 기록'}을 불러왔습니다 (결과 ${p.results.length}장)${p.results.isEmpty ? '' : ' · 비교·😊 미소 미리보기·치아 크기 조절로 다시 편집할 수 있어요'}';
    _toast(msg);
    if (openSmile && p.results.isNotEmpty && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (mounted) _openSmile(p);
    }
    return msg;
  }

  /// 🗂 기록 사진 한 장 불러오기 → 지금 화면의 '비교할 사진' 목록 끝에 (불러온 차례대로).
  /// 지금 화면이 예시 사진이면 그 기록의 환자(원본·상담 내용)를 만들어 거기에.
  /// 같은 기록의 환자면 변환 결과는 결과로, 미소 사진은 미소 미리보기로 들어감.
  Future<String> _loadRecordPhoto(String id, String file) async {
    final store = PatientRecords.instance;
    await store.ensureLoaded();
    final r = store.records.where((x) => x.id == id).firstOrNull;
    if (r == null) return '기록을 찾지 못했습니다.';
    Future<Uint8List?> read(String f) async {
      final fh = await store.file(r, f);
      return await fh.exists() ? fh.readAsBytes() : null;
    }

    final bytes = await read(file);
    if (bytes == null) return '사진 파일을 찾지 못했습니다.';
    final who = r.name.isEmpty ? '기록' : r.name;
    final shot = r.shots.where((s) => s.file == file).firstOrNull;
    final what = switch (file) {
      'before.jpg' => '$who 원본',
      'smile_before.jpg' => '😊 $who 미소',
      'smile_after.jpg' => '😊 $who 미소 미리보기',
      _ => shot?.label ?? '$who 변환 결과',
    };
    var p = _cur;
    if (p == null || !p.isUpload) {
      // 예시 사진 화면 → 그 기록의 환자로
      p = _patients.where((x) => x.recordId == id).firstOrNull;
      if (p == null) {
        final before = await read('before.jpg') ?? bytes;
        final im = await decodeImageFromList(before);
        _uploadSeq++;
        p = PatientPhoto(
          id: 'u$_uploadSeq',
          name: r.name.isEmpty ? '불러온 기록 $_uploadSeq' : r.name,
          type: r.photoType.isEmpty ? '환자 기록' : '${r.photoType} · 환자 기록',
          time: '불러옴',
          beforeBytes: before,
          imageSize: Size(im.width.toDouble(), im.height.toDouble()),
        );
        im.dispose();
        p.recordId = r.id;
        p.consult
          ..name = r.name
          ..tx.addAll(r.treatments)
          ..teeth.addAll(r.teeth)
          ..shade = r.shade
          ..memo = r.memo;
        _patients.insert(0, p);
      }
    }
    if (!mounted) return '시뮬레이터 화면이 닫혀 있습니다.';
    final target = p;
    if (!identical(_cur, target)) _select(target);
    final again = target.hasPhoto(bytes);
    if (!again) {
      final mine = target.recordId == id;
      if (mine && shot != null) {
        target.remember('기록 사진 불러오기');
        target.addResult(
          bytes,
          _settingsKey(),
          engine: shot.engine,
          check: shot.check,
        );
      } else if (mine && file == 'smile_before.jpg') {
        await setSmile(target, bytes);
      } else if (mine && file == 'smile_after.jpg' && target.smile != null) {
        target.smileAfter = bytes;
        target.smileFrom = r.shots.isEmpty ? '' : r.shots.last.label;
        target.noteSmile();
      } else {
        target.addExtra(bytes, what, sub: '환자 기록 · ${r.dayText} ${r.time}');
      }
    }
    if (!mounted) return '시뮬레이터 화면이 닫혀 있습니다.';
    setState(() {
      if (target.results.isNotEmpty) target.editing = false;
      _pos = 0.5;
    });
    _smilePublish(target);
    final msg = again
        ? '🗂 $what 은(는) 이미 목록에 있습니다'
        : '🗂 $what 을(를) 왼쪽 \'비교할 사진\' 목록에 불러왔습니다${_briefing ? '' : ' ([환자 브리핑 모드]에서 보여요)'} · 다른 사진도 한 장씩 불러올 수 있어요';
    _toast(msg);
    return msg;
  }

  /// 비교 목록에서 사진 빼기 (원본 제외)
  void _removePhoto(PatientPhoto p, int n) {
    final label = _label(p, n);
    String? done;
    setState(() => done = p.removePhoto(n, label));
    if (done == null) return;
    _smilePublish(p);
    _toast(
      n > 0
          ? '🗑 \'$label\' 을(를) 목록에서 뺐습니다 · [이전으로]로 되돌릴 수 있어요'
          : '🗑 \'$label\' 을(를) 목록에서 뺐습니다',
    );
  }

  ModalRoute<Object?>? _myRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _myRoute = ModalRoute.of(context);
  }

  Future<void> _addPhoto(Uint8List original, {bool fromPc = false}) async {
    var bytes = original;
    var masked = false;
    if (_eyeMask && EyeMasker.supported) {
      try {
        final m = await EyeMasker.mask(original);
        if (m != null) {
          bytes = m;
          masked = true;
        }
      } catch (e) {
        debugPrint('eye mask: $e');
      }
    }
    final img = await decodeImageFromList(bytes);
    _uploadSeq++;
    final p = PatientPhoto(
      id: 'u$_uploadSeq',
      name: '새 환자 $_uploadSeq',
      type: fromPc ? 'PC에서 등록' : '직접 등록',
      time: '방금',
      beforeBytes: bytes,
      imageSize: Size(img.width.toDouble(), img.height.toDouble()),
    );
    img.dispose();
    if (masked) {
      // [이전으로] 를 누르면 가리기 전 원본으로
      p.history.add(
        PhotoSnap(label: '눈 가리기', before: original, editing: true, roi: p.roi),
      );
    }
    if (!mounted) return;
    p.consult.name = ''; // 이름은 사진 위 칸에서 바로 입력
    _patients.insert(0, p);
    _select(p);
    if (!fromPc) _headNameFocus.requestFocus();
    final eyeMsg = !_eyeMask || !EyeMasker.supported
        ? ''
        : masked
        ? ' 👁 눈을 자동으로 가렸습니다 (원본: [이전으로]).'
        : ' (눈이 보이지 않아 가리지 않았습니다)';
    _toast(
      '${fromPc ? 'PC에서 보낸 ' : ''}'
      '${_useAi ? '사진을 등록했습니다. 환자 이름을 적고 [After 변환하기]를 눌러 주세요.' : '사진을 등록했습니다. 환자 이름을 적고, 점선을 치아에 맞춘 뒤 [After 변환하기]를 눌러 주세요.'}'
      '$eyeMsg',
    );
  }

  // ---------------------------------------------------------------------------
  // PC 상담 모니터에서 마우스로 조작한 명령
  // ---------------------------------------------------------------------------
  void _onRemoteCmd(Map<String, Object?> m) {
    if (!mounted) return;
    final qt = m['t'];
    if (qt is String &&
        (qt.startsWith('qa') ||
            qt.startsWith('arch') ||
            qt.startsWith('rec'))) {
      setState(() {}); // ack
      QaRemote.instance.handle(qt, m['v']);
      return;
    }
    if (_cur == null) return;
    setState(() {}); // 받은 명령 수(ack)를 PC 로 바로 보냄
    final p = _cur!, c = _c, t = m['t'], v = m['v'];
    final locked = c.doneAt != null;
    switch (t) {
      case 'briefing':
        if (_briefing != (v == true)) _setBriefing(v == true);
        return;
      case 'photo':
        if (v is String && v.length < 12000000) {
          try {
            _addPhoto(base64Decode(v), fromPc: true);
          } catch (_) {}
        }
        return;
      case 'undo':
        if (_converting) return;
        String? label;
        setState(() => label = p.undo());
        if (label != null) _toast('↶ PC에서 \'$label\' 이전 상태로 돌렸습니다.');
        return;
      case 'redo':
        if (_converting) return;
        String? label;
        setState(() => label = p.redo());
        if (label != null) _toast('↷ PC에서 \'$label\' 상태로 다시 돌렸습니다.');
        return;
      case 'cmpToggle':
        // PC 는 목록 위치(0, 1, 2 …)로 보냄 → 사진 번호로
        if (v is int && v >= 0 && v < p.listOrder.length) {
          setState(() {
            _smileView = false;
            p.editing = false;
            p.toggleSel(p.listOrder[v]);
            p.noteBase(p.listOrder[v]);
          });
        }
        return;
      case 'before': // 원본 화면 (서비컬 라인·🪄 치아 고르기)
        setState(() => _toEditView(p));
        return;
      case 'confirmSave': // PC 💾 저장 및 상담 완료 (PC 에서 이미 확인 받음)
        _confirm(ask: false);
        return;
      case 'slotImgReq': // PC 카드 사진이 없으면 다시 보내 달라고
        _slotImgKey = null;
        _smilePublish(p);
        return;
      case 'after':
        if (p.afterBytes != null && p.editing) {
          setState(() => p.editing = false);
        }
        return;
    }
    if (locked) return; // 상담 완료 후에는 내용 변경 안 함
    switch (t) {
      case 'name':
        if (v is String && v != c.name) {
          setState(() => c.name = v);
          if (_nameCtrl.text != v) {
            _nameCtrl.value = TextEditingValue(
              text: v,
              selection: TextSelection.collapsed(offset: v.length),
            );
          }
        }
      case 'tooth':
        if (v is int) {
          setState(
            () => c.teeth.contains(v) ? c.teeth.remove(v) : c.teeth.add(v),
          );
        }
      case 'group':
        if (v is List) {
          _toggleGroup([
            for (final x in v)
              if (x is int) x,
          ]);
        }
      case 'clearTeeth':
        setState(() => c.teeth.clear());
      case 'tx':
        if (v is String && kTreatments.contains(v)) {
          _toggleTx(v);
        }
      case 'shade':
        if (v == null) {
          setState(() => c.shade = null); // PC 에서 같은 셰이드를 다시 눌러 해제
        } else if (v is String && kShades.any((s) => s.id == v)) {
          setState(() => c.shade = v);
        }
      case 'shadeToggle':
        // PC 에서 셰이드 칩 클릭: 태블릿이 순서대로 판단 (같은 칩이면 해제, 아니면 선택)
        if (v is String && kShades.any((s) => s.id == v)) {
          setState(() => c.shade = c.shade == v ? null : v);
        }
      case 'strength':
        if (v is num) {
          setState(() => c.strength = (v.round() ~/ 5 * 5).clamp(30, 100));
        }
      case 'engine':
        final e = Engine.values.where((x) => x.name == v).firstOrNull;
        if (e != null) {
          PipelineSettings.instance.setEngine(e);
          setState(() {});
        }
      case 'useAi':
        if (AiService.instance.ready) setState(() => _useAiPref = v == true);
      case 'aiReq':
        if (v is String && v != _aiReqCtrl.text) {
          _aiReqCtrl.value = TextEditingValue(
            text: v,
            selection: TextSelection.collapsed(offset: v.length),
          );
          AiService.instance.saveRequest(v);
          setState(() {});
        }
      case 'aiReqDefault':
        _aiReqCtrl.clear();
        AiService.instance.saveRequest('');
        setState(() {});
      case 'drawLines':
        setState(() {
          _drawLines = v == true;
          if (_drawLines) _toEditView(p);
        });
      // 서비컬 라인: 한 줄 추가 / 마지막 줄 취소 / 모두 지움 (순서대로 처리 → 빠뜨림 없음)
      case 'lineAdd':
        final l = _lineFrom(v);
        if (l != null) _lineAdd(p, l);
      case 'lineErase': // PC 지우개: 지나간 길 + 반지름
        final path = v is Map ? _ptsFrom(v['p']) : const <Offset>[];
        final r = v is Map && v['r'] is num
            ? (v['r'] as num).toDouble().clamp(0.002, 0.1)
            : 0.015;
        if (path.isNotEmpty) _lineErase(p, path, r);
      case 'linesUndo':
        _lineUndo(p);
      case 'linesClear':
        _lineClear(p);
      case 'linesSmooth':
        _lineSmooth(p);
      case 'lines': // 예전 PC 화면용 (빈 목록은 Firebase 가 지워서 값 없이 옴 → 모두 지움)
        final list = v is List ? v : const [];
        _editLines(p, [for (final x in list) ?_lineFrom(x)]);
      case 'samTap': // PC 🪄 자동 선택 클릭
        if (v is Map && v['x'] is num && v['y'] is num) {
          _samTap(
            p,
            Offset(
              (v['x'] as num).toDouble().clamp(0.0, 1.0),
              (v['y'] as num).toDouble().clamp(0.0, 1.0),
            ),
          );
        }
      case 'samMark': // PC 📍 기준점 옮기기
        if (v is Map && v['n'] is num && v['x'] is num && v['y'] is num) {
          _samMark(
            p,
            (v['n'] as num).toInt(),
            v['inc'] == true,
            Offset(
              (v['x'] as num).toDouble().clamp(0.0, 1.0),
              (v['y'] as num).toDouble().clamp(0.0, 1.0),
            ),
          );
        }
      case 'smilePhoto': // PC 😊 미소 사진 올리기
        if (v is String && v.length < 12000000) _smileRemotePhoto(p, v);
      case 'smileAuto':
        _smileRemoteAuto(p);
      case 'smileTap':
        if (v is Map && v['x'] is num && v['y'] is num) {
          _smileRemoteTap(
            p,
            Offset(
              (v['x'] as num).toDouble().clamp(0.0, 1.0),
              (v['y'] as num).toDouble().clamp(0.0, 1.0),
            ),
          );
        }
      case 'smileUndo':
        p.smileSet?.undo().then((_) => _smilePublish(p));
      case 'smileClear':
        p.smileSet?.clear().then((_) => _smilePublish(p));
      case 'smileMake':
        _smileRemoteMake(p);
      case 'smileView':
        setState(() => _smileView = v == true && p.smileAfter != null);
      case 'slotRotate': // PC 원본 사진 돌리기 {s, d}
        if (v is Map && (v['s'] == 1 || v['s'] == 2) && v['d'] is int) {
          _rotateSlot(
            p,
            v['s'] as int,
            (v['d'] as int) >= 0 ? 1 : -1,
            ask: false,
          );
        }
      case 'newCase': // PC ＋ 새 작업
        _newCase();
      case 'step': // PC 단계 이동
        if (v is int && v >= 1 && v <= 7) _goStep(v);
      case 'slotSelect': // PC 변환할 원본 고르기 (1 미소 / 2 개구기)
        if (v == 1 || v == 2) _slotSelect(p, v as int);
      case 'slotPhoto': // PC 원본 슬롯에 사진 올리기 {s, b}
        if (v is Map && (v['s'] == 1 || v['s'] == 2) && v['b'] is String) {
          final b = v['b'] as String;
          if (b.length < 12000000) {
            _setSlot(p, v['s'] as int, base64Decode(b), fromPc: true);
          }
        }
      case 'finalSmile': // PC 2단계 최종 미소 만들기
        _finalSmile(p);
      case 'smileRef': // PC 😊 미소 사진도 참고해서 변환
        setState(() => _smileRef = v == true);
      case 'autoMatch': // PC 변환 후 미소 사진에 자동 매칭
        setState(() => _autoMatch = v == true);
      case 'cmpRemove': // PC 비교 목록 ✕ (목록 위치 번호)
        if (v is int && v > 0 && v < p.listOrder.length) {
          _removePhoto(p, p.listOrder[v]);
        }
      case 'extraPhoto': // PC 비교 목록에 사진 올리기
        if (v is String && v.length < 12000000) {
          final b = base64Decode(v);
          if (!p.hasPhoto(b)) {
            final k = p.extras.where((e) => e.sub == '불러온 사진').length + 1;
            setState(() => p.addExtra(b, '사진 $k', sub: '불러온 사진'));
            _smilePublish(p);
          }
        }
      case 'smileFromRec': // PC 환자 기록 → 미소 사진(+미소 미리보기)을 비교 목록에, 미소 사진은 미리보기용으로
        if (v is String) _smileFromRecord(p, v);
      case 'matchPhoto': // PC 🦷 보철 사진(2번) 올리기
        if (v is String && v.length < 12000000) {
          _matchSet(p, base64Decode(v), '보철 사진 (PC에서 올림)');
        }
      case 'matchUseAfter':
        final a = _shownAfter(p);
        if (a != null) {
          final n =
              p.compare.where((i) => i > 0).lastOrNull ?? p.results.length;
          _matchSet(p, a, _label(p, n));
        }
      case 'matchUseResult': // PC: 오늘 만든 After 중 하나를 2번(보철 사진)으로
        final a = _afterChoices(p).where((x) => x.key == '$v').firstOrNull;
        if (a != null) _matchSet(p, a.bytes, a.label);
      case 'matchRun':
        _matchRun(p);
      case 'matchPick':
        if (v is num) _matchPick(p, v.toInt());
      case 'rzStart':
        _rzStart(p);
      case 'rzTap':
        if (v is Map && v['x'] is num && v['y'] is num) {
          _rzTap(
            Offset(
              (v['x'] as num).toDouble().clamp(0.0, 1.0),
              (v['y'] as num).toDouble().clamp(0.0, 1.0),
            ),
          );
        }
      case 'rzNeg': // PC 오른쪽 클릭: 같이 잡힌 옆 치아 빼기
        if (_rz != null && v is Map && v['x'] is num && v['y'] is num) {
          final rz = _rz!;
          rz
              .negTap(
                Offset(
                  (v['x'] as num).toDouble().clamp(0.0, 1.0),
                  (v['y'] as num).toDouble().clamp(0.0, 1.0),
                ),
                falKey: PipelineSettings.instance.falKey,
              )
              .then((err) {
                if (!mounted || _rz != rz) return;
                setState(() {});
                _rzPreview();
                if (err != null) _toast(err);
              });
          setState(() {});
        }
      case 'rzSel':
        if (_rz != null && v is num) {
          setState(() => _rz!.sel = v.toInt().clamp(0, _rz!.teeth.length - 1));
        }
      case 'rzStep':
        if (_rz != null && v is Map) {
          final side = GrowSide.values
              .where((e) => e.name == v['s'])
              .firstOrNull;
          if (side != null &&
              _rz!.stepTooth(_rz!.sel, side, v['d'] == -1 ? -1 : 1)) {
            setState(() {});
            _rzPreview();
          }
        }
      case 'rzRemove':
        if (_rz != null) {
          setState(() => _rz!.removeTooth(_rz!.sel));
          _rzPreview();
        }
      case 'rzApply':
        _rzApply(p);
      case 'rzCancel':
        _rzEnd();
      case 'samUndo':
        _samUndo(p);
      case 'samClear':
        _samClear(p);
      case 'incisalAuto': // PC [🦷 절단선 자동 찾기]
        if (!locked) _autoIncisal(p);
      case 'convert':
        if (!_converting) _convert();
    }
  }

  // ---------------------------------------------------------------------------
  // After 변환 (상담 가이드의 버튼으로만 실행)
  // ---------------------------------------------------------------------------
  /// AI 로 After 한 장 만들기 (선택한 엔진 → 실패하면 나노바나나 단독). [fix]: 검사에서 고칠 점
  Future<({Uint8List? after, String? fail, String? notice, String tag})>
  _aiGenerate(PatientPhoto p, Consult c, {String fix = ''}) async {
    Uint8List? after;
    String? aiFail;
    String? aiNotice;
    var usedTag = '';
    // 🪄 SAM 으로 고른 치아 = 변환 영역 (없으면 서비컬 라인 방식)
    final region = _samRegion(p, c);
    // 잇몸 마스크 잠금 (잇몸 성형을 고르면 잇몸을 다듬어야 하므로 잠그지 않음)
    final lock = _useGuide && !c.tx.contains('잇몸 성형')
        ? p.lines.cervical
        : const <GuideLine>[];
    final eff = _engineNow();
    final base = p.baseBytes; // 원본 또는 목록에서 고른 변환 결과
    // 😊 원본 2장: 미소 사진도 참고로 (미소 입술선·얼굴 중심에 맞는 치아로)
    final useRef = _smileRefOn(p);
    final refs = useRef
        ? await smileRefs(p.smile!)
        : const <({String label, Uint8List jpeg})>[];
    if (eff.engine != Engine.solo) {
      // 2단계 파이프라인: 1단계 FLUX(마진·형태) → 2단계 선택한 엔진(리얼리즘)
      try {
        after = await TwoPassPipeline().run(
          engine: eff.engine,
          before: base,
          lines: p.lines.cervical,
          maskOverride: region,
          refs: refs,
          refPrompt: useRef ? kSmileRefPrompt : '',
          fluxPrompt: ClinicalPrompt.fluxPrompt(
            treatments: c.tx,
            teeth: sortTeeth(c.teeth),
            shade: c.shade,
            extra: fix,
          ),
          lock: lock,
          onStep: (step) {
            if (mounted) {
              setState(() => _convertMsg = stepMessage(eff.engine, step));
            }
          },
          onNotice: (m) {
            aiNotice = m;
            usedTag = 'FLUX'; // 2단계 실패 → 1단계 결과
          },
        );
        if (usedTag.isEmpty) usedTag = eff.engine.short;
      } on PipelineError catch (e) {
        aiNotice = '${e.message} → 이번에는 나노바나나 단독으로 만들었습니다.';
      } on AiError catch (e) {
        aiNotice = '${e.message} → 이번에는 나노바나나 단독으로 만들었습니다.';
      }
      if (after == null && mounted) {
        setState(() => _convertMsg = stepMessage(Engine.solo, 1));
      }
    } else if (eff.note != null) {
      aiNotice = eff.note;
    }
    if (after == null) {
      try {
        after = await AiService.instance.generateAfter(
          before: base,
          guide: _useGuide ? p.lines.cervical : const [],
          lock: lock,
          prompt: useRef
              ? '${_aiPrompt(extra: fix)}\n$kSmileRefPrompt'
              : _aiPrompt(extra: fix),
          refs: refs,
        );
        usedTag = Engine.solo.short;
      } on AiError catch (e) {
        aiFail = e.message;
      }
    }
    if (region != null && after != null) {
      // 고른 치아 바깥(잇몸·인접 치아·입술)은 원본 픽셀로 100% 되돌림
      final src = await AiService.decodePhoto(base);
      after = await compute(protectOutside, (src, after, region));
    }
    if (useRef && after != null && usedTag.isNotEmpty)
      usedTag = '$usedTag · 미소 참고';
    return (after: after, fail: aiFail, notice: aiNotice, tag: usedTag);
  }

  Future<void> _convert() async {
    final p = _cur!, c = _c;
    final useAi = _useAi;
    final baseN = p.baseIndex; // 0 = 원본, N = N번 결과를 다듬기
    if (!useAi && c.teeth.isEmpty) {
      _toast('치료 부위를 덴탈 차트에서 먼저 선택해 주세요.');
      return;
    }
    if (!useAi && c.shade == null) {
      _toast('기본 미백 방식은 희망 셰이드를 골라야 합니다.');
      return;
    }
    setState(() {
      _converting = true;
      _convertMsg = useAi
          ? stepMessage(_engineNow().engine, 1)
          : 'After 시뮬레이션 만드는 중…';
    });
    try {
      final shade = shadeById(
        c.shade ?? 'A1',
      ); // 기본 미백 방식용 (AI 실패 시 셰이드 미선택이면 A1)
      Uint8List? after;
      String? aiFail;
      String? aiNotice;
      var usedTag = ''; // 결과 이름 뒤에 붙일 엔진 표시 (비교용)
      NoPrepOutcome? noPrep; // 무삭제 라미네이트 검사 결과
      if (useAi && _noPrep) {
        // 🦷 무삭제 라미네이트: 절단선 확보 → 변환 → 픽셀 보호 → AI 검사 → 미달이면 다시 (최대 2회)
        if (!p.hasSam && _useGuide && p.lines.incisalLines.isEmpty) {
          await _autoIncisal(p, quiet: true);
        }
        try {
          final out = await runNoPrepGuard(
            original: p.baseBytes,
            lines: p.hasSam
                ? contourLines(p.sam)
                : (_useGuide ? p.lines : const []),
            marks: [
              for (final t in p.sam)
                (
                  label: t.label,
                  upper: t.upper,
                  zenith: t.zenith,
                  incisal: t.incisal,
                ),
            ],
            generate: (fix) async {
              final g = await _aiGenerate(p, c, fix: fix);
              if (g.notice != null) aiNotice = g.notice;
              usedTag = g.tag;
              if (g.after == null) throw AiError(g.fail ?? 'AI 변환에 실패했습니다.');
              return g.after!;
            },
            check: (o, r, m) =>
                realNoPrepCheck(o, r, m, teeth: sortTeeth(c.teeth)),
            onStep: (m) {
              if (mounted) setState(() => _convertMsg = m);
            },
          );
          after = out.bytes;
          noPrep = out;
        } on AiError catch (e) {
          aiFail = e.message;
        }
      } else if (useAi) {
        final g = await _aiGenerate(p, c);
        after = g.after;
        aiFail = g.fail;
        aiNotice = g.notice;
        usedTag = g.tag;
      }
      if (after == null) {
        // 기본 방식 (AI 를 끄거나 AI 가 실패했을 때)
        if (p.isUpload) {
          after = await whitenPhoto(
            p.baseBytes,
            roi: p.roi,
            targetL: shade.targetL,
            targetB: shade.targetB,
            strength: c.strength,
          );
          if (after == null) {
            _toast(aiFail ?? '치아를 찾지 못했습니다. 점선 영역을 치아 위로 옮겨 다시 눌러 주세요.');
            return;
          }
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          after = await drawSamplePhoto(
            p.view!,
            after: true,
            tooth: mixToothColor(shade, c.strength),
          );
        }
      }
      if (!mounted) return;
      setState(() {
        p.remember('After 변환');
        p.addResult(
          after!,
          _settingsKey(),
          engine: baseN > 0
              ? '${usedTag.isEmpty ? '' : '$usedTag · '}$baseN번 기준'
              : usedTag,
          check: noPrep == null ? '' : noPrep.label,
        );
        p.editing = false;
        _pos = 0.5;
      });
      // 😊 원본 2장: 변환이 끝나면 미소 사진에 바로 정밀 매칭 (미소 미리보기까지)
      // (최종 목표 = 미소 사진 결과. AI 를 끈 기본 방식으로 만들어도 맞춰 줌)
      final autoMatch = aiFail == null && p.smile != null && _autoMatch;
      if (autoMatch) {
        Future.microtask(() => _matchAfterConvert(p));
      }
      final np = noPrep;
      if (autoMatch) {
        _toast('After가 만들어졌습니다. 😊 이어서 미소 사진에 맞추는 중…');
      } else if (np != null && aiFail == null) {
        final v = np.verdict;
        _toast(
          v == null
              ? 'After가 만들어졌습니다.\n🦷 ${np.note}'
              : v.ok
              ? 'After가 만들어졌습니다.\n🦷 ${np.label}${np.tries > 1 ? ' · ${np.tries - 1}회 다시 만들어 맞췄습니다' : ''}'
              : 'After가 만들어졌습니다.\n🦷 ${np.tries - 1}회 다시 만들었지만 ${np.label}',
        );
      } else if (aiFail != null) {
        _toast('$aiFail\n→ 이번에는 기본 미백 방식으로 만들었습니다.');
      } else if (aiNotice != null) {
        _toast('After가 만들어졌습니다.\n$aiNotice');
      } else {
        _toast(
          '${useAi ? 'AI ' : ''}After가 만들어졌습니다. '
          '${_briefing ? '손잡이를 끌어 비교해 보세요.' : '위(치료 전)·아래(시뮬레이션)로 비교하고, 브리핑 모드에서는 손잡이로 비교할 수 있어요.'}',
        );
      }
    } catch (e) {
      _toast('After를 만들지 못했습니다. 다른 사진으로 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 브리핑 모드
  // ---------------------------------------------------------------------------
  void _setBriefing(bool on) {
    setState(() {
      _briefing = on;
      _pos = 0.5;
    });
    _setImmersive(on);
  }

  // 태블릿을 HDMI·무선으로 모니터에 연결했을 때 상태바 없이 꽉 차게
  void _setImmersive(bool on) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    SystemChrome.setEnabledSystemUIMode(
      on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  // ---------------------------------------------------------------------------
  // 상담 동의
  // ---------------------------------------------------------------------------
  /// 원본 화면(영역·선·치아 고르기)으로
  void _toEditView(PatientPhoto p) {
    if (p.editing) return;
    if (p.afterBytes != null) p.remember('Before 보기');
    p.editing = true;
    _smileView = false;
  }

  Future<void> _confirm({bool ask = true}) async {
    final p = _cur!, c = _c;
    if (c.doneAt != null) return _toast('이미 저장하고 상담을 완료했습니다.');
    if (c.name.trim().isEmpty) return _toast('환자 이름을 입력해 주세요.');
    if (c.teeth.isEmpty) return _toast('치료할 치아를 차트에서 선택해 주세요.');
    if (!_converted) return _toast('먼저 [After 변환하기]를 눌러 After를 만들어 주세요.');
    final shade = c.shade == null ? null : shadeById(c.shade!),
        teeth = sortTeeth(c.teeth);
    ScaffoldMessenger.of(context)
        .removeCurrentSnackBar(); // 알림이 떠 있는 채로 확인 창을 겹치지 않게
    final ok = !ask
        ? true
        : await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              title: const Text(
                '시뮬레이션 결과를 저장하고 상담을 완료할까요?',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.blueDeep,
                ),
              ),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.memory(p.afterBytes!, fit: BoxFit.cover),
                        ),
                      ),
                      const SizedBox(height: 14),
                      for (final kv in [
                        ('상담 날짜', formatConsultDate(c.date)),
                        ('환자', '${c.name.trim()} 님'),
                        ('사진', '${p.type} · ${p.time}'),
                        ('치료 항목', c.tx.isEmpty ? '선택 안 함' : c.tx.join(', ')),
                        (
                          '치료 부위',
                          '${teeth.map((t) => '#$t').join(' ')} (${teeth.length}개)',
                        ),
                        (
                          '희망 셰이드',
                          shade == null
                              ? '선택 안 함'
                              : '${shade.id} · ${shade.desc}',
                        ),
                        (
                          '메모',
                          c.memo.trim().isEmpty ? '(메모 없음)' : c.memo.trim(),
                        ),
                      ])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 76,
                                child: Text(
                                  kv.$1,
                                  style: const TextStyle(
                                    color: AppColors.gray500,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  kv.$2,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('취소'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(150, 46),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('저장 및 상담 완료'),
                ),
              ],
            ),
          );
    if (ok == true && mounted) {
      setState(() => c.doneAt = DateTime.now());
      // 🗂 환자 기록: 날짜 폴더 › 환자이름 폴더에 사진·상담 내용 저장
      try {
        final rec = await PatientRecords.instance.add(
          name: c.name,
          treatments: [
            for (final t in kTreatments)
              if (c.tx.contains(t)) t,
          ],
          teeth: teeth,
          shade: c.shade,
          memo: c.memo,
          photoType: p.type,
          clinic: widget.profile.clinicName,
          before: p.beforeBytes,
          smile: p.smile,
          smileAfter: p.smileAfter,
          results: [
            for (var i = 0; i < p.results.length; i++)
              (
                bytes: p.results[i].bytes,
                label: _label(p, i + 1),
                engine: p.results[i].engine,
                check: p.results[i].check,
              ),
          ],
        );
        p.recordId = rec.id;
        if (!mounted) return;
        setState(() {
          // PC 화면에도 알림
          _notice =
              '💾 ${c.name} 님 결과를 저장하고 상담을 완료했습니다 · 🗂 ${rec.dayText} › ${rec.name}';
          _noticeAt = DateTime.now().millisecondsSinceEpoch;
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                '${c.name} 님 결과를 저장하고 상담을 완료했습니다.\n🗂 ${rec.dayText} › ${rec.name} 폴더',
              ),
              action: SnackBarAction(
                label: '기록 보기',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RecordsScreen()),
                ),
              ),
            ),
          );
      } catch (e) {
        _toast('상담은 완료했지만 환자 기록을 저장하지 못했습니다. ($e)');
      }
    }
  }

  void _resetConsult() {
    final p = _cur!;
    setState(() {
      p.consult
        ..tx.clear()
        ..teeth.clear()
        ..memo = ''
        ..strength = 90
        ..doneAt = null
        ..name = p.isUpload ? '' : p.name;
      p.resetView();
      _nameCtrl.text = p.name;
      _memoCtrl.clear();
    });
    _toast('${p.name} 님의 상담 내용을 초기화했습니다.');
  }

  // PC 에도 같은 알림을 띄움 (불러오기·빼기 등이 됐는지 PC 에서도 보이게)
  String _notice = '';
  int _noticeAt = 0;

  void _toast(String msg) {
    if (!mounted) return;
    setState(() {
      _notice = msg;
      _noticeAt = DateTime.now().millisecondsSinceEpoch;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          width: MediaQuery.sizeOf(context).width > 700 ? 520 : null,
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // 화면
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _briefing ? _setBriefing(false) : null,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: _appBar(),
          body: _cur == null
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, c) {
                    final wide = c.maxWidth >= 1100 && c.maxHeight >= 600;
                    if (_newUi && !_briefing) return _stepLayout(wide, c);
                    return wide ? _wideLayout() : _narrowLayout(c);
                  },
                ),
        ),
      ),
    );
  }

  bool get _pro => widget.mode == SimMode.expert;

  /// [← 홈으로]: 직접 올린 사진이 있으면 한 번 확인
  Future<void> _goHome() async {
    final nav = Navigator.of(context);
    if (_patients.any((p) => p.isUpload)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('홈으로 나갈까요?'),
          content: const Text('지금 등록한 환자 사진과 시뮬레이션 결과는 저장되지 않고 사라집니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('홈으로'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (_briefing) _setImmersive(false);
    CastService.instance.clearImages();
    nav.pop();
  }

  void _openArchive() =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ArchiveScreen()));

  void _openRecords() =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const RecordsScreen()));

  void _logout() {
    if (_briefing) _setImmersive(false);
    CastService.instance.clearImages();
    Navigator.of(context)
        .pushAndRemoveUntil(smoothRoute(const LoginScreen()), (_) => false);
  }

  PreferredSizeWidget _appBar() {
    final phone = MediaQuery.sizeOf(context).width < 600;
    final narrow = MediaQuery.sizeOf(context).width < 1100;
    final canHome = Navigator.of(context).canPop();
    final roomy = MediaQuery.sizeOf(context).width >= 1100;
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      titleSpacing: canHome ? 4 : 16,
      automaticallyImplyLeading: false,
      leadingWidth: canHome ? (roomy ? 110 : 48) : null,
      leading: !canHome
          ? null
          : !roomy
          ? IconButton(
              tooltip: '홈으로',
              onPressed: _goHome,
              icon: const Icon(Icons.arrow_back_rounded),
            )
          : Padding(
              padding: const EdgeInsets.only(left: 10),
              child: TextButton.icon(
                onPressed: _goHome,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('홈으로'),
              ),
            ),
      title: Row(
        children: [
          if (!phone) ...[const AppLogo(size: 36), const SizedBox(width: 10)],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        phone && _pro ? 'B&A' : 'B&A 치과 시뮬레이터',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: AppColors.blueDeep,
                        ),
                      ),
                    ),
                    if (_pro) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: '전문가용',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.blueDeep,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            phone ? 'PRO' : 'PRO (전문가용)',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  '${widget.profile.clinicName} · ${widget.profile.role}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.gray500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (!narrow)
          _barButton(
            Icons.add_box_outlined,
            '＋ 새 작업',
            phone,
            _cur == null ? null : _newCase,
          ),
        if (!narrow)
          IconButton(
            tooltip: _newUi ? '예전 화면으로 (모든 기능)' : '새 단계 화면으로',
            onPressed: _toggleUi,
            icon: Icon(
              _newUi ? Icons.view_quilt_outlined : Icons.linear_scale_rounded,
              color: AppColors.blue,
            ),
          ),
        CastButton(iconOnly: phone),
        if (_pro)
          _barButton(
            Icons.smart_toy_outlined,
            '🤖 자동 QA',
            narrow,
            _cur == null ? null : _openQa,
          ),
        if (_pro && !narrow)
          _barButton(
            Icons.collections_bookmark_outlined,
            '📚 보관함',
            true,
            _openArchive,
          ),
        _barButton(
          Icons.folder_shared_outlined,
          '🗂 환자 기록',
          MediaQuery.sizeOf(context).width < 1400,
          _openRecords,
        ),
        if (narrow)
          // 좁은 화면: 자주 안 쓰는 버튼은 [더보기] 메뉴로
          PopupMenuButton<String>(
            tooltip: '더보기',
            icon: const Icon(Icons.more_vert_rounded, color: AppColors.blue),
            color: Colors.white,
            surfaceTintColor: Colors.transparent,
            onSelected: (v) => switch (v) {
              'new' => _cur == null ? null : _newCase(),
              'ui' => _toggleUi(),
              'archive' => _openArchive(),
              'reset' => _cur == null ? null : _resetConsult(),
              _ => _logout(),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'new',
                child: ListTile(
                  leading: Icon(Icons.add_box_outlined),
                  title: Text('＋ 새 작업'),
                ),
              ),
              PopupMenuItem(
                value: 'ui',
                child: ListTile(
                  leading: const Icon(Icons.view_quilt_outlined),
                  title: Text(_newUi ? '예전 화면으로' : '새 단계 화면으로'),
                ),
              ),
              if (_pro)
                const PopupMenuItem(
                  value: 'archive',
                  child: ListTile(
                    leading: Icon(Icons.collections_bookmark_outlined),
                    title: Text('📚 프롬프트 보관함'),
                  ),
                ),
              PopupMenuItem(
                value: 'reset',
                enabled: _cur != null,
                child: const ListTile(
                  leading: Icon(Icons.restart_alt_rounded),
                  title: Text('상담 초기화'),
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout_rounded),
                  title: Text('로그아웃'),
                ),
              ),
            ],
          )
        else ...[
          _barButton(
            Icons.restart_alt_rounded,
            '상담 초기화',
            false,
            _cur == null ? null : _resetConsult,
          ),
          _barButton(Icons.logout_rounded, '로그아웃', false, _logout),
        ],
        const SizedBox(width: 8),
      ],
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: AppColors.gray200),
      ),
    );
  }

  Widget _barButton(
    IconData icon,
    String label,
    bool iconOnly,
    VoidCallback? onTap,
  ) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: iconOnly
        ? IconButton(
            tooltip: label,
            onPressed: onTap,
            icon: Icon(icon, color: AppColors.blue),
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
  );

  // PC·태블릿 가로: 스크롤 없이 화면을 채움
  Widget _wideLayout() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _viewerCard(fill: true)),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOut,
                  width: _briefing ? 0 : 400,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: 400,
                      maxWidth: 400,
                      child: AnimatedOpacity(
                        opacity: _briefing ? 0 : 1,
                        duration: const Duration(milliseconds: 250),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 20),
                          child: _panel(scrollable: true),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 폰·태블릿 세로: 위에서 아래로 스크롤
  Widget _narrowLayout(BoxConstraints c) {
    final pad = c.maxWidth < 600 ? 12.0 : 20.0;
    final w = c.maxWidth - pad * 2 - 24;
    final phone = c.maxWidth < 700;
    double stageH;
    if (_briefing) {
      stageH = (c.maxHeight - 190).clamp(320.0, 2000.0);
    } else if (_mode == _ViewMode.stack) {
      stageH = phone ? w * 0.75 * 2 + 8 : c.maxHeight * 0.68;
    } else {
      stageH = phone ? w * 4 / 3 : c.maxHeight * 0.55;
    }
    return SingleChildScrollView(
      controller: _scroll,
      padding: EdgeInsets.all(pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _viewerCard(fill: false, stageHeight: stageH),
          if (!_briefing) ...[
            const SizedBox(height: 14),
            _panel(scrollable: false),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2) 비교 뷰어
  // ---------------------------------------------------------------------------
  Widget _viewerCard({required bool fill, double? stageHeight}) {
    final p = _cur!;
    final mode = _mode;
    Widget stage = switch (mode) {
      _ViewMode.edit => RoiEditor(
        bytes: p.beforeBytes,
        imageSize: p.imageSize,
        roi: p.roi,
        onChanged: (r) => setState(() => p.roi = r),
        showRoi: !_useAi, // AI 사용 시: 영역 표시 없이 사진만 (순수 프롬프트)
        lines: p.lines,
        onLineAdd: _drawLines && _useAi && _c.doneAt == null
            ? (l) => _lineAdd(p, l)
            : null,
        onLineErase: (path, r) => _lineErase(p, path, r),
        onLineUndo: p.lineHistory.isEmpty ? null : () => _lineUndo(p),
        onLineClear: () => _lineClear(p),
        onLineSmooth: () => _lineSmooth(p),
        showIncisal: _noPrep,
        samOverlay: p.samOverlay,
        onSamTap: _samOn && _c.doneAt == null ? (pt) => _samTap(p, pt) : null,
        samBusy: _samBusy,
        samCount: p.sam.length,
        onSamUndo: p.samHistory.isEmpty ? null : () => _samUndo(p),
        onSamClear: () => _samClear(p),
        onSamBrush: (st) => _samBrush(p, st),
        samMarks: [
          for (final t in p.sam)
            (label: t.label, zenith: t.zenith, incisal: t.incisal),
        ],
        onSamMark: (i, inc, pt) => _samMark(p, i, inc, pt),
      ),
      _ViewMode.stack ||
      _ViewMode.slider when p.compare.length == 1 => _SinglePhoto(
        bytes: p.bytesOf(p.compare.first),
        title: _label(p, p.compare.first),
        sub: _sub(p, p.compare.first),
        fit: _fit,
        overlay: _overlayFor(p, p.compare.first),
      ),
      _ViewMode.stack => StackedCompare(
        before: p.bytesOf(p.compare[0]),
        after: p.bytesOf(p.compare[1]),
        fit: _fit,
        beforeTitle: _label(p, p.compare[0]),
        beforeSub: _sub(p, p.compare[0]),
        afterTitle: _label(p, p.compare[1]),
        afterSub: _sub(p, p.compare[1]),
        afterOverlay: _overlayFor(p, p.compare[1]),
      ),
      _ViewMode.slider => SliderCompare(
        before: p.bytesOf(p.compare[0]),
        after: p.bytesOf(p.compare[1]),
        fit: _fit,
        position: _pos,
        onChanged: (v) => setState(() => _pos = v),
        beforeTitle: _label(p, p.compare[0]),
        beforeSub: _sub(p, p.compare[0]),
        afterTitle: _label(p, p.compare[1]),
        afterSub: _sub(p, p.compare[1]),
        afterOverlay: _overlayFor(p, p.compare[1]),
      ),
    };
    // 😊 미소 비교: 원본 미소 ↔ 시뮬레이션 미소
    if (_smileView &&
        mode != _ViewMode.edit &&
        p.smile != null &&
        p.smileAfter != null) {
      stage = mode == _ViewMode.slider
          ? SliderCompare(
              before: p.smile!,
              after: p.smileAfter!,
              fit: BoxFit.contain,
              position: _pos,
              onChanged: (v) => setState(() => _pos = v),
              beforeTitle: '미소',
              beforeSub: '치료 전',
              afterTitle: '미소 미리보기',
              afterSub: p.smileFrom,
            )
          : StackedCompare(
              before: p.smile!,
              after: p.smileAfter!,
              fit: BoxFit.contain,
              beforeTitle: '미소',
              beforeSub: '치료 전',
              afterTitle: '미소 미리보기',
              afterSub: p.smileFrom,
            );
    }
    // 브리핑 모드: 왼쪽에 원본 + 변환 결과 목록 (체크해서 비교할 사진 고르기)
    // 왼쪽 '비교할 사진' 목록: 브리핑이 아닐 때도 (불러온 사진 확인·고르기) — 폰처럼 좁으면 브리핑에서만
    final listOn = _newUi
        ? (_briefing || (_step >= 4 && MediaQuery.sizeOf(context).width >= 700))
        : (_briefing || MediaQuery.sizeOf(context).width >= 700);
    if (listOn) {
      stage = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _comparePicker(p),
          const SizedBox(width: 10),
          Expanded(child: stage),
        ],
      );
    }
    if (_converting) {
      stage = Stack(
        fit: StackFit.expand,
        children: [
          stage,
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ColoredBox(
              color: const Color(0x99081222),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _convertMsg,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    final howto = switch (mode) {
      _ViewMode.edit =>
        _useAi
            ? '상담 가이드의 [AI 요청 내용]을 확인하고 [After 변환하기] · 확대: 두 손가락/마우스 휠/＋ 버튼'
            : '점선 영역을 끌어 치아에 맞추기 · 모서리 점으로 크기 조절 · 상담 가이드에서 [After 변환하기]',
      _ViewMode.stack =>
        '위: 치료 전 · 아래: 시뮬레이션 결과 · [환자 브리핑 모드]를 켜면 손잡이를 끌어 한 화면에서 비교',
      _ViewMode.slider => '가운데 손잡이를 좌우로 끌어 비교 · 탭하면 바로 이동 · PC: ← → 키, Esc로 종료',
    };
    return _card(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _viewerHead(p, mode),
          const SizedBox(height: 10),
          if (!_briefing && !_newUi) ...[
            _slotBar(p),
            const SizedBox(height: 10),
          ],
          if (fill)
            Expanded(child: stage)
          else
            SizedBox(height: stageHeight, child: stage),
          const SizedBox(height: 10),
          if (_briefing)
            _briefInfo()
          else
            Text(
              howto,
              style: const TextStyle(fontSize: 12, color: AppColors.gray500),
            ),
          if (!_briefing && _useAi && !_newUi) _guideCheck(p),
          if (!_newUi &&
              mode != _ViewMode.edit &&
              (_converted || _rzTargetOf(p) != null))
            _resultTools(p),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // A⑤ 원본 윤곽 겹쳐 보기 · B② 치아 크기 조절
  // ---------------------------------------------------------------------------
  bool _showContour = true;
  final Map<int, Uint8List> _contourPng = {};
  final Set<int> _contourBusy = {};

  List<GuideLine> _contourLines(PatientPhoto p) => p.hasSam
      ? contourLines(p.sam)
      : [
          if (p.lines.incisalLines.isNotEmpty) ...p.lines.cervical,
          ...p.lines.incisalLines,
        ];

  /// 원본의 마진선(초록)·절단선(노랑) 점선 PNG — 없으면 null (만드는 중이면 다음 화면에)
  Uint8List? _contourFor(PatientPhoto p) {
    if (!_showContour) return null;
    final lines = _contourLines(p);
    if (lines.isEmpty) return null;
    final key = Object.hash(p.id, linesHash(lines));
    final hit = _contourPng[key];
    if (hit != null || _contourBusy.contains(key)) return hit;
    _contourBusy.add(key);
    final w = p.imageSize.width.round(), h = p.imageSize.height.round();
    compute((a) => contourOverlayPng(a.$1, a.$2, a.$3), (lines, w, h)).then((
      png,
    ) {
      _contourBusy.remove(key);
      if (mounted) setState(() => _contourPng[key] = png);
    });
    return null;
  }

  Widget _resultTools(PatientPhoto p) {
    final hasContour = _contourLines(p).isNotEmpty;
    final canResize =
        !_briefing && _useAi && _c.doneAt == null && _rzTargetOf(p) != null;
    final hasSmile = p.smileAfter != null && p.smile != null;
    if (!hasContour && !canResize && !hasSmile) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (hasContour)
            FilterChip(
              avatar: const Icon(Icons.timeline, size: 18),
              label: const Text('원본 윤곽 겹쳐 보기'),
              tooltip: '시뮬레이션 위에 원본의 마진선(초록)·절단선(노랑)을 점선으로 겹쳐 길이·마진 유지를 확인',
              selected: _showContour,
              onSelected: (v) => setState(() => _showContour = v),
            ),
          if (canResize)
            OutlinedButton.icon(
              onPressed: () => _openResize(p),
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
              label: const Text('🦷 치아 크기 조절'),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 상담 PC 에서 변환된 사진 치아 크기 조절 (태블릿이 계산, PC 는 조작·미리보기)
  // ---------------------------------------------------------------------------
  ResizeSession? _rz;
  int _rzVer = 0;

  int _rzN = 0; // PC 크기 조절 중인 사진 번호

  void _rzStart(PatientPhoto p) {
    final n = _rzTargetOf(p);
    if (n == null || _c.doneAt != null) return;
    _rzN = n;
    setState(
      () => _rz = ResizeSession(
        image: p.bytesOf(n),
        noPrep: _c.tx.contains(kNoPrep),
        chartTeeth: sortTeeth(_c.teeth),
        teeth: n > 0
            ? [
                for (final t in p.sam)
                  (label: t.label, box: t.box, upper: t.upper),
              ]
            : const [],
        masks: n > 0 ? [for (final t in p.sam) t.mask] : const [],
      ),
    );
    _rzPreview();
  }

  Future<void> _rzTap(Offset pt) async {
    final rz = _rz;
    if (rz == null || rz.busy) return;
    final f = rz.tap(pt, falKey: PipelineSettings.instance.falKey);
    setState(() {});
    final err = await f;
    if (!mounted || _rz != rz) return;
    setState(() {});
    if (err != null) _toast(err);
  }

  Future<void> _rzPreview() async {
    final rz = _rz;
    if (rz == null) return;
    final ver = ++_rzVer;
    final png = await rz.preview();
    if (ver != _rzVer || _rz != rz) return;
    CastService.instance.put('rzImg', {'v': ver, 'img': base64Encode(png)});
  }

  Future<void> _rzApply(PatientPhoto p) async {
    final rz = _rz;
    if (rz == null) return;
    if (!rz.changed) return _rzEnd();
    setState(() => rz.busy = true);
    final out = await rz.apply();
    if (!mounted) return;
    final n = _rzN;
    setState(() {
      _rz = null;
      _rzAddResult(p, n, out);
    });
    CastService.instance.put('rzImg', null);
    _toast(_rzDoneMsg(p, n));
  }

  void _rzEnd() {
    setState(() => _rz = null);
    CastService.instance.put('rzImg', null);
  }

  /// 지금 비교 화면에 보이는 변환 결과 (없으면 마지막 결과)
  Uint8List? _shownAfter(PatientPhoto p) {
    final n = p.compare.where((i) => i > 0).lastOrNull;
    return n == null ? p.afterBytes : p.bytesOf(n);
  }

  bool _smileView = false;
  bool _smileMaking = false;
  String _smileMsg = '';

  /// 상담 PC 에 미소 사진 + 치아 영역 하이라이트 보내기
  Future<void> _smilePublish(PatientPhoto p) async {
    if (!mounted) return;
    setState(() {});
    if (!CastService.instance.connected || !identical(p, _cur)) return;
    // 원본 1·2 슬롯 작은 사진 (PC 카드)
    final s1 = _slot1Bytes(p), s2 = _slotPhoto(p, 2)?.beforeBytes;
    final sk = '${identityHashCode(s1)}|${identityHashCode(s2)}';
    if (sk != _slotImgKey) {
      _slotImgKey = sk;
      CastService.instance.put('slotImg', {
        if (s1 != null) 's1': await jpegBase64(s1, maxSide: 240, quality: 70),
        if (s2 != null) 's2': await jpegBase64(s2, maxSide: 240, quality: 70),
      });
    }
    final sm = p.smile;
    if (sm == null) {
      CastService.instance.put('smileImg', null);
      return;
    }
    CastService.instance.put('smileImg', {
      'id': p.id,
      'photo': await jpegBase64(sm, maxSide: 1280),
      if (p.smileSet?.overlay != null) 'ov': base64Encode(p.smileSet!.overlay!),
      if (p.smileAfter != null)
        'after': await jpegBase64(p.smileAfter!, maxSide: 1280),
      if (_mFor == p.id && _mProsth != null)
        'p2': await jpegBase64(_mProsth!, maxSide: 480, quality: 75),
      // 오늘 만든 After 작은 사진 (PC 정밀 매칭에서 고르기)
      'aft': {
        for (final a in _afterChoices(p))
          a.key: await jpegBase64(a.bytes, maxSide: 200, quality: 65),
      },
      if (_mFor == p.id && _mRes != null) ...{
        'm1': await jpegBase64(_mRes!.composite, maxSide: 1280),
        'm2': await jpegBase64(_mRes!.stage1, maxSide: 1280),
        'm3': await jpegBase64(_mRes!.finalImage, maxSide: 1280),
      },
    });
  }

  /// 😊 미소 사진을 그 환자의 기록 폴더에 저장 (기록이 아직 없으면 [저장 및 상담 완료] 때 함께 저장)
  String? _smileSavedKey;
  Future<void> _smileSave(PatientPhoto p) async {
    final id = p.recordId, sm = p.smile;
    if (id == null || sm == null) return;
    final key = '$id|${identityHashCode(sm)}|${identityHashCode(p.smileAfter)}';
    if (key == _smileSavedKey) return; // 바뀐 게 없음
    _smileSavedKey = key;
    try {
      final r = await PatientRecords.instance.saveSmile(
        id,
        sm,
        after: p.smileAfter,
      );
      if (r != null && mounted) {
        _toast('🗂 미소 사진을 ${r.dayText} › ${r.name} 폴더에 저장했습니다');
      }
    } catch (e) {
      _smileSavedKey = null;
      debugPrint('smile save: $e');
    }
  }

  Future<void> _smileRemotePhoto(PatientPhoto p, String b64) async {
    try {
      await setSmile(p, base64Decode(b64));
      _smileMsg = '미소 사진을 받았습니다';
      _smileSave(p);
      await _smilePublish(p);
      await _smileRemoteAuto(p);
    } catch (e) {
      _smileMsg = '미소 사진을 읽지 못했습니다';
      _smilePublish(p);
    }
  }

  Future<void> _smileFromRecord(PatientPhoto p, String id) async {
    await PatientRecords.instance.ensureLoaded();
    final r = PatientRecords.instance.records
        .where((x) => x.id == id)
        .firstOrNull;
    final f = r == null ? null : await readRecordFiles(r);
    if (r == null || f == null || f.smile == null) {
      _smileMsg = '그 기록에는 미소 사진이 없어요';
      _smilePublish(p);
      return;
    }
    final who = r.name.isEmpty ? '기록' : r.name;
    final sub = '환자 기록 · ${r.dayText} ${r.time}';
    p.addExtra(f.smile!, '😊 $who 미소', sub: sub);
    if (f.smileAfter != null) {
      p.addExtra(f.smileAfter!, '😊 $who 미소 미리보기', sub: sub);
    }
    await setSmile(p, f.smile!);
    _smileMsg = '환자 기록($who ${r.dayText})의 미소 사진을 불러왔어요 · 왼쪽 비교 목록에도 들어갔어요';
    _smilePublish(p);
    await _smileRemoteAuto(p);
  }

  /// 비교 목록 [사진 추가]: 갤러리(여러 장) 또는 환자 기록에서 → 불러온 차례대로 목록 끝에
  Future<void> _addCompare(PatientPhoto p) async {
    final src = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.folder_open_outlined,
                color: AppColors.blue,
              ),
              title: const Text('🗂 환자 기록 사진 (한 장씩 골라도 돼요)'),
              onTap: () => Navigator.pop(ctx, 'rec'),
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library_outlined,
                color: AppColors.blue,
              ),
              title: const Text('갤러리에서 (여러 장)'),
              onTap: () => Navigator.pop(ctx, 'gal'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (src == null || !mounted) return;
    var added = 0;
    if (src == 'rec') {
      final got = await pickRecordPhotos(context);
      if (got == null) return;
      for (final g in got) {
        if (p.hasPhoto(g.bytes)) continue;
        p.addExtra(g.bytes, g.label, sub: g.sub);
        added++;
      }
    } else {
      try {
        final fs = await _picker.pickMultiImage(
          maxWidth: 2000,
          maxHeight: 2000,
          imageQuality: 92,
        );
        for (final f in fs) {
          final k = p.extras.where((e) => e.sub == '불러온 사진').length + 1;
          p.addExtra(await f.readAsBytes(), '사진 $k', sub: '불러온 사진');
          added++;
        }
      } catch (e) {
        _toast('사진을 불러오지 못했습니다. 사진 권한을 확인해 주세요.');
        return;
      }
    }
    if (!mounted || added == 0) return;
    setState(() {});
    _toast('비교 목록에 $added장을 넣었습니다 · 눌러서 비교해 보세요');
  }

  Future<void> _smileRemoteAuto(PatientPhoto p) async {
    final set = p.smileSet;
    if (set == null) return;
    if (!MouthFinder.supported) {
      _smileMsg = '이 태블릿에서는 자동 찾기를 쓸 수 없어요 · 🪄로 치아를 클릭해 주세요';
      _smilePublish(p);
      return;
    }
    set.busy = true;
    _smilePublish(p);
    final poly = await MouthFinder.lips(set.photo);
    if (poly != null) await set.setAuto(poly);
    set.busy = false;
    _smileMsg = poly == null
        ? '입술을 찾지 못했어요 · 🪄로 치아를 클릭해 주세요'
        : '입술 사이를 자동으로 골랐어요';
    _smilePublish(p);
  }

  Future<void> _smileRemoteTap(PatientPhoto p, Offset pt) async {
    final set = p.smileSet;
    if (set == null || set.busy) return;
    final f = set.tap(pt);
    _smilePublish(p);
    final err = await f;
    _smileMsg = err ?? '';
    _smilePublish(p);
  }

  Future<void> _smileRemoteMake(PatientPhoto p) async {
    final set = p.smileSet, smile = p.smile, after = _shownAfter(p);
    if (set?.union == null || smile == null || after == null || _smileMaking) {
      return;
    }
    final n = p.compare.where((i) => i > 0).lastOrNull ?? p.results.length;
    setState(() {
      _smileMaking = true;
      _smileMsg = '😊 미소에 입히는 중…';
    });
    try {
      final out = await makeSmile(
        smile: smile,
        after: after,
        region: set!.union!,
      );
      if (!mounted) return;
      setState(() {
        p.smileAfter = out;
        p.smileFrom = _label(p, n);
        p.noteSmile();
        _smileView = true;
        _smileMsg = '완성! 미소 비교로 보여 드립니다';
      });
      _smilePublish(p);
      _smileSave(p);
    } catch (e) {
      _smileMsg = e is PipelineError
          ? e.message
          : e is AiError
          ? e.message
          : '미소에 입히지 못했어요 ($e)';
    } finally {
      if (mounted) setState(() => _smileMaking = false);
    }
  }

  // ── 🦷 보철 사진 정밀 매칭 (PC 원격) ─────────────────────────────
  String? _mFor; // 어느 환자 사진의 매칭인지
  Uint8List? _mProsth;
  String _mLabel = '';
  bool _mBusy = false;
  String _mStep = '';
  MatchResult? _mRes;
  int _mPick = 3;

  void _matchReset(PatientPhoto p) {
    if (_mFor == p.id) return;
    _mFor = p.id;
    _mProsth = null;
    _mLabel = '';
    _mStep = '';
    _mRes = null;
    _mPick = 3;
  }

  void _matchSet(PatientPhoto p, Uint8List b, String label) {
    if (_mBusy) return;
    _matchReset(p);
    _mProsth = b;
    _mLabel = label;
    _mRes = null;
    _mStep = '2번 사진 준비 완료 · [정밀 매칭 시작]을 눌러 주세요';
    _smilePublish(p);
  }

  Future<void> _matchRun(PatientPhoto p) async {
    _matchReset(p);
    final smile = p.smile, prosth = _mProsth;
    if (_mBusy) return;
    if (smile == null || prosth == null) {
      _mStep = smile == null ? '먼저 미소 사진(1번)을 올려 주세요' : '보철 사진(2번)을 골라 주세요';
      _smilePublish(p);
      return;
    }
    final run =
        debugMatchOverride ??
        (s, pr, step) => matchProsthesis(smile: s, prosth: pr, onStep: step);
    if (!DentalAligner.supported && debugMatchOverride == null) {
      _mStep = '이 기기에서는 정밀 매칭을 쓸 수 없어요 (안드로이드 태블릿 필요)';
      _smilePublish(p);
      return;
    }
    setState(() {
      _mBusy = true;
      _mRes = null;
      _mStep = '시작합니다…';
    });
    _smilePublish(p);
    try {
      final r = await run(smile, prosth, (m) {
        _mStep = m;
        _smilePublish(p);
      });
      if (!mounted) return;
      setState(() {
        _mRes = r;
        _mPick = 3;
        p.smileAfter = r.finalImage;
        p.smileFrom = '보철 사진 정밀 매칭';
        p.noteSmile();
        _smileView = identical(p, _cur);
        _mStep =
            '완성! ${r.align.summary}${r.notes.isEmpty ? '' : '\n${r.notes.join('\n')}'}';
      });
      _smileSave(p);
    } on PipelineError catch (e) {
      _mStep = '⚠ ${e.message}';
    } on AiError catch (e) {
      _mStep = '⚠ ${e.message}';
    } catch (e) {
      _mStep = '⚠ 정밀 매칭에 실패했습니다 ($e)';
    } finally {
      if (mounted) setState(() => _mBusy = false);
      _smilePublish(p);
    }
  }

  void _matchPick(PatientPhoto p, int n) {
    final r = _mRes;
    if (r == null || _mFor != p.id || n < 1 || n > 3) return;
    setState(() {
      _mPick = n;
      p.smileAfter = [r.composite, r.stage1, r.finalImage][n - 1];
      p.smileFrom = '보철 사진 정밀 매칭 (${['① 정렬 합성', '② FLUX 1차', '③ 최종'][n - 1]})';
      p.noteSmile();
      _smileView = true;
    });
    _smilePublish(p);
    _smileSave(p);
  }

  /// 😊 미소 미리보기 (변환 전에도 열림: 미소 사진·보철 사진 정밀 매칭)
  Future<void> _openSmile(PatientPhoto p) async {
    final after = _shownAfter(p);
    final n = p.compare.where((i) => i > 0).lastOrNull ?? p.results.length;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SmilePreviewScreen(
          photo: p,
          after: after,
          afterLabel: after == null ? '' : _label(p, n),
          afterChoices: [
            for (final a in _afterChoices(p)) (label: a.label, bytes: a.bytes),
          ],
        ),
      ),
    );
    if (!mounted) return;
    p.noteSmile();
    setState(() => _smileView = p.smileAfter != null);
    _smilePublish(p); // 태블릿에서 만든 미소도 PC 로
    _smileSave(p);
  }

  /// 🦷 크기 조절할 사진: 왼쪽 목록에서 마지막으로 누른 사진 (원본 1·2 는 제외)
  ///   After(변환 결과)·미소 미리보기·Final Smile·불러온 사진 모두 가능
  int? _rzTargetOf(PatientPhoto p) =>
      p.resizeTarget(orig1: _slot1Bytes(p), smileView: _smileView);

  /// 크기 조절 결과 넣기: After 였으면 새 After, 다른 사진이면 그 옆에 새 사진
  void _rzAddResult(PatientPhoto p, int n, Uint8List out) {
    if (n > 0) {
      p.remember('치아 크기 조절');
      p.addResult(out, _settingsKey(), engine: '크기조절');
      return;
    }
    final e = p.extras[-n - 1];
    final k = p.addExtra(
      out,
      '${e.label} · 크기조절',
      sub: '크기 조절',
      pair: e.pair ?? e.bytes,
    );
    p.sel = [n, k];
    p.editing = false;
    _smileView = false;
  }

  String _rzDoneMsg(PatientPhoto p, int n) => n > 0
      ? '🦷 치아 크기를 조절한 결과를 ${_label(p, p.results.length)}(으)로 추가했습니다.'
      : '🦷 치아 크기를 조절한 사진을 왼쪽 목록에 추가했습니다.';

  Future<void> _openResize(PatientPhoto p) async {
    final n = _rzTargetOf(p);
    if (n == null) return;
    final image = p.bytesOf(n);
    var size = p.imageSize;
    if (n < 0) {
      final im = await decodeImageFromList(image);
      size = Size(im.width.toDouble(), im.height.toDouble());
      im.dispose();
    }
    if (!mounted) return;
    final out = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => ToothResizeScreen(
          image: image,
          imageSize: size,
          // 같은 촬영(After)이면 고른 치아 윤곽을 그대로, 다른 사진이면 새로 탭해서 고름
          teeth: n > 0
              ? [
                  for (final t in p.sam)
                    (label: t.label, box: t.box, upper: t.upper),
                ]
              : const [],
          noPrep: _c.tx.contains(kNoPrep),
          falKey: PipelineSettings.instance.falKey,
          chartTeeth: sortTeeth(_c.teeth),
          masks: n > 0 ? [for (final t in p.sam) t.mask] : const [],
        ),
      ),
    );
    if (out == null || !mounted) return;
    setState(() => _rzAddResult(p, n, out));
    _toast(_rzDoneMsg(p, n));
  }

  /// 사진 아래: 서비컬 라인 그리기 사용 체크
  Widget _guideCheck(PatientPhoto p) {
    final n = p.lines.cervical.length, ni = p.lines.incisalLines.length;
    final check = Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: _drawLines ? AppColors.blueSoft : Colors.white,
        borderRadius: BorderRadius.circular(10),
        child: CheckboxListTile(
          value: _drawLines,
          onChanged: _c.doneAt != null
              ? null
              : (v) => setState(() {
                  _drawLines = v ?? false;
                  if (_drawLines) _toEditView(p); // 원본 화면에서 선 그리기
                }),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.gray200),
          ),
          title: const Text(
            '서비컬 라인 그려서 AI 기준 잡기',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            _drawLines
                ? '사진 왼쪽 [상악선 🟢]/[하악선 🩷]을 고르고 펜·손가락·마우스로 잇몸선을 따라 그리세요 '
                      '(두 손가락: 확대·이동)${n > 0 ? ' · 그린 선 $n개' : ''}'
                      '${_noPrep ? '\n🦷 무삭제 라미네이트: 절단선(앞니 끝선 🟡)을 기준으로 절단길이가 짧아지지 않게 보호합니다${ni > 0 ? ' · 절단선 $ni개' : ''}' : ''}'
                : '체크하면 사진 위에 상악·하악 잇몸선을 직접 그려 AI에게 기준선으로 전달합니다',
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
      ),
    );
    if (!_noPrep || !_drawLines) return check;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        check,
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _c.doneAt != null || n == 0
                    ? null
                    : () => _autoIncisal(p),
                icon: const Icon(Icons.auto_fix_high, size: 18),
                label: Text(ni > 0 ? '🦷 절단선 다시 찾기' : '🦷 절단선 자동 찾기'),
              ),
              Text(
                n == 0
                    ? '서비컬 라인을 먼저 그리면 절단선을 찾을 수 있어요'
                    : ni == 0
                    ? '변환할 때 자동으로 찾아서 씁니다'
                    : '노란 선 = 원본 절단끝 (이보다 짧아지지 않게 보호)',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.gray500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 치료 버튼 켜기/끄기. 보관함에서 '이 치료의 기본 설정으로 적용'한 값이 있으면 켤 때 자동으로 채움
  void _toggleTx(String t) {
    final c = _c;
    setState(() => toggleTreatment(c.tx, t));
    final d = TreatmentDefaults.instance.map[t];
    if (d == null || !c.tx.contains(t)) return;
    setState(() {
      _aiReqCtrl.text = d.request;
      c.strength = d.strength;
    });
    AiService.instance.saveRequest(d.request);
    _toast(
      '📚 보관함 기본값 적용: $t · 강도 ${d.strength}%${d.request.isEmpty ? '' : ' · 추가 요청 채움'}',
    );
  }

  /// 🤖 자동 QA 에이전트 열기 (지금 선택된 치료·치아·셰이드·서비컬 라인·엔진 그대로)
  /// 지금 화면 조건 그대로 자동 QA 조건 만들기 (PC 에서 시작할 때)
  QaSetup? _qaSetup(Uint8List? target) {
    final p = _cur;
    if (p == null) return null;
    final c = _c;
    return QaSetup(
      original: p.beforeBytes,
      target: target,
      treatments: [
        for (final t in kTreatments)
          if (c.tx.contains(t)) t,
      ],
      teeth: sortTeeth(c.teeth),
      shade: c.shade,
      strength: c.strength,
      request: _aiReqCtrl.text,
      lines: _useGuide ? p.lines.cervical : const [],
      lockGum: _useGuide && !c.tx.contains('잇몸 성형'),
      patientName: c.name,
      passScore: QaSession.instance.passScore,
    );
  }

  void _openQa() {
    final p = _cur!, c = _c;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QaAgentScreen(
          original: p.beforeBytes,
          treatments: [
            for (final t in kTreatments)
              if (c.tx.contains(t)) t,
          ],
          teeth: sortTeeth(c.teeth),
          shade: c.shade,
          strength: c.strength,
          request: _aiReqCtrl.text,
          lines: _useGuide ? p.lines.cervical : const [],
          lockGum: _useGuide && !c.tx.contains('잇몸 성형'),
          engine: PipelineSettings.instance.engine,
          patientName: c.name,
        ),
      ),
    );
  }

  /// 원본 / 김민수 1번 / 김민수 2번 …
  String _label(PatientPhoto p, int n) {
    if (n < 0) return -n <= p.extras.length ? p.extras[-n - 1].label : '사진';
    if (n == 0) {
      if (p.slot == 1) return '원본 1 (미소)';
      return p.pair != null ? '원본 2 (개구기)' : '원본';
    }
    final name = p.consult.name.trim();
    final r = n <= p.results.length ? p.results[n - 1] : null;
    final ck = r == null || r.check.isEmpty
        ? ''
        : r.check.startsWith('✓')
        ? ' 🦷✓'
        : ' 🦷⚠';
    // 변환 결과 = After (엔진 이름은 아래 작은 글씨로)
    return '${name.isEmpty ? '' : '$name '}After $n$ck';
  }

  /// 사진 아래 작은 글씨 (치료 전 / 시뮬레이션 / 불러온 사진 설명)
  String _sub(PatientPhoto p, int n) => n == 0
      ? '치료 전'
      : n > 0
      ? (n <= p.results.length && p.results[n - 1].engine.isNotEmpty
            ? 'After · ${p.results[n - 1].engine}'
            : 'After')
      : (-n <= p.extras.length ? p.extras[-n - 1].sub : '');

  /// 원본 윤곽 점선은 변환 결과에만
  Uint8List? _overlayFor(PatientPhoto p, int n) =>
      n > 0 ? _contourFor(p) : null;

  Widget _comparePicker(PatientPhoto p) {
    final cmp = p.compare;
    Widget item(int n) {
      final on = cmp.contains(n);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: on ? AppColors.blueSoft : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: on ? AppColors.blue : AppColors.gray200,
              width: on ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() {
              _smileView = false; // 고른 사진을 보여 줌
              p.editing = false; // 첫 화면(영역 지정)에서도 고른 사진으로
              p.toggleSel(n);
              p.noteBase(n); // 결과를 누르면 [다시 변환하기] 기준도 그 결과로
            }),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        p.bytesOf(n),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        cacheWidth: 240,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: AppColors.gray200),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        on
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded,
                        size: 18,
                        color: on ? AppColors.blue : AppColors.gray500,
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          _label(p, n),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (n != 0)
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            tooltip: '목록에서 빼기',
                            onPressed: () => _removePhoto(p, n),
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: AppColors.gray500,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              '비교할 사진\n(1~2장 체크)',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.gray500,
                height: 1.3,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final n in p.listOrder) item(n),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 40),
                  ),
                  onPressed: () => _addCompare(p),
                  icon: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 18,
                  ),
                  label: const Text('기록·사진 추가', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewerHead(PatientPhoto p, _ViewMode mode) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 19,
              backgroundColor: AppColors.blueSoft,
              child: Text(
                _c.name.trim().isEmpty ? '?' : _c.name.trim().characters.first,
                style: const TextStyle(
                  color: AppColors.blueDeep,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 사진 위에서 바로 환자 이름 입력 → 상담 가이드 이름 칸과 같은 내용(같은 컨트롤러)
                _HeadNameField(
                  controller: _nameCtrl,
                  focusNode: _headNameFocus,
                  enabled: _c.doneAt == null,
                  onChanged: (v) => setState(() => _c.name = v),
                ),
                Text(
                  '${p.type} · ${p.time} ${p.isUpload ? '등록' : '촬영'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.gray500,
                  ),
                ),
              ],
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (p.history.isNotEmpty)
              Tooltip(
                message: '${p.history.last.label} 취소',
                child: _headButton(Icons.undo_rounded, '이전으로', phone, () {
                  late String? label;
                  setState(() => label = p.undo());
                  if (label != null) _toast('↶ \'$label\' 이전 상태로 돌아갔습니다.');
                }),
              ),
            if (p.future.isNotEmpty)
              Tooltip(
                message: '${p.future.last.label} 다시 하기',
                child: _headButton(Icons.redo_rounded, '다시 돌아가기', phone, () {
                  late String? label;
                  setState(() => label = p.redo());
                  if (label != null) _toast('↷ \'$label\' 상태로 다시 돌아갔습니다.');
                }),
              ),
            if (!_newUi)
              _headButton(
                Icons.photo_camera_outlined,
                '환자 사진 등록',
                phone,
                _choosePhoto,
              ),
            // 변환하기 전에도: 예전에 변환했던 기록 불러오기 · 미소 미리보기
            if (!_newUi)
              _headButton(
                Icons.history_rounded,
                '이전 변환 불러오기',
                phone,
                _openRecords,
              ),
            if (!_briefing && !_newUi)
              _headButton(
                Icons.sentiment_very_satisfied_outlined,
                p.smile == null ? '😊 미소 미리보기' : '😊 미소 미리보기 다시',
                phone,
                () => _openSmile(p),
              ),
            if (mode != _ViewMode.edit)
              _headButton(
                Icons.crop_free_rounded,
                _useAi ? '처음 사진 보기' : '영역 다시 지정',
                phone,
                () => setState(() {
                  p.remember('Before 보기');
                  p.editing = true;
                }),
              ),
            if (mode != _ViewMode.edit)
              IconButton.outlined(
                tooltip: _fit == BoxFit.cover ? '사진 전체 보기' : '화면 꽉 채우기',
                onPressed: () => setState(
                  () => _fit = _fit == BoxFit.cover
                      ? BoxFit.contain
                      : BoxFit.cover,
                ),
                icon: const Icon(
                  Icons.fit_screen_outlined,
                  size: 20,
                  color: AppColors.blue,
                ),
              ),
            if (mode == _ViewMode.slider)
              IconButton.outlined(
                tooltip: '손잡이 가운데로',
                onPressed: () => setState(() => _pos = 0.5),
                icon: const Icon(
                  Icons.vertical_align_center_rounded,
                  size: 20,
                  color: AppColors.blue,
                ),
              ),
            _BriefingToggle(on: _briefing, onChanged: _setBriefing),
          ],
        ),
      ],
    );
  }

  Widget _headButton(
    IconData icon,
    String label,
    bool iconOnly,
    VoidCallback onTap,
  ) => iconOnly
      ? IconButton.outlined(
          tooltip: label,
          onPressed: onTap,
          icon: Icon(icon, size: 20, color: AppColors.blue),
        )
      : OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40)),
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label),
        );

  // 브리핑 모드: 사진 아래에 환자 요약 (얼굴을 가리지 않게)
  Widget _briefInfo() {
    final c = _c, sid = c.shade, teeth = sortTeeth(c.teeth);
    final shade = sid == null ? null : shadeById(sid);
    Widget pill(Widget child) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.blueSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          color: AppColors.blueDeep,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        child: child,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.gray200),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${c.name} 님',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          for (final t in c.tx) pill(Text(t)),
          if (teeth.isNotEmpty) pill(Text(teethSummary(teeth))),
          if (shade != null)
            pill(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: shade.chip,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.black12),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text('셰이드 ${shade.id}'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 3·4) 상담 가이드 패널
  // ---------------------------------------------------------------------------
  /// 단계 화면에서 쓰는 패널 조각 (0 머리 · 1 이름 · 2 치료 항목 · 3 치료 부위 · 4 셰이드 · 5 변환 · 6 메모 · 7 저장 · 8 안내)
  Widget _panelParts(bool locked, Set<int> only) =>
      _panel(scrollable: false, only: only);

  Widget _panel({required bool scrollable, Set<int>? only}) {
    final c = _c, locked = c.doneAt != null;
    final teeth = sortTeeth(c.teeth);
    final children = <Widget>[
      Row(
        children: [
          const Icon(Icons.assignment_outlined, color: AppColors.blue),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '상담 가이드',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.blueDeep,
              ),
            ),
          ),
          // 상담 날짜
          Tooltip(
            message: '상담 날짜',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.gray50,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.gray200),
              ),
              child: Text(
                '📅 ${formatConsultDate(c.date)}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ),
          ),
        ],
      ),
      _sec(
        '환자 이름',
        null,
        TextField(
          controller: _nameCtrl,
          enabled: !locked,
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.person_outline_rounded),
          ),
          onChanged: (v) => setState(() => c.name = v),
        ),
      ),
      _sec(
        '치료 항목',
        null,
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in kTreatments)
              _Chip(
                label: t,
                on: c.tx.contains(t),
                onTap: locked ? null : () => _toggleTx(t),
              ),
          ],
        ),
      ),
      _sec(
        '치료 부위',
        '치아를 눌러 선택하세요 (환자 기준 좌·우)',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _QuickButton(
                  '상악 앞니 6개',
                  locked ? null : () => _toggleGroup(kUpper6),
                ),
                _QuickButton(
                  '하악 앞니 6개',
                  locked ? null : () => _toggleGroup(kLower6),
                ),
                _QuickButton(
                  '선택 해제',
                  locked ? null : () => setState(() => c.teeth.clear()),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.blueSoft.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.gray200),
              ),
              child: Center(
                child: DentalChart(
                  selected: c.teeth,
                  enabled: !locked,
                  onToggle: (t) => setState(
                    () => c.teeth.contains(t)
                        ? c.teeth.remove(t)
                        : c.teeth.add(t),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            teeth.isEmpty
                ? const Text(
                    '선택된 치아가 없습니다',
                    style: TextStyle(fontSize: 13, color: AppColors.gray500),
                  )
                : Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '선택 ${teeth.length}개 ',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      for (final t in teeth)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.blueSoft,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '#$t',
                            style: const TextStyle(
                              color: AppColors.blueDeep,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
          ],
        ),
      ),
      _sec(
        '희망 셰이드',
        '환자와 함께 색을 보고 고르세요 · 한 번 더 누르면 선택 해제 (색 강제 적용 안 함)',
        ShadePicker(
          value: c.shade,
          enabled: !locked,
          onChanged: (s) =>
              setState(() => c.shade = s), // 같은 칩을 다시 누르면 해제(null)
        ),
      ),
      _convertBox(locked),
      _sec(
        '상담 메모',
        null,
        TextField(
          controller: _memoCtrl,
          enabled: !locked,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: '예) 치료 기간 약 3주, 비용 안내 완료',
          ),
          onChanged: (v) => setState(() => c.memo = v), // PC 메모 칸과 실시간 공유
        ),
      ),
      if (!locked)
        FilledButton.icon(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(62),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          onPressed: _converted ? _confirm : null,
          icon: const Icon(Icons.verified_user_outlined),
          label: const Text('시뮬레이션 결과 저장 및 상담 완료', textAlign: TextAlign.center),
        )
      else
        _doneBanner(c),
      const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.gray500),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '1단계 앱: 사진과 상담 내용은 이 기기 안에서만 처리되며 서버로 전송되지 않습니다.',
              style: TextStyle(fontSize: 12, color: AppColors.gray500),
            ),
          ),
        ],
      ),
    ];
    final shown = only == null
        ? children
        : [
            for (var i = 0; i < children.length; i++)
              if (only.contains(i)) children[i],
          ];
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: 18),
          shown[i],
        ],
      ],
    );
    if (only != null) return body;
    return _card(
      padding: const EdgeInsets.all(18),
      child: scrollable ? SingleChildScrollView(child: body) : body,
    );
  }

  void _toggleGroup(List<int> g) {
    setState(() {
      final all = g.every(_c.teeth.contains);
      for (final t in g) {
        all ? _c.teeth.remove(t) : _c.teeth.add(t);
      }
    });
  }

  /// 지금 선택으로 AI 에 보낼 전체 지시문 / 화면 요약
  String _aiPrompt({String extra = ''}) => ClinicalPrompt.build(
    treatments: _c.tx,
    teeth: sortTeeth(_c.teeth),
    shade: _c.shade,
    strength: _c.strength,
    hasGuide: _useGuide,
    guideUpper: _useGuide && _cur!.lines.cervical.any((l) => l.upper),
    guideLower: _useGuide && _cur!.lines.cervical.any((l) => !l.upper),
    request: [
      _aiReqCtrl.text.trim(),
      extra.trim(),
    ].where((e) => e.isNotEmpty).join('\n'),
  );
  List<String> _aiSummary() => ClinicalPrompt.summary(
    treatments: _c.tx,
    teeth: sortTeeth(_c.teeth),
    shade: _c.shade,
    hasGuide: _useGuide,
    guideUpper: _useGuide && _cur!.lines.cervical.any((l) => l.upper),
    guideLower: _useGuide && _cur!.lines.cervical.any((l) => !l.upper),
  );

  void _showPrompt() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'AI에 보낼 전체 지시',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            child: SelectableText(
              _aiPrompt(),
              style: const TextStyle(fontSize: 12.5, height: 1.55),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Widget _aiRow(bool locked) {
    final row = _aiSwitchRow(locked);
    if (!_useAi) return row;
    final empty = _aiReqCtrl.text.trim().isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        const SizedBox(height: 8),
        // 치료 항목·부위·셰이드·서비컬 라인으로 자동 조합되는 임상 지시
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
          decoration: BoxDecoration(
            color: AppColors.blueSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '자동 임상 지시 (치료 항목·부위·셰이드 기준)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppColors.blueDeep,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _showPrompt,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text(
                      '전체 지시 보기',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              for (final l in _aiSummary())
                Text(
                  '＋ $l',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.blueDeep,
                    height: 1.45,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              child: Text(
                '추가 요청 (선택 · 직접 입력 · 한글 OK)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            if (!empty)
              TextButton(
                onPressed: locked
                    ? null
                    : () {
                        _aiReqCtrl.clear();
                        AiService.instance.saveRequest('');
                        setState(() {});
                      },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('지우기', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        TextField(
          controller: _aiReqCtrl,
          enabled: !locked,
          minLines: 2,
          maxLines: 5,
          style: const TextStyle(fontSize: 13, height: 1.4),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.all(10),
            hintText: '자동 임상 지시에 더할 내용 (예: 11, 21 길이 1mm 늘리고 정중선 맞추기)',
          ),
          onChanged: (v) {
            AiService.instance.saveRequest(v);
            setState(() {});
          },
        ),
      ],
    );
  }

  /// AI 시뮬레이션 엔진 고르기 (옵션 A·B·C·단독 중 하나) — 같은 사진으로 바꿔 가며 비교
  Widget _aiSwitchRow(bool locked) {
    final ready = AiService.instance.ready;
    final st = PipelineSettings.instance;
    final eff = _engineNow();
    Widget option(Engine e) {
      final on = st.engine == e;
      final needKey =
          (e != Engine.solo && !st.hasFal) || (e == Engine.c && !st.hasVertex);
      return Material(
        color: on ? AppColors.blueSoft : Colors.white,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: locked
              ? null
              : () => setState(() {
                  st.setEngine(e);
                }),
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: on ? AppColors.blue : AppColors.gray200,
                width: on ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                Radio<Engine>(
                  value: e,
                  enabled: !locked,
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${e.tag} · ${e.label}',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: on ? AppColors.blueDeep : AppColors.ink,
                        ),
                      ),
                      Text(
                        needKey ? '${e.desc} · ⚠ API 키 필요' : e.desc,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: needKey
                              ? const Color(0xFFB25E00)
                              : AppColors.gray500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.gray200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('🤖', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'AI 시뮬레이션 엔진 (하나 선택)',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
                ),
              ),
              TextButton(
                onPressed: () =>
                    showAiSettingsSheet(context).then((_) => setState(() {})),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('API 키 설정', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (!ready)
            const Padding(
              padding: EdgeInsets.fromLTRB(2, 0, 2, 6),
              child: Text(
                'AI 연결 준비 안 됨 → 기본 미백 방식(색만 변경)으로 만들어요',
                style: TextStyle(fontSize: 11.5, color: Color(0xFFB25E00)),
              ),
            )
          else if (!_useAiPref)
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'AI 꺼짐 · 기본 미백 방식(색만 변경)',
                    style: TextStyle(fontSize: 12, color: AppColors.gray500),
                  ),
                ),
                TextButton(
                  onPressed: locked
                      ? null
                      : () => setState(() => _useAiPref = true),
                  child: const Text('AI 켜기'),
                ),
              ],
            )
          else ...[
            RadioGroup<Engine>(
              groupValue: st.engine,
              onChanged: (v) {
                if (!locked && v != null) {
                  setState(() {
                    st.setEngine(v);
                  });
                }
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final e in Engine.values) ...[
                    option(e),
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
            Text(
              eff.note != null && st.engine != Engine.solo
                  ? '⚠ ${eff.note}'
                  : eff.engine == Engine.solo
                  ? '나노바나나 2.1 한 번으로 변환 · 1회 약 50원(크레딧)'
                  : '1단계 FLUX(마진·형태 고정) → 2단계 ${eff.engine.finisher}(리얼리즘 마무리)',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: eff.note != null && st.engine != Engine.solo
                    ? const Color(0xFFB25E00)
                    : AppColors.blueDeep,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: locked
                    ? null
                    : () => setState(() => _useAiPref = false),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text(
                  'AI 끄기 (기본 미백)',
                  style: TextStyle(fontSize: 11.5, color: AppColors.gray500),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── 🖼 원본 2슬롯: 원본 1(자연스러운 미소) · 원본 2(개구기) ─────────────
  PatientPhoto? _slotPhoto(PatientPhoto p, int k) {
    final q = p.slot == k ? p : (p.pair?.slot == k ? p.pair : null);
    return q == null || q.blank ? null : q;
  }

  /// 원본 1(미소) 사진: 슬롯 1 사진, 없으면 미소 미리보기에 넣은 미소 사진
  Uint8List? _slot1Bytes(PatientPhoto p) =>
      _slotPhoto(p, 1)?.beforeBytes ?? (p.slot == 2 ? p.smile : null);

  /// 2단계에 쓸 After: 지금 사진의 After, 없으면 짝 사진의 After
  Uint8List? _finalAfter(PatientPhoto p) =>
      _shownAfter(p) ?? (p.pair == null ? null : _shownAfter(p.pair!));

  bool _finalReady(PatientPhoto p) =>
      _slot1Bytes(p) != null && _finalAfter(p) != null && !_finalBusy;

  /// 오늘 만든 After 목록: 이 사진·짝 사진(원본 1·2)의 변환 결과 + 크기조절·After 가 붙은 사진
  List<({String key, String label, Uint8List bytes})> _afterChoices(
    PatientPhoto p,
  ) {
    final out = <({String key, String label, Uint8List bytes})>[];
    void addAll(PatientPhoto q, String pre) {
      for (var n = 1; n <= q.results.length; n++) {
        out.add((
          key: '$pre$n',
          label: pre == 'q' ? '${_label(q, n)} (원본 ${q.slot})' : _label(q, n),
          bytes: q.results[n - 1].bytes,
        ));
      }
    }

    addAll(p, 'p');
    final q = p.pair;
    if (q != null) addAll(q, 'q');
    for (var i = 0; i < p.extras.length; i++) {
      final e = p.extras[i];
      if (e.sub == '크기 조절' || e.label.contains('After')) {
        out.add((key: 'e$i', label: e.label, bytes: e.bytes));
      }
    }
    return out;
  }

  bool _finalBusy = false;
  String? _slotImgKey;
  String _finalMsg = '';

  Future<PatientPhoto> _makeSlotPhoto(
    Uint8List bytes,
    int k,
    Consult consult,
  ) async {
    final im = await decodeImageFromList(bytes);
    _uploadSeq++;
    final np = PatientPhoto(
      id: 'u$_uploadSeq',
      name: consult.name.isEmpty ? '새 환자 $_uploadSeq' : consult.name,
      type: k == 1 ? '원본 1 · 자연스러운 미소' : '원본 2 · 개구기',
      time: '방금',
      beforeBytes: bytes,
      imageSize: Size(im.width.toDouble(), im.height.toDouble()),
      sharedConsult: consult,
      slot: k,
    );
    im.dispose();
    return np;
  }

  /// 슬롯에 사진 넣기 (빈 슬롯 → 짝으로 추가 / 찬 슬롯 → 그 슬롯 사진을 새로 바꿈)
  Future<void> _setSlot(
    PatientPhoto p,
    int k,
    Uint8List bytes, {
    bool fromPc = false,
    bool mask = true, // 돌리기처럼 이미 가린 사진이면 false
    String? note,
  }) async {
    // 옆으로 누운 사진(EXIF 방향)은 바로 세움
    var data = await compute(normalizeOrientation, bytes);
    if (mask && k == 2 && _eyeMask && EyeMasker.supported) {
      try {
        data = await EyeMasker.mask(bytes) ?? bytes; // 개구기 사진만 눈 가리기
      } catch (e) {
        debugPrint('eye mask: $e');
      }
    }
    final old = _slotPhoto(p, k) ?? (p.blank && p.slot == k ? p : null);
    final other = _slotPhoto(p, k == 1 ? 2 : 1);
    final np = await _makeSlotPhoto(data, k, p.consult);
    if (!mounted) return;
    np.recordId = p.recordId;
    np.pair = other;
    if (other != null) other.pair = np;
    final i = old == null ? -1 : _patients.indexOf(old);
    if (i >= 0) {
      _patients[i] = np;
    } else {
      _patients.insert(math.max(0, _patients.indexOf(p) + 1), np);
    }
    // 원본 2(개구기) 쪽 미소 사진 = 원본 1 (미소 미리보기·정밀 매칭·참고 변환에 씀)
    final s2 = k == 2 ? np : other;
    if (s2 != null && k == 1) await setSmile(s2, data);
    if (k == 2 && other != null && np.smile == null) {
      await setSmile(np, other.beforeBytes);
    }
    if (!mounted) return;
    if (identical(old, p) || p.blank) {
      // 지금 보던 슬롯을 바꿨거나 [새 작업] 빈 자리면 새 사진으로
      if (p.blank && !identical(old, p)) _patients.remove(p);
      _select(np);
    } else {
      setState(() {});
    }
    _smilePublish(_cur!);
    _toast(
      note ??
          '${fromPc ? 'PC에서 ' : ''}원본 $k(${k == 1 ? '자연스러운 미소' : '개구기'}) 사진을 넣었습니다'
              '${identical(_cur, np) ? '' : ' · 카드를 누르면 그 사진을 변환할 수 있어요'}',
    );
  }

  /// ⟳ 원본 사진 돌리기 (옆으로 누운 사진) — 그 사진의 After·치아 선택은 새로 해야 함
  Future<void> _rotateSlot(
    PatientPhoto p,
    int k,
    int turns, {
    bool ask = true,
  }) async {
    final q = _slotPhoto(p, k);
    if (q == null || _converting) return;
    if (ask && (q.results.isNotEmpty || q.sam.isNotEmpty)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('사진을 돌릴까요?'),
          content: const Text(
            '돌리면 이 사진으로 만든 After와 고른 치아가 지워져요. 돌린 뒤 다시 만들어 주세요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('돌리기'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final r = await compute((a) => rotatePhoto(a.$1, a.$2), (
      q.beforeBytes,
      turns,
    ));
    if (!mounted) return;
    await _setSlot(
      p,
      k,
      r,
      mask: false,
      note: '원본 $k 사진을 ${turns > 0 ? '오른쪽' : '왼쪽'}으로 돌렸습니다',
    );
  }

  /// ＋ 새 작업: 지금 작업은 그대로 두고(저장했으면 기록에 있음) 빈 자리에서 새 환자 시작
  void _newCase() {
    _uploadSeq++;
    final p = PatientPhoto(
      id: 'u$_uploadSeq',
      name: '새 환자 $_uploadSeq',
      type: '새 작업',
      time: '방금',
      beforeBytes: blankPhoto(),
      imageSize: const Size(640, 480),
    )..blank = true;
    p.consult.name = '';
    _patients.insert(0, p);
    _select(p);
    setState(() {
      _step = 1;
      _finalMsg = '';
      _smileMsg = '';
      _drawLines = false;
    });
    _toast('＋ 새 작업을 시작합니다 · 원본 2(개구기) 사진부터 넣어 주세요');
  }

  /// 변환할 원본 고르기
  Future<void> _slotSelect(PatientPhoto p, int k) async {
    if (p.slot == k) return;
    var t = _slotPhoto(p, k);
    if (t == null && k == 1 && p.smile != null) {
      // 미소 미리보기에 넣었던 미소 사진을 원본 1 로
      t = await _makeSlotPhoto(p.smile!, 1, p.consult);
      t.pair = p;
      t.recordId = p.recordId;
      p.pair = t;
      _patients.insert(math.max(0, _patients.indexOf(p) + 1), t);
    }
    if (t == null || !mounted) return;
    _select(t);
  }

  Future<void> _slotUpload(PatientPhoto p, int k) async {
    final canCamera = _picker.supportsImageSource(ImageSource.camera);
    final src = canCamera
        ? await showModalBottomSheet<ImageSource>(
            context: context,
            showDragHandle: true,
            backgroundColor: Colors.white,
            constraints: const BoxConstraints(maxWidth: 480),
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: Text('원본 $k 촬영'),
                    onTap: () => Navigator.pop(ctx, ImageSource.camera),
                  ),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: const Text('갤러리에서 고르기'),
                    onTap: () => Navigator.pop(ctx, ImageSource.gallery),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          )
        : ImageSource.gallery;
    if (src == null) return;
    try {
      final f = await _picker.pickImage(
        source: src,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 92,
      );
      if (f == null) return;
      await _setSlot(p, k, await f.readAsBytes());
    } catch (e) {
      _toast('사진을 불러오지 못했습니다. 카메라·사진 권한을 확인해 주세요.');
    }
  }

  /// 2단계: 원본 1 + After → fal.ai 나노바나나 → Final Smile
  Future<void> _finalSmile(PatientPhoto p) async {
    final s1 = _slot1Bytes(p), after = _finalAfter(p);
    if (_finalBusy) return;
    if (s1 == null || after == null) {
      _finalMsg = s1 == null
          ? '원본 1(자연스러운 미소) 사진을 먼저 넣어 주세요'
          : '먼저 1단계 변환으로 After를 만들어 주세요';
      _toast(_finalMsg);
      return;
    }
    setState(() {
      _finalBusy = true;
      _finalMsg = '✨ 2단계: 원본 1에 After 치열을 맞추는 중… (나노바나나)';
    });
    try {
      final r = await (debugFinalSmile ?? makeFinalSmile)(
        orig1: s1,
        after: after,
      );
      if (!mounted) return;
      if (!identical(p.smile, s1)) await setSmile(p, s1);
      if (!mounted) return;
      setState(() {
        p.smileAfter = r.image;
        p.smileFrom = 'Final Smile (2단계)';
        p.addExtra(r.image, '✨ Final Smile', sub: 'After 치열 → 원본 1', pair: s1);
        p.noteSmile();
        _smileView = true;
        _finalMsg = r.lipsLocked
            ? '완성! 입술·얼굴은 원본 1 그대로 고정했습니다'
            : '완성! (입술 자동 고정은 못 했어요 · 입술 모양을 확인해 주세요)';
      });
      _smilePublish(p);
      _smileSave(p);
      _toast('✨ Final Smile 완성 · ${_finalMsg.replaceFirst('완성! ', '')}');
    } on PipelineError catch (e) {
      _finalMsg = '⚠ ${e.message}';
      _toast(_finalMsg);
    } on AiError catch (e) {
      _finalMsg = '⚠ ${e.message}';
      _toast(_finalMsg);
    } catch (e) {
      _finalMsg = '⚠ 2단계를 만들지 못했습니다 ($e)';
      _toast(_finalMsg);
    } finally {
      if (mounted) setState(() => _finalBusy = false);
    }
  }

  Widget _slotBar(PatientPhoto p) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    Widget card(int k) {
      final b = k == 1 ? _slot1Bytes(p) : _slotPhoto(p, 2)?.beforeBytes;
      final sel = p.slot == k;
      final title = k == 1 ? '원본 1 · 자연스러운 미소' : '원본 2 · 개구기';
      final hasAfter = (_slotPhoto(p, k)?.results.isNotEmpty ?? false);
      return Expanded(
        child: Material(
          color: sel ? AppColors.blueSoft : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: sel ? AppColors.blue : AppColors.gray200,
              width: sel ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _converting || _finalBusy
                ? null
                : () => b == null ? _slotUpload(p, k) : _slotSelect(p, k),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  SizedBox(
                    width: phone ? 54 : 72,
                    height: phone ? 40 : 54,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: b == null
                          ? const ColoredBox(
                              color: AppColors.gray100,
                              child: Icon(
                                Icons.add_a_photo_outlined,
                                color: AppColors.gray500,
                              ),
                            )
                          : Image.memory(
                              b,
                              fit: BoxFit.cover,
                              cacheWidth: 160,
                              gaplessPlayback: true,
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              sel
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 16,
                              color: sel ? AppColors.blue : AppColors.gray500,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          b == null
                              ? '눌러서 사진 올리기'
                              : sel
                              ? '변환할 사진${hasAfter ? ' · After 있음' : ''}'
                              : '눌러서 이 사진 변환${hasAfter ? ' · After 있음' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.gray500,
                          ),
                        ),
                        if (b != null)
                          InkWell(
                            onTap: _converting || _finalBusy
                                ? null
                                : () => _slotUpload(p, k),
                            child: const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Text(
                                '사진 바꾸기',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.blue,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final go = FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
      onPressed: _finalReady(p) ? () => _finalSmile(p) : null,
      icon: _finalBusy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.auto_awesome),
      label: Text(_finalBusy ? '2단계 만드는 중…' : '2단계 · 최종 미소 만들기'),
    );
    final note = Text(
      _finalMsg.isNotEmpty
          ? _finalMsg
          : _slot1Bytes(p) == null
          ? '원본 1(미소)을 넣고 1단계 After를 만들면 2단계를 할 수 있어요'
          : _finalAfter(p) == null
          ? '1단계: 변환할 사진을 고르고 [After 변환하기] → 2단계: 원본 1에 After 치열 맞추기'
          : '원본 1 + After 치열 → 입술·얼굴은 그대로, 치아만 바꿔요 (fal.ai 나노바나나)',
      style: const TextStyle(fontSize: 11.5, color: AppColors.gray500),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [card(1), const SizedBox(width: 8), card(2)]),
        const SizedBox(height: 6),
        if (phone) ...[
          go,
          const SizedBox(height: 4),
          note,
        ] else
          Row(
            children: [
              Expanded(child: note),
              const SizedBox(width: 8),
              go,
            ],
          ),
      ],
    );
  }

  // ── 😊 원본 2장 (개구기 사진 + 미소 사진) ─────────────────────────
  bool _smileRef = true; // 변환할 때 미소 사진도 참고
  bool _autoMatch = false; // 변환 후 미소 사진에 자동 정밀 매칭 (기본 끔: 2단계 버튼이 대신함)
  bool _smileRefOn(PatientPhoto p) => _useAi && _smileRef && p.smile != null;

  Future<void> _matchAfterConvert(PatientPhoto p) async {
    final after = p.afterBytes;
    if (after == null || p.smile == null || !mounted) return;
    _matchReset(p);
    _mProsth = after;
    _mLabel = _label(p, p.results.length);
    _mRes = null;
    await _matchRun(p);
    if (!mounted) return;
    if (_mRes != null) {
      _toast('😊 미소 미리보기 완성! ${_mRes!.align.summary} · 왼쪽 목록에도 들어갔어요');
    } else if (_mStep.isNotEmpty) {
      _toast('😊 미소 사진에 맞추지 못했어요: $_mStep');
    }
  }

  Widget _smileRefBox(PatientPhoto p) {
    final sm = p.smile;
    // CheckboxListTile 은 가까운 Material 위에 그려지므로 투명 Material 로 감쌈
    return Material(
      type: MaterialType.transparency,
      child: _smileRefInner(p, sm),
    );
  }

  Widget _smileRefInner(PatientPhoto p, Uint8List? sm) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.gray200),
      ),
      child: sm == null
          ? Row(
              children: [
                const Expanded(
                  child: Text(
                    '😊 원본 2장 방식: 미소 사진을 넣으면 미소에 어울리는 치아로 변환하고, 끝나면 미소 사진에 자동으로 맞춰 줘요',
                    style: TextStyle(fontSize: 12, color: AppColors.gray500),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: () => _openSmile(p),
                  child: const Text('😊 미소 사진 넣기'),
                ),
              ],
            )
          : Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.memory(
                    sm,
                    width: 56,
                    height: 42,
                    fit: BoxFit.cover,
                    cacheWidth: 120,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        value: _smileRef && _useAi,
                        onChanged: _useAi
                            ? (v) => setState(() => _smileRef = v ?? true)
                            : null,
                        title: const Text(
                          '😊 미소 사진도 참고해서 변환 (원본 2장)',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        value: _autoMatch,
                        onChanged: (v) =>
                            setState(() => _autoMatch = v ?? true),
                        title: const Text(
                          '변환 후 미소 사진에 자동으로 맞추기 (최종: 미소 결과)',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// 🔁 어떤 사진을 기준으로 변환하는지 (목록에서 결과를 누르면 바뀜)
  Widget _baseLine(PatientPhoto p) {
    final n = p.baseIndex;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        n == 0
            ? '기준 사진: 원본 (비교 목록에서 변환 결과를 누르면 그 결과를 기준으로 다시 다듬어요)'
            : '기준 사진: ${_label(p, n)} → 이 결과를 다듬어 새 결과를 만들어요 (원본으로 하려면 목록에서 원본을 누르세요)',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: n == 0 ? FontWeight.w500 : FontWeight.w800,
          color: n == 0 ? AppColors.gray500 : AppColors.blueDeep,
        ),
      ),
    );
  }

  Widget _convertBox(bool locked) {
    final c = _c, converted = _converted, stale = _stale;
    final ready = !converted || stale;
    final note = !converted
        ? '아직 After가 없습니다. 위 설정을 확인하고 눌러 주세요.'
        : stale
        ? '설정이 바뀌었습니다. [다시 변환하기]를 눌러 반영하세요.'
        : '✓ 셰이드 ${c.shade ?? '선택 안 함'} · 강도 ${c.strength}%로 변환됨';
    final noteColor = !converted
        ? AppColors.gray500
        : stale
        ? const Color(0xFFB26A00)
        : AppColors.mint;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.blueSoft.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.blue.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'After 변환',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
              Text(
                '치아 영역 · 치료 부위 · 셰이드를 정한 뒤 누르세요',
                style: TextStyle(fontSize: 12, color: AppColors.gray500),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _baseLine(_cur!),
          _smileRefBox(_cur!),
          _aiRow(locked),
          Row(
            children: [
              const Text(
                '적용 강도',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              Expanded(
                // 잠금은 Slider 를 비활성(onChanged: null)로 바꾸지 않고 터치만 막음:
                // 확인 창이 닫히는 순간 비활성 전환되면 Flutter 접근성 트리 갱신 오류가 남
                child: AbsorbPointer(
                  absorbing: locked,
                  child: Opacity(
                    opacity: locked ? 0.5 : 1,
                    child: Slider(
                      value: c.strength.toDouble(),
                      min: 30,
                      max: 100,
                      divisions: 14,
                      label: '${c.strength}%',
                      onChanged: (v) {
                        if (!locked) setState(() => c.strength = v.round());
                      },
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 42,
                child: Text(
                  '${c.strength}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: AppColors.blue,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(
            height: 52,
            child: ready
                ? FilledButton.icon(
                    onPressed: locked || _converting ? null : _convert,
                    icon: const Icon(Icons.auto_fix_high_rounded),
                    label: Text(converted ? '다시 변환하기' : 'After 변환하기'),
                  )
                : OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.blue, width: 2),
                    ),
                    onPressed: locked || _converting ? null : _convert,
                    icon: const Icon(Icons.auto_fix_high_rounded),
                    label: const Text(
                      '다시 변환하기',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          Text(
            note,
            style: TextStyle(
              fontSize: 12,
              color: noteColor,
              fontWeight: converted ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  Widget _doneBanner(Consult c) {
    String two(int v) => v.toString().padLeft(2, '0');
    final t = c.doneAt!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.mint.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.mint.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_rounded, color: AppColors.mint),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${c.name} 님 결과 저장 · 상담 완료',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${t.year}.${two(t.month)}.${two(t.day)} ${two(t.hour)}:${two(t.minute)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.gray500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: _choosePhoto,
          child: const Text('📷 다음 환자 사진 등록'),
        ),
      ],
    );
  }

  Widget _sec(String title, String? help, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          if (help != null)
            Text(
              help,
              style: const TextStyle(fontSize: 12, color: AppColors.gray500),
            ),
        ],
      ),
      const SizedBox(height: 8),
      child,
    ],
  );

  Widget _card({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(16),
  }) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: AppColors.gray200),
    ),
    child: child,
  );
}

// -----------------------------------------------------------------------------
// 작은 위젯들
// -----------------------------------------------------------------------------
class _BriefingToggle extends StatelessWidget {
  const _BriefingToggle({required this.on, required this.onChanged});
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '상담 패널을 접고 비교 화면만 크게 봅니다 (Esc로 종료)',
      child: Material(
        color: on ? AppColors.blue : Colors.white,
        shape: const StadiumBorder(
          side: BorderSide(color: AppColors.blue, width: 1.5),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => onChanged(!on),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '🖥️ ${on ? '브리핑 종료' : '환자 브리핑 모드'}',
                  style: TextStyle(
                    color: on ? Colors.white : AppColors.blue,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  height: 24,
                  child: FittedBox(
                    child: Switch(
                      value: on,
                      onChanged: onChanged,
                      activeTrackColor: Colors.white.withValues(alpha: 0.45),
                      activeThumbColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 비교 목록에서 1장만 골랐을 때: 그 사진 하나를 크게
class _SinglePhoto extends StatelessWidget {
  const _SinglePhoto({
    required this.bytes,
    required this.title,
    required this.sub,
    required this.fit,
    this.overlay,
  });
  final Uint8List bytes;
  final Uint8List? overlay;
  final String title, sub;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: const Color(0xFF0D1622),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(bytes, fit: fit, gaplessPlayback: true),
            if (overlay != null)
              IgnorePointer(
                child: Image.memory(overlay!, fit: fit, gaplessPlayback: true),
              ),
            Positioned(
              left: 16,
              top: 16,
              child: PhotoBadge(
                title: title,
                sub: sub,
                color: sub == '치료 전' ? const Color(0xFF4E5D73) : AppColors.blue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeadNameField extends StatelessWidget {
  const _HeadNameField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onChanged,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w800,
      color: AppColors.ink,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 150,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            maxLength: 30,
            textInputAction: TextInputAction.done,
            style: style,
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              hintText: '환자 이름 입력',
              hintStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.blue,
              ),
              filled: false,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.gray200),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.blue, width: 1.6),
              ),
              suffixIcon: const Icon(
                Icons.edit_outlined,
                size: 16,
                color: AppColors.gray500,
              ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 28,
                minHeight: 20,
              ),
            ),
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 4),
        const Text('님', style: style),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: on ? AppColors.blue : Colors.white,
    shape: StadiumBorder(
      side: BorderSide(color: on ? AppColors.blue : AppColors.gray200),
    ),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: on ? Colors.white : AppColors.ink,
          ),
        ),
      ),
    ),
  );
}

class _QuickButton extends StatelessWidget {
  const _QuickButton(this.label, this.onTap);
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 34),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
    ),
    onPressed: onTap,
    child: Text(label),
  );
}
