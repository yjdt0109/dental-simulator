import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../ai/smile.dart' show ToothMaskSet;
import '../ai/tooth_select.dart' show ToothSel;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 셰이드 칩: [chip] 칩 색, [tooth] 예시 사진 After 치아 색,
/// [targetL]/[targetB] 직접 등록한 사진을 미백할 때의 목표 밝기(L*)와 노란기(b*)
class Shade {
  const Shade(
    this.id,
    this.desc,
    this.chip,
    this.tooth,
    this.targetL,
    this.targetB,
  );
  final String id;
  final String desc;
  final Color chip;
  final Color tooth;
  final double targetL;
  final double targetB;
}

const kShades = [
  Shade('BL1', '최대 미백', Color(0xFFF7F5EE), Color(0xFFFBFAF6), 92, 4),
  Shade('A1', '밝은 자연색', Color(0xFFF0E6D0), Color(0xFFF5EEDD), 86, 9),
  Shade('A2', '일반 자연색', Color(0xFFE8D9B9), Color(0xFFEEE2C6), 82, 14),
  Shade('B1', '맑은 톤', Color(0xFFF3ECDA), Color(0xFFF7F1E3), 88, 7),
];
Shade shadeById(String id) =>
    kShades.firstWhere((s) => s.id == id, orElse: () => kShades[1]);

const kTreatments = [
  '라미네이트',
  '무삭제 라미네이트',
  '미백',
  '교정',
  '잇몸 성형',
  '올세라믹 크라운',
  '임플란트',
];

/// 치료 종류 켜고 끄기. 라미네이트(깎아서 정돈)와 무삭제 라미네이트(덧붙이기만)는
/// 지시가 정반대라 둘 중 하나만 고를 수 있음.
void toggleTreatment(Set<String> tx, String t) {
  if (tx.contains(t)) {
    tx.remove(t);
    return;
  }
  const exclusive = {'라미네이트': '무삭제 라미네이트', '무삭제 라미네이트': '라미네이트'};
  final other = exclusive[t];
  if (other != null) tx.remove(other);
  tx.add(t);
}

/// FDI 치식. 화면(환자를 마주 본 상태) 왼쪽→오른쪽 순서
const kUpperArch = [
  18,
  17,
  16,
  15,
  14,
  13,
  12,
  11,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
];
const kLowerArch = [
  48,
  47,
  46,
  45,
  44,
  43,
  42,
  41,
  31,
  32,
  33,
  34,
  35,
  36,
  37,
  38,
];
const kUpper6 = [13, 12, 11, 21, 22, 23];
const kLower6 = [43, 42, 41, 31, 32, 33];
List<int> sortTeeth(Iterable<int> set) =>
    [...kUpperArch, ...kLowerArch].where(set.contains).toList();

const _week = ['월', '화', '수', '목', '금', '토', '일'];

