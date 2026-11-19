import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../qa/qa_agent.dart' show QaSettings, realCheckScorer, isModelMissing;
import '../simulator/sim_models.dart' show GuideLine, GuideLineKinds;
import 'ai_service.dart';
import 'tooth_select.dart' show ToothMeasure, measureTeeth, applyMarginBand;

// =============================================================================
// 🦷 무삭제 라미네이트 보호
//   치아를 깎지 않으므로 ① 마진(치은)라인은 거의 그대로, ② 절단라인은 길어져도 되지만
//   짧아지면 안 됨. 이것이 지켜져야 사실적으로 보임.
//   1) 픽셀: 마진 위 잇몸은 원본 고정(기존 잠금) + 결과에서 절단끝이 원본보다 짧아진
//      부분은 원본 치아 픽셀(결과 치아 색으로 맞춤)로 채워 원래 길이 복원
//   2) AI 검사: 비전 AI 가 원본·결과를 비교해 절단 짧아짐·마진 변화를 확인하고,
//      미달이면 고칠 지시로 다시 변환 (최대 2회)
// =============================================================================

const kNoPrep = '무삭제 라미네이트';
const kNoPrepMaxRetry = 2;

double _lum(img.Pixel p) => 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
double _chroma(img.Pixel p) {
  final mx = math.max(p.r, math.max(p.g, p.b)).toDouble();
  final mn = math.min(p.r, math.min(p.g, p.b)).toDouble();
  return mx - mn;
}

/// 치아다움 (밝고 채도 낮을수록 큼)
double toothness(img.Image im, int x, int y) {
  final p = im.getPixel(x, y);
  return _lum(p) - 0.6 * _chroma(p);
}

/// 선 위에서 x(0~1)일 때 y(0~1) — 범위 밖이면 null
double? lineYAt(List<Offset> pts, double x) {
  if (pts.length < 2) return null;
  final s = [...pts]..sort((a, b) => a.dx.compareTo(b.dx));
  if (x < s.first.dx || x > s.last.dx) return null;
  for (var i = 1; i < s.length; i++) {
    final a = s[i - 1], b = s[i];
    if (x <= b.dx) {
      final w = b.dx - a.dx;
      return w <= 0 ? a.dy : a.dy + (b.dy - a.dy) * (x - a.dx) / w;
    }
  }
  return s.last.dy;
}

/// 한 열(x 픽셀)에서 서비컬 라인(yc)부터 치아 쪽으로 내려가며(상악) / 올라가며(하악)
/// 치아가 끝나는 곳(절단끝) 찾기. 못 찾으면 null.
int? edgeInColumn(
  img.Image im,
  int x,
  int yc,
  bool upper,
  int crownGuess, {
  int? near, // 이 근처(±window)에서만 찾기
}) {
  final dir = upper ? 1 : -1;
  final h = im.height;
  int at(int k) => (yc + dir * k).clamp(0, h - 1);
  // 기준 치아 밝기: 서비컬에서 15~35% 지점
  final ref = <double>[];
  for (
    var k = (crownGuess * 0.15).round();
    k <= (crownGuess * 0.35).round();
    k++
  ) {
    ref.add(toothness(im, x, at(k)));
  }
  if (ref.isEmpty) return null;
  ref.sort();
  final base = ref[ref.length ~/ 2];
  if (base < 90) return null; // 치아가 아닌 열 (어두움)
  final th = base * 0.62;
  final from = near == null
      ? (crownGuess * 0.3).round()
      : math.max(
          (crownGuess * 0.2).round(),
          (near - yc).abs() - (crownGuess * 0.45).round(),
        );
  final to = near == null
      ? (crownGuess * 1.9).round()
      : (near - yc).abs() + (crownGuess * 0.45).round();
  var run = 0;
  for (var k = from; k <= to; k++) {
    final y = yc + dir * k;
    if (y < 0 || y >= h) break;
    if (toothness(im, x, y) < th) {
      if (++run >= 3) return y - dir * 2;
    } else {
      run = 0;
    }
  }
  return null;
}

List<double?> _median(List<double?> v, int r) => [
  for (var i = 0; i < v.length; i++)
    () {
      final w = [
        for (
          var j = math.max(0, i - r);
          j <= math.min(v.length - 1, i + r);
          j++
        )
          ?v[j],
      ]..sort();
      return w.isEmpty ? null : w[w.length ~/ 2];
    }(),
];

/// 서비컬 라인 하나 기준 → 절단라인 자동 감지 (사진 0~1 좌표). 못 찾으면 null.
GuideLine? detectIncisal(img.Image im, GuideLine cervical) {
  final pts = cervical.pts;
  if (pts.length < 2) return null;
  final xs = pts.map((p) => p.dx);
  final x0 = xs.reduce(math.min), x1 = xs.reduce(math.max);
  final spanPx = (x1 - x0) * im.width;
  if (spanPx < 20) return null;
  // 앞니 6개 폭 대비 치관 길이 대략 0.22배 (사진마다 달라 넉넉히 찾음)
  final crown = math.max(12, (spanPx * 0.22).round());
  const n = 60;
  final ys = <double?>[];
  final xsN = <double>[];
  for (var i = 0; i <= n; i++) {
    final fx = x0 + (x1 - x0) * i / n;
    final yc = lineYAt(pts, fx);
    final px = (fx * im.width).round().clamp(0, im.width - 1);
    xsN.add(fx);
    if (yc == null) {
      ys.add(null);
      continue;
    }
    final e = edgeInColumn(
      im,
      px,
      (yc * im.height).round(),
      cervical.upper,
      crown,
    );
    ys.add(e == null ? null : e / im.height);
  }
  final sm = _median(ys, 3);
  final ok = sm.whereType<double>().length;
  if (ok < n * 0.4) return null;
  return GuideLine(
    upper: cervical.upper,
    incisal: true,
    pts: [
      for (var i = 0; i < sm.length; i++)
        if (sm[i] != null) Offset(xsN[i], sm[i]!),
    ],
  );
}

/// 픽셀 보호 결과
class NoPrepFix {
  const NoPrepFix(
    this.image, {
    required this.shortCols,
    required this.maxShort,
  });
  final img.Image image;
  final double shortCols; // 짧아졌던 열 비율 (0~1)
  final double maxShort; // 가장 많이 짧아진 정도 (치관 길이 대비)
}

/// 결과에서 절단끝이 원본(절단라인)보다 짧아진 곳을 원본 치아로 채워 길이 복원.
/// 채우는 원본 치아는 결과 치아 색에 맞춰 색을 옮김 (라미네이트 색 유지).
NoPrepFix restoreIncisal(
  img.Image orig,
  img.Image result,
  List<GuideLine> lines,
) {
  final out = result.clone();
  var shortN = 0, total = 0;
  var maxShort = 0.0;
  for (final inc in lines.incisalLines) {
    final cerv = lines.cervical.where((c) => c.upper == inc.upper).toList();
    if (cerv.isEmpty || inc.pts.length < 2) continue;
    final xs = inc.pts.map((p) => p.dx);
    final x0 = xs.reduce(math.min), x1 = xs.reduce(math.max);
    final px0 = (x0 * out.width).ceil(), px1 = (x1 * out.width).floor();
    final dir = inc.upper ? 1 : -1;
    // 열마다: 원본 절단끝 y0, 서비컬 yc, 결과 절단끝 y1
    final y1s = <int, int>{};
    for (var px = px0; px <= px1; px += 2) {
      final fx = px / out.width;
      final yc0 = cerv
          .map((c) => lineYAt(c.pts, fx))
          .whereType<double>()
          .firstOrNull;
      final y0f = lineYAt(inc.pts, fx);
      if (yc0 == null || y0f == null) continue;
      final yc = (yc0 * out.height).round(), y0 = (y0f * out.height).round();
      final crown = (y0 - yc).abs();
      if (crown < 8) continue;
      final e = edgeInColumn(out, px, yc, inc.upper, crown, near: y0);
      if (e != null) y1s[px] = e;
    }
    for (var px = px0; px <= px1; px++) {
      final fx = px / out.width;
      final yc0 = cerv
          .map((c) => lineYAt(c.pts, fx))
          .whereType<double>()
          .firstOrNull;
      final y0f = lineYAt(inc.pts, fx);
      if (yc0 == null || y0f == null) continue;
      final yc = (yc0 * out.height).round(), y0 = (y0f * out.height).round();
      final crown = (y0 - yc).abs();
      if (crown < 8) continue;
      // 가까운 측정값 (2px 간격으로 잼)
      final y1 = y1s[px] ?? y1s[px - 1] ?? y1s[px + 1];
      if (y1 == null) continue;
      total++;
      final short = (y0 - y1) * dir; // + 이면 짧아짐
      final tol = math.max(2, (crown * 0.03).round());
      if (short <= tol) continue;
      if (short > crown * 0.6) continue; // 감지가 틀렸을 가능성 → AI 검사에 맡김
      shortN++;
      maxShort = math.max(maxShort, short / crown);
      // 결과 치아 색 - 원본 치아 색 (절단끝 바로 안쪽 띠)
      var dr = 0.0, dg = 0.0, db = 0.0, k = 0;
      for (var j = 3; j <= 12; j++) {
        final y = y1 - dir * j;
        if (y < 0 || y >= out.height) continue;
        final a = result.getPixel(px, y), b = orig.getPixel(px, y);
        dr += a.r - b.r;
        dg += a.g - b.g;
        db += a.b - b.b;
        k++;
      }
      if (k > 0) {
        dr /= k;
        dg /= k;
        db /= k;
      }
      const feather = 4;
      for (var j = -feather; j <= short + 1; j++) {
        final y = y1 + dir * j;
        if (y < 0 || y >= out.height) continue;
        final o = orig.getPixel(px, y);
        final a = j < 0 ? (j + feather) / feather : 1.0; // 경계는 부드럽게
        final r = result.getPixel(px, y);
        int mix(num src, num shifted) =>
            (src * (1 - a) + shifted.clamp(0, 255) * a).round();
        out.setPixelRgb(
          px,
          y,
          mix(r.r, o.r + dr),
          mix(r.g, o.g + dg),
          mix(r.b, o.b + db),
        );
      }
    }
  }
  return NoPrepFix(
    out,
    shortCols: total == 0 ? 0 : shortN / total,
    maxShort: maxShort,
  );
}