/// 2026.11.13 (금)
String formatConsultDate(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')} (${_week[d.weekday - 1]})';

String teethSummary(List<int> list) {
  bool has(List<int> g) => g.every(list.contains);
  if (list.length == 6 && has(kUpper6)) return '상악 앞니 6개';
  if (list.length == 6 && has(kLower6)) return '하악 앞니 6개';
  if (list.length == 12 && has(kUpper6) && has(kLower6)) return '상·하악 앞니 12개';
  if (list.length <= 4) return list.map((t) => '#$t').join(' ');
  return '#${list.first} 외 ${list.length - 1}개';
}

/// 예시 사진 종류 (촬영실 샘플)
enum SampleView { front, smile, side }

/// 기본 치아 영역 (사진 크기 대비 비율)
const kDefaultRoi = Rect.fromLTWH(0.14, 0.30, 0.72, 0.46);

/// 촬영실/직접 등록 사진 1건과 그 사진의 변환 상태
/// AI 적용 범위 칠하기 한 획 (좌표는 사진 기준 0~1, 굵기 r 은 사진 너비 기준)
class MaskStroke {
  MaskStroke({required this.r, required this.erase, List<Offset>? pts})
    : pts = pts ?? [];
  final double r;
  final bool erase;
  final List<Offset> pts;
}

/// 서비컬 라인(치경부 잇몸선) 기준선 한 획 — 좌표는 사진 기준 0~1
class GuideLine {
  GuideLine({required this.upper, List<Offset>? pts, this.incisal = false})
    : pts = pts ?? [];
  final bool upper; // true: 상악, false: 하악
  final List<Offset> pts;

  /// true: 절단라인(앞니 끝선) — 무삭제 라미네이트에서 '짧아지면 안 되는 선'
  final bool incisal;
}

extension GuideLineKinds on List<GuideLine> {
  /// 서비컬(잇몸) 라인만 — AI 기준선·잇몸 잠금에 쓰임
  List<GuideLine> get cervical => [
    for (final l in this)
      if (!l.incisal) l,
  ];

  /// 절단라인만
  List<GuideLine> get incisalLines => [
    for (final l in this)
      if (l.incisal) l,
  ];
}

int linesHash(List<GuideLine> l) => Object.hashAll([
  for (final g in l) Object.hash(g.upper, g.incisal, Object.hashAll(g.pts)),
]);

int maskHash(List<MaskStroke> m) => Object.hashAll([
  for (final s in m) Object.hash(s.r, s.erase, Object.hashAll(s.pts)),
]);

class PatientPhoto {
  PatientPhoto({
    required this.id,
    required this.name,
    required this.type,
    required this.time,
    required this.beforeBytes,
    required this.imageSize,
    this.view,
    this.isNew = false,
    List<String> planTx = const [],
    List<int> planTeeth = const [],
    String planShade = 'A1',
    Consult? sharedConsult,
    this.slot = 2,
  }) : consult =
           sharedConsult ??
           Consult(
             name: name,
             tx: {...planTx},
             teeth: {...planTeeth},
             shade: planShade,
           );

  /// 원본 슬롯: 1 = 자연스러운 미소(Base Smile), 2 = 개구기(Retractor View)
  final int slot;

  /// 같은 환자의 다른 슬롯 사진 (원본 1 ↔ 원본 2). 상담 내용(Consult)은 함께 씀
  PatientPhoto? pair;

  /// [＋ 새 작업] 으로 만든 빈 자리 (아직 사진 없음)
  bool blank = false;

  final String id;
  final String name;
  final String type;
  final String time;
  final SampleView? view; // null 이면 직접 등록한 사진
  Uint8List beforeBytes; // 눈 가리기 등으로 바뀔 수 있음
  final Size imageSize;
  bool isNew;

  Rect roi = kDefaultRoi;
  List<MaskStroke> mask = []; // 비어 있으면 치아 영역 전체에 AI 적용
  List<GuideLine> lines = []; // AI 기준 서비컬 라인
  final List<List<GuideLine>> lineHistory = []; // 서비컬 라인 [되돌리기] 기록

  // 🪄 원클릭 치아 자동 선택 (SAM 2)
  List<ToothSel> sam = []; // 고른 치아들 (탭한 순서)
  List<MaskStroke> samEdits = []; // 손으로 더하기/빼기
  final List<(List<ToothSel>, List<MaskStroke>)> samHistory = []; // [마지막 선택 취소]
  Uint8List? samOverlay; // 사진 위 하이라이트 PNG
  img.Image? samUnion; // 합친 마스크 (AI 로 보내는 크기)
  img.Image? samSmall; // AI 로 보내는 크기의 원본 (탭 좌표 기준)
  Uint8List? samJpeg;
  bool get hasSam => sam.isNotEmpty || samEdits.any((e) => !e.erase);

  // 😊 미소 미리보기 (개구기 없이 웃는 얼굴 사진 → 변환 치아 입히기)
  Uint8List? smile; // 환자 미소 사진 (눈 가리지 않음)
  Size smileSize = Size.zero;
  ToothMaskSet? smileSet; // 입술 사이 치아 영역
  Uint8List? smileAfter; // 미소에 입힌 결과
  String smileFrom = ''; // 어떤 결과를 입혔는지 (예: 김민수 2번)
  String? recordId; // 🗂 저장된(또는 불러온) 환자 기록 — 미소 사진도 그 폴더에 저장

  /// 변환 결과 1번, 2번, … (원본은 따로 beforeBytes). 마지막 것이 지금 After.
  List<AfterResult> results = [];
  Uint8List? get afterBytes => results.isEmpty ? null : results.last.bytes;
  String? get convKey => results.isEmpty ? null : results.last.convKey;

  /// 비교 목록에 더 불러온 사진 (미소 사진·미소 미리보기·환자 기록 사진 …), 불러온 차례대로.
  /// 번호는 -1, -2, … (원본·변환 결과 다음에 목록에 보임)
  final List<ExtraPhoto> extras = [];

  /// 같은 사진이 이미 있으면 그 번호, 아니면 새로 넣고 그 번호 (-1, -2 …)
  int addExtra(
    Uint8List bytes,
    String label, {
    String sub = '',
    Uint8List? pair, // 같은 촬영의 짝 (예: Final Smile → 원본 1)
  }) {
    for (var i = 0; i < extras.length; i++) {
      if (identical(extras[i].bytes, bytes)) return -(i + 1);
    }
    extras.add(ExtraPhoto(bytes, label, sub: sub, pair: pair));
    return -extras.length;
  }

  /// 비교 목록에서 사진 빼기 (원본은 못 뺌). 변환 결과는 [이전으로]로 되돌릴 수 있음. 뺀 사진 이름을 돌려줌
  String? removePhoto(int n, String label) {
    if (n > 0 && n <= results.length) {
      remember('사진 빼기');
      results = [...results]..removeAt(n - 1);
      if (results.isEmpty) editing = true;
      basePick = 0;
    } else if (n < 0 && -n <= extras.length) {
      extras.removeAt(-n - 1);
    } else {
      return null;
    }
    sel = [];
    return label;
  }

  /// 🔁 다시 변환할 때 기준 사진: 목록에서 변환 결과를 누르면 그 결과(번호), 원본을 누르면 0
  int basePick = 0;
  int get baseIndex =>
      basePick > 0 && basePick <= results.length ? basePick : 0;
  Uint8List get baseBytes => bytesOf(baseIndex);

  /// 목록에서 누른 사진으로 기준 정하기 (불러온 다른 사진은 기준이 안 됨: 구도가 다름)
  void noteBase(int n) {
    if (n < 0) return;
    if (compare.contains(n)) {
      basePick = n;
    } else {
      basePick = compare.where((x) => x > 0).lastOrNull ?? 0;
    }
  }

  /// 🦷 크기 조절할 사진: 목록에서 마지막으로 누른 사진 (원본·원본 1(미소)·미소 원본 제외).
  /// After(결과)·미소 미리보기·Final Smile·불러온 사진 모두 가능. 없으면 null
  int? resizeTarget({Uint8List? orig1, bool smileView = false}) {
    bool ok(int n) {
      if (n == 0) return false;
      if (n > 0) return n <= results.length;
      if (-n > extras.length) return false;
      final e = extras[-n - 1];
      return !(identical(e.bytes, orig1) ||
          identical(e.bytes, beforeBytes) ||
          identical(e.bytes, smile) ||
          e.sub == '미소 사진');
    }

    final cmp = compare;
    for (final n in sel.reversed) {
      if (ok(n) && cmp.contains(n)) return n;
    }
    if (smileView && smileAfter != null) {
      final i = extras.indexWhere((e) => identical(e.bytes, smileAfter));
      if (i >= 0) return -(i + 1);
    }
    final last = cmp.where(ok).lastOrNull;
    if (last != null) return last;
    return results.isEmpty ? null : results.length;
  }

  /// 같은 내용의 사진이 이미 목록(원본·결과·불러온 사진)에 있는지
  bool hasPhoto(Uint8List b) {
    bool same(Uint8List a) =>
        identical(a, b) || (a.length == b.length && listEquals(a, b));
    return same(beforeBytes) ||
        results.any((r) => same(r.bytes)) ||
        extras.any((e) => same(e.bytes));
  }

  /// 지금 미소 사진·미소 미리보기를 비교 목록에 (이미 있으면 그대로)
  void noteSmile() {
    bool has(Uint8List b) => extras.any((e) => identical(e.bytes, b));
    final sm = smile, sa = smileAfter;
    if (sm != null && !has(sm)) {
      final k = extras.where((e) => e.sub == '미소 사진').length + 1;
      addExtra(sm, '😊 미소 $k', sub: '미소 사진');
    }
    if (sa != null && !has(sa)) {
      final k = extras.where((e) => e.sub.startsWith('미소 미리보기')).length + 1;
      addExtra(
        sa,
        '😊 미소 미리보기 $k',
        sub: '미소 미리보기${smileFrom.isEmpty ? '' : ' · $smileFrom'}',
      );
    }
  }

  /// 비교 목록 순서: 원본(0) → 변환 결과(1…) → 불러온 사진(-1, -2 …)
  List<int> get listOrder => [
    for (var n = 0; n <= results.length; n++) n,
    for (var i = 1; i <= extras.length; i++) -i,
  ];

  bool _valid(int n) => n >= 0 ? n <= results.length : -n <= extras.length;
  int _rank(int n) => n >= 0 ? n : results.length - n;

  /// 브리핑 비교에 고른 사진 (0 = 원본, 1 = 1번 …, -1 = 불러온 첫 사진), 고른 순서대로 최대 2개
  List<int> sel = [];

  /// 비교할 두 장 (목록 위쪽이 왼쪽) — 1장만 골랐으면 [그 번호]
  List<int> get compare {
    final ok = [
      for (final n in sel)
        if (_valid(n)) n,
    ]..sort((a, b) => _rank(a).compareTo(_rank(b)));
    if (ok.isNotEmpty) return ok;
    return results.isEmpty ? [0] : [0, results.length];
  }

  Uint8List bytesOf(int n) => n < 0 && -n <= extras.length
      ? extras[-n - 1].bytes
      : n <= 0 || n > results.length
      ? beforeBytes
      : results[n - 1].bytes;

  /// 비교 목록에서 사진 체크/해제 (최대 2장, 3번째를 고르면 가장 먼저 고른 것이 빠짐)
  void toggleSel(int n) {
    if (!_valid(n)) return;
    final cur = [for (final x in compare) x];
    if (cur.contains(n)) {
      if (cur.length > 1) cur.remove(n); // 마지막 1장은 남김
      sel = cur;
    } else {
      sel = [...(sel.isEmpty ? cur : sel.where(cur.contains)), n];
      if (sel.length > 2) sel = sel.sublist(sel.length - 2);
    }
  }

  void addResult(
    Uint8List bytes,
    String key, {
    String engine = '',
    String check = '',
  }) {
    results = [
      ...results,
      AfterResult(bytes, key, engine: engine, check: check),
    ];
    sel = [0, results.length]; // 새로 만든 결과를 원본과 비교
  }

  bool editing = true; // true: 영역 지정 단계
  final Consult consult;

  bool get isUpload => view == null;

  /// [이전으로] 되돌리기 기록 (최근 것이 맨 뒤) / [다시 돌아가기] 기록
  final List<PhotoSnap> history = [];
  final List<PhotoSnap> future = [];

  PhotoSnap _snap(String label) => PhotoSnap(
    label: label,
    before: beforeBytes,
    results: results,
    sel: sel,
    editing: editing,
    roi: roi,
  );

  void _restore(PhotoSnap s) {
    beforeBytes = s.before;
    results = s.results;
    sel = s.sel;
    editing = s.editing;
    roi = s.roi;
  }

  /// 지금 상태를 기록해 두기 (label: 되돌릴 작업 이름). 새 작업을 하면 [다시 돌아가기]는 없어짐.
  void remember(String label) {
    history.add(_snap(label));
    if (history.length > 20) history.removeAt(0);
    future.clear();
  }

  /// 마지막 작업 취소. 되돌린 작업 이름을 돌려줌
  String? undo() {
    if (history.isEmpty) return null;
    final s = history.removeLast();
    future.add(_snap(s.label));
    _restore(s);
    return s.label;
  }

  /// 취소했던 작업 다시 하기
  String? redo() {
    if (future.isEmpty) return null;
    final s = future.removeLast();
    history.add(_snap(s.label));
    _restore(s);
    return s.label;
  }

  void resetView() {
    roi = kDefaultRoi;
    mask = [];
    results = [];
    sel = [];
    editing = true;
  }
}

/// 비교 목록에 더 불러온 사진 한 장
class ExtraPhoto {
  const ExtraPhoto(this.bytes, this.label, {this.sub = '', this.pair});
  final Uint8List bytes;
  final Uint8List? pair;
  final String label; // 예: 😊 미소 1
  final String sub; // 예: 치료 전 / 미소 미리보기 / 환자 기록
}

class AfterResult {
  const AfterResult(
    this.bytes,
    this.convKey, {
    this.engine = '',
    this.check = '',
  });
  final Uint8List bytes;
  final String convKey;

  /// 무삭제 라미네이트 검사 결과 (예: '✓ 무삭제 검사 통과 …') / 없으면 ''
  final String check;

  /// 만든 엔진 (비교용 표시): 'A' 'B' 'C' '단독' 'FLUX' … / 기본 미백 방식은 ''
  final String engine;
}

class PhotoSnap {
  const PhotoSnap({
    required this.label,
    required this.before,
    this.results = const [],
    this.sel = const [],
    required this.editing,
    required this.roi,
  });
  final String label;
  final Uint8List before;
  final List<AfterResult> results;
  final List<int> sel;
  final bool editing;
  final Rect roi;
}

/// 환자 1명의 상담 내용
class Consult {
  Consult({
    required this.name,
    required this.tx,
    required this.teeth,
    required this.shade,
  });
  String name;
  Set<String> tx;
  Set<int> teeth;
  String? shade; // null: 셰이드 선택 안 함 (색 강제 적용 안 함)
  int strength = 90;
  String memo = '';
  final DateTime date = DateTime.now(); // 상담 날짜 (상담을 시작한 날)
  DateTime? doneAt;
}

/// 사진의 EXIF 방향(옆으로 누운 사진)을 실제 픽셀로 바로 세움. 바꿀 게 없으면 그대로 돌려줌
Uint8List normalizeOrientation(Uint8List bytes) {
  try {
    final im = img.decodeJpg(bytes);
    if (im == null) return bytes;
    final o = im.exif.imageIfd.orientation;
    if (o == null || o == 1) return bytes;
    final baked = img.bakeOrientation(im);
    return Uint8List.fromList(img.encodeJpg(baked, quality: 92));
  } catch (_) {
    return bytes;
  }
}

/// 사진을 90° 돌림 ([turns] 1 = 오른쪽(시계 방향), -1 = 왼쪽)
Uint8List rotatePhoto(Uint8List bytes, int turns) {
  final im = img.decodeImage(bytes);
  if (im == null) return bytes;
  final r = img.copyRotate(img.bakeOrientation(im), angle: 90 * turns);
  return Uint8List.fromList(img.encodeJpg(r, quality: 92));
}

/// 빈 자리용 회색 사진
Uint8List blankPhoto() => Uint8List.fromList(
  img.encodeJpg(
    img.Image(width: 640, height: 480)..clear(img.ColorRgb8(226, 230, 236)),
    quality: 80,
  ),
);