// -----------------------------------------------------------------------------
// AI 검사
// -----------------------------------------------------------------------------
class NoPrepVerdict {
  const NoPrepVerdict({
    required this.incisalShorter,
    required this.marginChange,
    this.shorterTeeth = const [],
    this.marginTeeth = const [],
    this.fix = '',
    this.summary = '',
  });
  final bool incisalShorter;
  final int marginChange; // 0 없음 · 1 미세 · 2 눈에 띔 · 3 심함
  final List<String> shorterTeeth, marginTeeth;
  final String fix; // 다음 변환에 붙일 고칠 지시
  final String summary;

  bool get ok => !incisalShorter && marginChange <= 1;

  /// 낮을수록 좋음 (여러 번 해도 미달이면 가장 나은 것 고르기)
  int get badness => (incisalShorter ? 10 : 0) + marginChange;

  String get label => ok
      ? '✓ 무삭제 검사 통과 (절단길이 유지 · 마진라인 유지)'
      : [
          if (incisalShorter)
            '절단 짧아짐 의심${shorterTeeth.isEmpty ? '' : ' (${shorterTeeth.join(', ')})'}',
          if (marginChange > 1)
            '마진라인 변화 ${marginChange >= 3 ? '심함' : '있음'}${marginTeeth.isEmpty ? '' : ' (${marginTeeth.join(', ')})'}',
        ].join(' · ');

  factory NoPrepVerdict.parse(String raw) {
    final a = raw.indexOf('{'), b = raw.lastIndexOf('}');
    if (a < 0 || b <= a) throw const FormatException('검사 결과를 읽지 못했습니다.');
    final j = jsonDecode(raw.substring(a, b + 1)) as Map<String, dynamic>;
    List<String> list(Object? v) => v is List ? [for (final x in v) '$x'] : [];
    final m = j['margin_change'];
    return NoPrepVerdict(
      incisalShorter: j['incisal_shorter'] == true,
      marginChange: (m is num ? m.round() : int.tryParse('$m') ?? 0).clamp(
        0,
        3,
      ),
      shorterTeeth: list(j['shorter_teeth']),
      marginTeeth: list(j['margin_teeth']),
      fix: '${j['fix'] ?? ''}'.trim(),
      summary: '${j['summary'] ?? ''}'.trim(),
    );
  }
}

String buildNoPrepCheckPrompt({
  required List<int> teeth,
  required double measuredShort,
}) =>
    '''
당신은 무삭제 라미네이트(No-prep veneer) 결과를 검수하는 치과 전문가입니다.
- 사진 1: 치료 전 원본
- 사진 2: AI 가 만든 무삭제 라미네이트 결과
무삭제 라미네이트는 치아를 깎지 않으므로 아래 두 가지가 지켜져야 사실적입니다. 치열·모양이 약간 어색한 것은 감점하지 마세요.
1) 절단라인(앞니 끝선): 원본보다 길어지는 것은 괜찮지만, 어느 치아든 원본보다 짧아지면 안 됩니다.
2) 마진라인(치은라인, 치아와 잇몸 경계): 원본과 거의 같아야 합니다. 잇몸선 위치·모양이 바뀌거나 치아가 잇몸 쪽으로 커지면 안 됩니다.
치료 치아: ${teeth.isEmpty ? '선택 안 함(앞니 전체)' : teeth.map((t) => '#$t').join(' ')}
(사진 계산 참고: 결과 절단끝이 원본보다 짧았던 곳을 일부 원본 길이로 복원했습니다. 복원 전 최대 ${(measuredShort * 100).round()}% 짧았음)

사진 2를 사진 1과 꼼꼼히 비교해 아래 JSON 하나만 답하세요 (설명 없이):
{"incisal_shorter": true/false, "shorter_teeth": ["#11", ...], "margin_change": 0-3 (0 없음, 1 미세, 2 눈에 띔, 3 심함), "margin_teeth": ["#21", ...], "fix": "다음 변환에서 고칠 점 (한국어, 치아 번호·위치 구체적으로, 200자 이내. 예: #11·#21 절단끝을 원본 위치까지 유지하고 0.5mm 연장, 마진라인은 원본 그대로)", "summary": "한 줄 평"}
''';

typedef NoPrepChecker = Future<NoPrepVerdict> Function(
  Uint8List original,
  Uint8List result,
  double measuredShort,
);

/// 실제 AI 검사 (자동 QA 채점과 같은 Gemini 비전 모델)
Future<NoPrepVerdict> realNoPrepCheck(
  Uint8List original,
  Uint8List result,
  double measuredShort, {
  List<int> teeth = const [],
}) async {
  final bad = await realCheckScorer();
  if (bad != null) throw AiError(bad);
  Future<Uint8List> small(Uint8List b) async =>
      AiService.photoJpeg(await AiService.decodePhoto(b, maxSide: 1280));
  try {
    final raw = await AiService.instance.geminiText(
      model: QaSettings.active!,
      prompt: buildNoPrepCheckPrompt(
        teeth: teeth,
        measuredShort: measuredShort,
      ),
      images: [
        (label: '사진 1: 치료 전 원본', jpeg: await small(original)),
        (label: '사진 2: 무삭제 라미네이트 결과', jpeg: await small(result)),
      ],
    );
    return NoPrepVerdict.parse(raw);
  } catch (e) {
    if (isModelMissing(e)) QaSettings.active = null;
    rethrow;
  }
}

/// 무삭제 변환 반복: 변환 → 픽셀 보호 → AI 검사 → 미달이면 고친 지시로 다시 (최대 [maxRetry]회)
class NoPrepOutcome {
  const NoPrepOutcome(
    this.bytes,
    this.verdict,
    this.tries, {
    this.note,
    this.measures = const [],
  });
  final Uint8List bytes;
  final NoPrepVerdict? verdict; // null: 검사를 못 함
  final int tries;
  final String? note; // 검사를 못 한 이유 등
  final List<ToothMeasure> measures; // A③ 치아별 숫자 측정 (보호 적용 전 원래 결과 기준)

  /// 결과 옆에 남길 한 줄
  String get label {
    final v = verdict;
    if (v == null) return note ?? '';
    if (measures.isEmpty) return v.label;
    final m = measures.map((e) => e.text).join(' · ');
    return v.ok ? '✓ 숫자 검사 통과 · $m' : '⚠ $m → 짧아진 절단끝·마진은 원본으로 복원함';
  }
}

/// 숫자 측정 → 검사 결과 (AI 호출 없이)
NoPrepVerdict numericVerdict(List<ToothMeasure> ms) {
  final short = ms.where((m) => m.shorter).toList();
  final moved = ms.where((m) => m.marginMoved).toList();
  return NoPrepVerdict(
    incisalShorter: short.isNotEmpty,
    marginChange: moved.isEmpty ? 0 : 2,
    shorterTeeth: [for (final m in short) m.label],
    marginTeeth: [for (final m in moved) m.label],
    fix: [
      for (final m in short)
        '${m.label} 절단끝이 원본보다 ${((1 - m.length!) * 100).round()}% 짧음 → 원본 길이 이상으로 유지.',
      for (final m in moved)
        '${m.label} 마진(치은)라인이 ${(m.margin! * 100).round()}% 움직임 → 원본 위치 그대로.',
    ].join(' '),
    summary: ms.map((m) => m.text).join(' · '),
  );
}

Future<NoPrepOutcome> runNoPrepGuard({
  required Uint8List original,
  required List<GuideLine> lines,
  required Future<Uint8List> Function(String fix) generate,
  required NoPrepChecker check,
  required void Function(String msg) onStep,
  Future<img.Image> Function(Uint8List)? decode,
  int maxRetry = kNoPrepMaxRetry,
  List<({String label, bool upper, Offset zenith, Offset incisal})> marks =
      const [],
  bool marginBand = true,
}) async {
  final dec = decode ?? (b) => AiService.decodePhoto(b, maxSide: 2000);
  final hasLines = lines.incisalLines.isNotEmpty && lines.cervical.isNotEmpty;
  final origImg = hasLines || marks.isNotEmpty ? await dec(original) : null;
  var fix = '';
  NoPrepOutcome? best;
  for (var i = 0; i <= maxRetry; i++) {
    onStep(
      i == 0 ? '무삭제 라미네이트 변환 중…' : '🦷 검사 미달 → 고친 지시로 다시 변환 ($i/$maxRetry)…',
    );
    var bytes = await generate(fix);
    var measured = 0.0;
    var ms = const <ToothMeasure>[];
    if (origImg != null) {
      var res = await dec(bytes);
      if (res.width != origImg.width || res.height != origImg.height) {
        res = img.copyResize(res, width: origImg.width, height: origImg.height);
      }
      if (marks.isNotEmpty) {
        onStep('📏 숫자 검사: 치아별 길이·마진 위치 재는 중…');
        ms = await compute((a) => measureTeeth(a.$1, a.$2, a.$3), (
          origImg,
          res,
          marks,
        ));
      }
      if (hasLines) {
        onStep('🦷 절단길이·마진 보호: 원본 기준으로 복원 중…');
        final f = await compute((a) {
          final r = restoreIncisal(a.$1, a.$2, a.$3);
          if (a.$4) applyMarginBand(a.$1, r.image, a.$3);
          return r;
        }, (origImg, res, lines, marginBand));
        measured = f.maxShort;
        if (f.shortCols > 0 || marginBand) {
          bytes = img.encodeJpg(f.image, quality: 92);
        }
      }
    }
    NoPrepVerdict v;
    if (ms.any((m) => m.length != null)) {
      v = numericVerdict(ms); // A③ 숫자 검사가 1순위 (AI 는 부르지 않음)
    } else {
      onStep('🦷 AI 검사: 절단길이 짧아짐·마진라인 변화 확인 중…');
      try {
        v = await check(original, bytes, measured);
      } catch (e) {
        final msg = e is AiError ? e.message : '$e';
        return NoPrepOutcome(
          bytes,
          null,
          i + 1,
          note: 'AI 검사를 하지 못했습니다 ($msg) · 픽셀 보호만 적용했습니다',
        );
      }
    }
    final cur = NoPrepOutcome(bytes, v, i + 1, measures: ms);
    if (best == null || v.badness < best.verdict!.badness) best = cur;
    if (v.ok) return cur;
    fix = [
      v.fix,
      if (v.incisalShorter) '모든 치아의 절단끝은 원본보다 절대 짧아지면 안 됨(같거나 약간 길게).',
      if (v.marginChange > 1) '마진(치은)라인은 원본 위치·모양 그대로 유지.',
    ].where((e) => e.isNotEmpty).join(' ');
  }
  return NoPrepOutcome(
    best!.bytes,
    best.verdict,
    maxRetry + 1,
    measures: best.measures,
  );
}
