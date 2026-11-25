import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../simulator/sim_models.dart' show GuideLine, MaskStroke;
import 'noprep_guard.dart' show edgeInColumn, toothness;
import 'pipeline.dart' show PipelineError;

// =============================================================================
// 🪄 원클릭 치아 자동 선택 (Fal.ai SAM 2) + 치아별 기준점 · 숫자 검사 · 마진 띠 잠금 · 크기 조절
//   - 탭한 점 (x, y) → fal-ai/sam2/image → 그 치아 윤곽 마스크 (사진과 같은 크기, 흰색 = 치아)
//   - 여러 치아 마스크 합치기 + 손으로 더하기/빼기 → FLUX.1 Fill 의 mask_url 로 그대로 사용
//   - 선택 바깥(잇몸·인접 치아)은 결과에서 원본 픽셀로 100% 되돌림
// =============================================================================

class FalSam {
  FalSam(this.key, {http.Client? client}) : _client = client ?? http.Client();
  final String key;
  final http.Client _client;
  static final endpoint = Uri.parse('https://fal.run/fal-ai/sam2/image');

  /// [jpeg] 안의 (x, y) 픽셀을 탭 → 그 물체(치아) 마스크 (회색조, 255 = 선택)
  Future<img.Image> segment(
    Uint8List jpeg,
    int x,
    int y, {
    List<(int, int)> negatives = const [],
  }) async {
    http.Response r;
    try {
      r = await _client
          .post(
            endpoint,
            headers: {
              'Authorization': 'Key $key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'image_url': 'data:image/jpeg;base64,${base64Encode(jpeg)}',
              'prompts': [
                {'x': x, 'y': y, 'label': 1},
                // 빼고 싶은 곳 (잘못 같이 잡힌 옆 치아)
                for (final (nx, ny) in negatives)
                  {'x': nx, 'y': ny, 'label': 0},
              ],
              'apply_mask': false,
              'output_format': 'png',
              'sync_mode': true,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const PipelineError('자동 선택(SAM) 응답이 너무 늦습니다. 인터넷을 확인해 주세요.');
    } catch (e) {
      throw PipelineError('자동 선택(SAM)에 연결하지 못했습니다. ($e)');
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw const PipelineError('Fal.ai API 키가 맞지 않습니다. [API 키 설정]을 확인해 주세요.');
    }
    if (r.statusCode == 402 || r.statusCode == 429) {
      throw const PipelineError('Fal.ai 크레딧이 부족하거나 요청이 많습니다. 잠시 뒤 다시 탭해 주세요.');
    }
    if (r.statusCode != 200) {
      throw PipelineError('자동 선택(SAM) 실패 (${r.statusCode})');
    }
    final j = jsonDecode(r.body);
    final url = j is Map && j['image'] is Map
        ? (j['image'] as Map)['url']
        : null;
    if (url is! String) {
      throw const PipelineError('자동 선택(SAM)이 마스크를 돌려주지 않았습니다.');
    }
    final Uint8List bytes;
    if (url.startsWith('data:')) {
      bytes = base64Decode(url.substring(url.indexOf(',') + 1));
    } else {
      final g = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (g.statusCode != 200) {
        throw const PipelineError('자동 선택(SAM) 마스크를 내려받지 못했습니다.');
      }
      bytes = g.bodyBytes;
    }
    final m = img.decodeImage(bytes);
    if (m == null) throw const PipelineError('자동 선택(SAM) 마스크를 읽지 못했습니다.');
    return m;
  }
}

/// 마스크 값 (0~255)
int maskAt(img.Image m, int x, int y) {
  if (x < 0 || y < 0 || x >= m.width || y >= m.height) return 0;
  final p = m.getPixel(x, y);
  return m.numChannels == 1 ? p.r.toInt() : p.r.toInt();
}

/// 치아 하나 선택 (마스크 + 기준점)
class ToothSel {
  ToothSel({
    required this.mask,
    required this.tap,
    required this.box,
    required this.upper,
    required this.zenith,
    required this.incisal,
    this.label = '',
  });
  final img.Image mask; // 회색조, 선택 사진(AI 로 보내는 크기)과 같은 크기
  final Offset tap; // 0~1
  final Rect box; // 0~1 (치아 바운딩 박스)
  final bool upper; // 상악 치아 (잇몸이 위쪽)
  Offset zenith; // 📍 치은 정점 (잇몸 꼭대기) 0~1 — 손으로 옮길 수 있음
  Offset incisal; // 📍 절단끝 중앙 0~1
  String label; // '#11' 또는 '치아 1'

  int get area => _area(mask);
}

int _area(img.Image m) {
  var n = 0;
  for (final p in m) {
    if (p.r > 127) n++;
  }
  return n;
}

/// SAM 마스크 → 선택 정보. 치아가 아닌 것 같으면 null (너무 크거나 작음)
ToothSel? analyzeSel(img.Image photo, img.Image raw, Offset tap) {
  // 크기를 사진에 맞추고 0/255 로
  final w = photo.width, h = photo.height;
  var m = raw;
  if (m.width != w || m.height != h) {
    m = img.copyResize(
      m,
      width: w,
      height: h,
      interpolation: img.Interpolation.nearest,
    );
  }
  final bin = img.Image(width: w, height: h, numChannels: 1);
  var x0 = w, y0 = h, x1 = -1, y1 = -1, n = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = m.getPixel(x, y).r;
      if (v > 127) {
        bin.setPixelR(x, y, 255);
        n++;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  if (n < w * h * 0.0004 || n > w * h * 0.12) return null; // 점 하나 / 입 전체 같은 것
  // 상악·하악: 마스크 바로 위쪽이 더 붉으면(잇몸) 상악
  double redness(int y) {
    var s = 0.0, k = 0;
    for (var x = x0; x <= x1; x += 2) {
      if (y < 0 || y >= h) continue;
      final p = photo.getPixel(x, y);
      s += p.r - (p.g + p.b) / 2;
      k++;
    }
    return k == 0 ? 0 : s / k;
  }

  // 상악·하악 판별: ① 치관은 잇몸 쪽(치경부)이 절단 쪽보다 좁음 (가장 확실한 단서)
  //                ② 잇몸 쪽이 더 붉음 (보조)
  final gap = math.max(3, ((y1 - y0) * 0.12).round());
  final hh = y1 - y0;
  int widthAt(int y) {
    var n = 0;
    for (var x = x0; x <= x1; x++) {
      if (bin.getPixel(x, y).r > 0) n++;
    }
    return n;
  }

  final wTop = (widthAt(y0 + hh ~/ 10) + widthAt(y0 + hh ~/ 5)) / 2;
  final wBot = (widthAt(y1 - hh ~/ 10) + widthAt(y1 - hh ~/ 5)) / 2;
  final shape = (wBot - wTop) / math.max(1, math.max(wTop, wBot));
  final red = (redness(y0 - gap) - redness(y1 + gap)) / 60;
  final upper = shape + 0.5 * red >= 0;
  // 기준점: 가운데 1/3 열에서 잇몸 쪽 끝(정점) / 절단 쪽 끝
  final cx0 = x0 + (x1 - x0) ~/ 3, cx1 = x1 - (x1 - x0) ~/ 3;
  int? zx, zy, ix, iy;
  for (var x = cx0; x <= cx1; x++) {
    int? top, bottom;
    for (var y = y0; y <= y1; y++) {
      if (bin.getPixel(x, y).r > 0) {
        top ??= y;
        bottom = y;
      }
    }
    if (top == null) continue;
    final gumY = upper ? top : bottom!, cutY = upper ? bottom! : top;
    if (zy == null || (upper ? gumY < zy : gumY > zy)) {
      zy = gumY;
      zx = x;
    }
    if (iy == null || (upper ? cutY > iy : cutY < iy)) {
      iy = cutY;
      ix = x;
    }
  }
  if (zy == null || iy == null) return null;
  final cx = (x0 + x1) / 2;
  return ToothSel(
    mask: bin,
    tap: tap,
    box: Rect.fromLTRB(x0 / w, y0 / h, (x1 + 1) / w, (y1 + 1) / h),
    upper: upper,
    // 정점은 그 열, 절단끝은 치아 가운데 열 기준
    zenith: Offset(zx! / w, zy / h),
    incisal: Offset((ix! + cx) / 2 / w, iy / h),
  );
}

/// FDI 번호 붙이기: 치아 차트에서 고른 같은 악궁 치아 수와 선택 수가 같으면 왼쪽→오른쪽 순서대로
/// (정면 사진: 사진 왼쪽 = 환자 오른쪽 → 18…11, 21…28)
void labelTeeth(List<ToothSel> sels, List<int> chartTeeth) {
  for (final upper in [true, false]) {
    final group = sels.where((s) => s.upper == upper).toList()
      ..sort((a, b) => a.box.center.dx.compareTo(b.box.center.dx));
    final arch = upper
        ? [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28]
        : [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38];
    final chosen = arch.where(chartTeeth.contains).toList();
    for (var i = 0; i < group.length; i++) {
      group[i].label = chosen.length == group.length
          ? '#${chosen[i]}'
          : '${upper ? '상악' : '하악'} ${i + 1}';
    }
  }
}

/// 여러 치아 마스크 합치기 + 손으로 더하기/빼기 (획 좌표 0~1, 굵기 r 은 사진 너비 비율)
img.Image unionMask(
  int w,
  int h,
  List<img.Image> masks,
  List<MaskStroke> edits,
) {
  final out = img.Image(width: w, height: h, numChannels: 1);
  for (final m in masks) {
    final same = m.width == w && m.height == h;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = same
            ? m.getPixel(x, y).r
            : m.getPixel(x * m.width ~/ w, y * m.height ~/ h).r;
        if (v > 127) out.setPixelR(x, y, 255);
      }
    }
  }
  for (final s in edits) {
    final r = math.max(1, (s.r * w).round());
    final c = s.erase
        ? img.ColorUint8.rgb(0, 0, 0)
        : img.ColorUint8.rgb(255, 255, 255);
    for (var i = 0; i < s.pts.length; i++) {
      final a = s.pts[i], b = s.pts[i == 0 ? 0 : i - 1];
      final ax = a.dx * w, ay = a.dy * h, bx = b.dx * w, by = b.dy * h;
      final steps = math.max(
        1,
        (math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by)) / (r / 2))
            .ceil(),
      );
      for (var k = 0; k <= steps; k++) {
        final t = k / steps;
        img.fillCircle(
          out,
          x: (bx + (ax - bx) * t).round(),
          y: (by + (ay - by) * t).round(),
          radius: r,
          color: c,
        );
      }
    }
  }
  return out;
}

/// 변환할 영역: 합친 마스크 + (길이가 바뀌는 치료면) 절단 쪽으로 치관 길이의 [grow] 만큼 여유
img.Image editRegion(img.Image union, List<ToothSel> sels, {double grow = 0}) {
  if (grow <= 0) return union;
  final out = union.clone();
  final w = union.width, h = union.height;
  for (final s in sels) {
    final crown = ((s.incisal.dy - s.zenith.dy).abs() * h);
    final ext = (crown * grow).round();
    if (ext < 1) continue;
    final bx0 = (s.box.left * w).floor(), bx1 = (s.box.right * w).ceil();
    for (var x = math.max(0, bx0); x < math.min(w, bx1); x++) {
      // 이 열에서 치아의 절단 쪽 끝
      int? edge;
      for (var y = 0; y < h; y++) {
        if (s.mask.getPixel(x, y).r > 127) {
          if (s.upper) {
            edge = y;
          } else {
            edge ??= y;
          }
        }
      }
      if (edge == null) continue;
      for (var k = 1; k <= ext; k++) {
        final y = edge + (s.upper ? k : -k);
        if (y < 0 || y >= h) break;
        out.setPixelR(x, y, 255);
      }
    }
  }
  return out;
}

/// ③ 마진 고정형 변환 영역: 고른 치아의 **잇몸 쪽 경계(서비컬)만 고정**하고
/// 절단 쪽으로 [incisal](치아 길이 대비)만큼, 옆에 고른 치아가 있으면 그쪽 틈까지 [lateral] 만큼 넓게 열어 줌.
/// → 마진은 그대로, 치아 길이·폭·깨진 절단끝·벌어진 틈은 새로 만들 수 있음
img.Image marginLockedRegion(
  img.Image union,
  List<ToothSel> sels, {
  double incisal = 0.25,
  double lateral = 0.15,
}) {
  final out = union.clone();
  final w = union.width, h = union.height;
  for (final s in sels) {
    final m = s.mask;
    final bx0 = math.max(0, (s.box.left * w).floor());
    final bx1 = math.min(w - 1, (s.box.right * w).ceil());
    // 열마다 잇몸 쪽 끝(cerv)과 절단 쪽 끝(edge)
    final cerv = <int, int>{}, edge = <int, int>{};
    for (var x = bx0; x <= bx1; x++) {
      int? top, bot;
      for (var y = 0; y < h; y++) {
        if (m.getPixel(x, y).r > 127) {
          top ??= y;
          bot = y;
        }
      }
      if (top == null || bot == null) continue;
      cerv[x] = s.upper ? top : bot;
      edge[x] = s.upper ? bot : top;
    }
    if (cerv.isEmpty) continue;
    final cols = cerv.keys.toList()..sort();
    final first = cols.first, last = cols.last;
    final crownPx = math.max(
      ((s.incisal.dy - s.zenith.dy).abs() * h),
      (s.box.height * h * 0.6),
    );
    final ext = (crownPx * incisal).round();
    // 절단 쪽 한계: 이 치아에서 가장 긴 곳 + ext (들쭉날쭉한 절단끝도 고르게 채울 수 있게)
    final limit = s.upper
        ? edge.values.reduce(math.max) + ext
        : edge.values.reduce(math.min) - ext;
    // 옆에 같은 턱의 고른 치아가 있으면 그쪽으로 틈까지 열기, 없으면 아주 조금만
    final tw = (last - first + 1).toDouble();
    bool neighbor(int dir) => sels.any(
      (o) =>
          !identical(o, s) &&
          o.upper == s.upper &&
          (dir < 0
              ? o.box.center.dx < s.box.center.dx
              : o.box.center.dx > s.box.center.dx) &&
          (o.box.center.dx - s.box.center.dx).abs() * w < tw * 2.2,
    );
    final wl = (tw * (neighbor(-1) ? lateral : 0.03)).round();
    final wr = (tw * (neighbor(1) ? lateral : 0.03)).round();
    for (
      var x = math.max(0, first - wl);
      x <= math.min(w - 1, last + wr);
      x++
    ) {
      // 넓힌 옆 칸은 가장 가까운 치아 열의 잇몸 높이를 씀 (잇몸 꼭지는 그대로)
      final kx = x < first ? first : (x > last ? last : x);
      var c = cerv[kx];
      if (c == null) {
        // 윤곽 중간에 빈 열이 있으면 가까운 열에서
        for (var d = 1; d < cols.length && c == null; d++) {
          c = cerv[kx - d] ?? cerv[kx + d];
        }
      }
      if (c == null) continue;
      if (s.upper) {
        for (var y = c; y <= math.min(h - 1, limit); y++) {
          out.setPixelR(x, y, 255);
        }
      } else {
        for (var y = math.max(0, limit); y <= c; y++) {
          out.setPixelR(x, y, 255);
        }
      }
    }
  }
  return out;
}

/// 사진 위에 깔 반투명 하이라이트 (민트) — 경계는 진하게
Uint8List overlayPng(img.Image union, {int maxSide = 900}) {
  var m = union;
  final k = maxSide / math.max(m.width, m.height);
  if (k < 1) {
    m = img.copyResize(
      m,
      width: (m.width * k).round(),
      height: (m.height * k).round(),
      interpolation: img.Interpolation.nearest,
    );
  }
  final o = img.Image(width: m.width, height: m.height, numChannels: 4);
  bool on(int x, int y) =>
      x >= 0 &&
      y >= 0 &&
      x < m.width &&
      y < m.height &&
      m.getPixel(x, y).r > 127;
  for (var y = 0; y < m.height; y++) {
    for (var x = 0; x < m.width; x++) {
      if (!on(x, y)) continue;
      final edge =
          !on(x - 1, y) || !on(x + 1, y) || !on(x, y - 1) || !on(x, y + 1);
      o.setPixelRgba(
        x,
        y,
        edge ? 0 : 0,
        edge ? 230 : 214,
        edge ? 190 : 180,
        edge ? 240 : 105,
      );
    }
  }
  return img.encodePng(o);
}

/// 결과에서 선택 바깥(잇몸·인접 치아·입술)은 원본 픽셀로 되돌림 (경계 2px 부드럽게)
Uint8List protectOutside((img.Image, Uint8List, img.Image) a) {
  final (src, aiBytes, region) = a;
  var out = img.decodeImage(aiBytes)!;
  if (out.width != src.width || out.height != src.height) {
    out = img.copyResize(
      out,
      width: src.width,
      height: src.height,
      interpolation: img.Interpolation.cubic,
    );
  }
  final soft = img.gaussianBlur(region.clone(), radius: 2);
  final sx = soft.width / src.width, sy = soft.height / src.height;
  for (var y = 0; y < src.height; y++) {
    final my = math.min(soft.height - 1, (y * sy).floor());
    for (var x = 0; x < src.width; x++) {
      final a =
          soft.getPixel(math.min(soft.width - 1, (x * sx).floor()), my).r /
          255.0;
      if (a >= 0.999) continue;
      final s = src.getPixel(x, y), r = out.getPixel(x, y);
      out.setPixelRgb(
        x,
        y,
        (s.r * (1 - a) + r.r * a).round(),
        (s.g * (1 - a) + r.g * a).round(),
        (s.b * (1 - a) + r.b * a).round(),
      );
    }
  }
  return img.encodeJpg(out, quality: 92);
}

/// 치아마다 잇몸쪽·절단쪽 윤곽선 → 기존 서비컬/절단선 보호(픽셀 복원·마진 띠)에 그대로 사용
List<GuideLine> contourLines(List<ToothSel> sels) {
  final out = <GuideLine>[];
  for (final s in sels) {
    final w = s.mask.width, h = s.mask.height;
    final x0 = (s.box.left * w).floor(), x1 = (s.box.right * w).ceil() - 1;
    // 가장자리 10%는 둥글게 말려 있어 빼고 씀
    final pad = ((x1 - x0) * 0.1).round();
    final cerv = <Offset>[], inc = <Offset>[];
    final step = math.max(1, (x1 - x0) ~/ 24);
    for (var x = x0 + pad; x <= x1 - pad; x += step) {
      int? top, bottom;
      for (var y = 0; y < h; y++) {
        if (s.mask.getPixel(x, y).r > 127) {
          top ??= y;
          bottom = y;
        }
      }
      if (top == null) continue;
      cerv.add(Offset(x / w, (s.upper ? top : bottom!) / h));
      inc.add(Offset(x / w, (s.upper ? bottom! : top) / h));
    }
    if (cerv.length < 2) continue;
    out.add(GuideLine(upper: s.upper, pts: cerv));
    out.add(GuideLine(upper: s.upper, incisal: true, pts: inc));
  }
  return out;
}

/// A④ 마진 띠 잠금: 서비컬(마진) 선에서 치아 쪽으로 치관 길이의 [frac] 만큼은 원본 그대로 (끝은 부드럽게)
/// → AI 가 '예쁘게' 하려고 치경부를 좁히거나 마진을 올리는 것을 막음
void applyMarginBand(
  img.Image src,
  img.Image out,
  List<GuideLine> lines, {
  double frac = 0.07,
}) {
  double? yAt(List<Offset> pts, double x) {
    if (pts.length < 2) return null;
    final s = [...pts]..sort((a, b) => a.dx.compareTo(b.dx));
    if (x < s.first.dx || x > s.last.dx) return null;
    for (var i = 1; i < s.length; i++) {
      if (x <= s[i].dx) {
        final a = s[i - 1], b = s[i], d = b.dx - a.dx;
        return d <= 0 ? a.dy : a.dy + (b.dy - a.dy) * (x - a.dx) / d;
      }
    }
    return s.last.dy;
  }

  final incs = lines.where((l) => l.incisal).toList();
  final cervs = lines.where((l) => !l.incisal).toList();
  for (var px = 0; px < out.width; px++) {
    final fx = px / out.width;
    for (final c in cervs) {
      final yc0 = yAt(c.pts, fx);
      if (yc0 == null) continue;
      final yi0 = incs
          .where((i) => i.upper == c.upper)
          .map((i) => yAt(i.pts, fx))
          .whereType<double>()
          .firstOrNull;
      if (yi0 == null) continue;
      final yc = yc0 * out.height, yi = yi0 * out.height;
      final crown = (yi - yc).abs();
      if (crown < 6) continue;
      final band = math.max(2.0, crown * frac);
      final dir = yi > yc ? 1 : -1;
      for (var k = 0; k <= band.ceil(); k++) {
        final y = (yc + dir * k).round();
        if (y < 0 || y >= out.height) continue;
        final t = k / band;
        final a = t < 0.6
            ? 1.0
            : (1 - (t - 0.6) / 0.4).clamp(0.0, 1.0); // 원본 비율
        final s = src.getPixel(px, y), r = out.getPixel(px, y);
        out.setPixelRgb(
          px,
          y,
          (s.r * a + r.r * (1 - a)).round(),
          (s.g * a + r.g * (1 - a)).round(),
          (s.b * a + r.b * (1 - a)).round(),
        );
      }
    }
  }
}

/// A③ 치아별 숫자 측정
class ToothMeasure {
  const ToothMeasure(this.label, {this.length, this.margin});
  final String label;
  final double? length; // 결과 치관 길이 / 원본 (1.0 = 같음, 0.92 = 8% 짧음). null: 못 잼
  final double? margin; // 마진(정점) 이동 / 원본 치관 길이 (0.03 = 3%)
  bool get shorter => length != null && length! < kMinLength;
  bool get marginMoved => margin != null && margin! > kMaxMargin;
  bool get ok => !shorter && !marginMoved;
  String get text {
    final l = length == null ? '길이 ?' : '길이 ${(length! * 100).round()}%';
    final m = margin == null
        ? ''
        : ' · 마진 ${(margin! * 100).toStringAsFixed(0)}%';
    return '$label $l$m${ok ? '' : ' ⚠'}';
  }
}

const kMinLength = 0.98; // 원본보다 2% 넘게 짧으면 미달
const kMaxMargin = 0.05; // 마진이 치관 길이의 5% 넘게 움직이면 미달

/// 치아마다 (정점 → 절단끝) 길이와 마진 위치를 원본·결과에서 비교
List<ToothMeasure> measureTeeth(
  img.Image orig,
  img.Image res,
  List<({String label, bool upper, Offset zenith, Offset incisal})> marks,
) {
  final out = <ToothMeasure>[];
  for (final m in marks) {
    final w = res.width, h = res.height;
    final yc = (m.zenith.dy * h).round(), yi = (m.incisal.dy * h).round();
    final crown = (yi - yc).abs();
    if (crown < 8) {
      out.add(ToothMeasure(m.label));
      continue;
    }
    final cx = ((m.zenith.dx + m.incisal.dx) / 2 * w).round();
    final edges = <int>[];
    final tops = <int>[];
    for (final dx in [-crown ~/ 8, 0, crown ~/ 8]) {
      final x = (cx + dx).clamp(0, w - 1);
      final e = edgeInColumn(res, x, yc, m.upper, crown, near: yi);
      if (e != null) edges.add(e);
      // 결과의 마진: 정점 근처에서 치아가 시작되는 곳
      final dir = m.upper ? 1 : -1;
      final mid = (yc + dir * crown * 0.4).round().clamp(0, h - 1);
      final base = toothness(res, x, mid);
      if (base < 90) continue;
      for (var k = -(crown * 0.3).round(); k <= (crown * 0.3).round(); k++) {
        final y = yc + dir * k;
        if (y < 0 || y >= h) continue;
        if (toothness(res, x, y) >= base * 0.72) {
          tops.add(y);
          break;
        }
      }
    }
    double? length, margin;
    if (edges.isNotEmpty) {
      edges.sort();
      length = (edges[edges.length ~/ 2] - yc).abs() / crown;
    }
    if (tops.isNotEmpty) {
      // 원본 마진도 같은 방식으로 재서 비교 (사진마다 감지 기준을 맞춤)
      final otops = <int>[];
      final dir = m.upper ? 1 : -1;
      for (final dx in [-crown ~/ 8, 0, crown ~/ 8]) {
        final x = (cx + dx).clamp(0, w - 1);
        final mid = (yc + dir * crown * 0.4).round().clamp(0, h - 1);
        final base = toothness(orig, x, mid);
        if (base < 90) continue;
        for (var k = -(crown * 0.3).round(); k <= (crown * 0.3).round(); k++) {
          final y = yc + dir * k;
          if (y < 0 || y >= h) continue;
          if (toothness(orig, x, y) >= base * 0.72) {
            otops.add(y);
            break;
          }
        }
      }
      if (otops.isNotEmpty) {
        tops.sort();
        otops.sort();
        margin =
            (tops[tops.length ~/ 2] - otops[otops.length ~/ 2]).abs() / crown;
      }
    }
    out.add(ToothMeasure(m.label, length: length, margin: margin));
  }
  return out;
}

/// A⑤ 원본 윤곽 겹쳐 보기: 원본의 마진선(초록)·절단선(노랑)을 점선으로 그린 투명 PNG
Uint8List contourOverlayPng(
  List<GuideLine> lines,
  int w,
  int h, {
  int maxSide = 1200,
}) {
  final k = math.min(1.0, maxSide / math.max(w, h));
  final ow = (w * k).round(), oh = (h * k).round();
  final o = img.Image(width: ow, height: oh, numChannels: 4);
  final th = math.max(2, (ow / 400).round());
  for (final l in lines) {
    final c = l.incisal
        ? img.ColorRgba8(255, 210, 0, 255)
        : img.ColorRgba8(0, 230, 120, 255);
    var dist = 0.0;
    for (var i = 1; i < l.pts.length; i++) {
      final a = Offset(l.pts[i - 1].dx * ow, l.pts[i - 1].dy * oh);
      final b = Offset(l.pts[i].dx * ow, l.pts[i].dy * oh);
      final len = (b - a).distance;
      final n = math.max(1, (len / 2).ceil());
      for (var j = 0; j < n; j++) {
        final t = j / n;
        dist += len / n;
        if ((dist ~/ (th * 4)).isOdd) continue; // 점선
        final p = Offset.lerp(a, b, t)!;
        img.fillCircle(
          o,
          x: p.dx.round(),
          y: p.dy.round(),
          radius: th ~/ 2 + 1,
          color: img.ColorRgba8(0, 0, 0, 150),
        );
        img.fillCircle(
          o,
          x: p.dx.round(),
          y: p.dy.round(),
          radius: th ~/ 2,
          color: c,
        );
      }
    }
  }
  return img.encodePng(o);
}

// -----------------------------------------------------------------------------
// B② 치아 크기 조절 (사진 늘이기 · AI 비용 없음)
// -----------------------------------------------------------------------------
/// 치아 하나를 위/아래/왼쪽/오른쪽으로 키움 (값은 픽셀). 주변은 부드럽게 따라 늘어나고,
/// [pad] 바깥은 그대로.
img.Image warpTooth(
  img.Image src,
  Rect box, {
  double left = 0,
  double right = 0,
  double up = 0,
  double down = 0,
  double? pad,
}) {
  if (left == 0 && right == 0 && up == 0 && down == 0) return src;
  final p = pad ?? math.max(box.width, box.height) * 0.6;
  final out = src.clone();
  final nx0 = box.left - left, nx1 = box.right + right;
  final ny0 = box.top - up, ny1 = box.bottom + down;
  final rx0 = math.min(nx0, box.left) - p, rx1 = math.max(nx1, box.right) + p;
  final ry0 = math.min(ny0, box.top) - p, ry1 = math.max(ny1, box.bottom) + p;
  // 새 좌표 → 원래 좌표 (구간별 직선, 바깥 경계는 그대로)
  double map(
    double v,
    double a0,
    double n0,
    double n1,
    double a1,
    double o0,
    double o1,
  ) {
    if (v <= a0 || v >= a1) return v;
    if (v < n0) return a0 + (v - a0) * (o0 - a0) / (n0 - a0);
    if (v <= n1) return o0 + (v - n0) * (o1 - o0) / (n1 - n0);
    return o1 + (v - n1) * (a1 - o1) / (a1 - n1);
  }

  // 치아에서 멀어질수록 늘이는 효과를 줄임 (경계에서 0 → 이음매 없음)
  double fall(double v, double n0, double n1, double a0, double a1) {
    if (v >= n0 && v <= n1) return 1;
    final t = v < n0 ? (v - a0) / (n0 - a0) : (a1 - v) / (a1 - n1);
    final c = t.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  final xs0 = math.max(0, rx0.floor()),
      xs1 = math.min(src.width - 1, rx1.ceil());
  final ys0 = math.max(0, ry0.floor()),
      ys1 = math.min(src.height - 1, ry1.ceil());
  for (var y = ys0; y <= ys1; y++) {
    for (var x = xs0; x <= xs1; x++) {
      final fx = fall(x.toDouble(), nx0, nx1, rx0, rx1);
      final fy = fall(y.toDouble(), ny0, ny1, ry0, ry1);
      final mx = map(x.toDouble(), rx0, nx0, nx1, rx1, box.left, box.right);
      final my = map(y.toDouble(), ry0, ny0, ny1, ry1, box.top, box.bottom);
      final sxv = x + (mx - x) * fy; // 가로 늘이기는 치아 높이 범위에서만
      final syv = y + (my - y) * fx;
      final c = src.getPixelInterpolate(
        sxv,
        syv,
        interpolation: img.Interpolation.linear,
      );
      out.setPixelRgb(x, y, c.r.toInt(), c.g.toInt(), c.b.toInt());
    }
  }
  return out;
}

/// 🦷 치아 윤곽만 키우기: [mask](치아 = 흰색, 크기 무관) 안의 치아 픽셀만 [box](픽셀) 기준으로
/// 위/아래/왼쪽/오른쪽으로 늘려 원래 사진 위에 덮음. 잇몸·옆 치아는 원본 그대로 (키운 치아가 앞으로).
img.Image scaleToothMasked(
  img.Image src,
  img.Image mask,
  Rect box, {
  double left = 0,
  double right = 0,
  double up = 0,
  double down = 0,
}) {
  if (left == 0 && right == 0 && up == 0 && down == 0) return src;
  final out = src.clone();
  // 경계를 2~3px 부드럽게 (마스크 크기에서 살짝 흐림)
  final soft = img.gaussianBlur(
    mask.numChannels == 1 ? mask.clone() : img.grayscale(mask.clone()),
    radius: math.max(1, (mask.width / src.width * 1.5).round()),
  );
  final nx0 = box.left - left, nx1 = box.right + right;
  final ny0 = box.top - up, ny1 = box.bottom + down;
  final kx = box.width / math.max(1e-6, nx1 - nx0);
  final ky = box.height / math.max(1e-6, ny1 - ny0);
  final mx = soft.width / src.width, my = soft.height / src.height;
  // ➖ 줄이기(음수): 원래 치아 자리를 먼저 치아 바깥 배경으로 채움
  //   AI 치아 윤곽은 실제 치아보다 조금 작을 때가 많아 → 윤곽을 넉넉히 넓혀서(잔상 방지)
  //   그 바깥에서 배경을 끌어옴: 절단끝 → 아래(입 안·아래 치아), 잇몸 쪽 → 위 잇몸, 옆 → 옆 공간
  if (left < 0 || right < 0 || up < 0 || down < 0) {
    final mxH = box.height * 0.08 + 3, mxW = box.width * 0.08 + 3; // 넓히는 양(px)
    final wide = img.gaussianBlur(
      mask.numChannels == 1 ? mask.clone() : img.grayscale(mask.clone()),
      radius: math.max(2, (mxH * 1.3 * mask.height / src.height).round()),
    );
    final cx = box.center.dx, cy = box.center.dy;
    final bx0 = math.max(0, (box.left - mxW).floor()),
        bx1 = math.min(src.width - 1, (box.right + mxW).ceil());
    final by0 = math.max(0, (box.top - mxH).floor()),
        by1 = math.min(src.height - 1, (box.bottom + mxH).ceil());
    for (var y = by0; y <= by1; y++) {
      for (var x = bx0; x <= bx1; x++) {
        final w0 =
            wide
                .getPixelInterpolate(
                  x * mx,
                  y * my,
                  interpolation: img.Interpolation.linear,
                )
                .r /
            255.0;
        if (w0 <= 0.02) continue;
        // 넓힌 윤곽 안은 확실히 덮고(가장자리만 살짝 부드럽게)
        final a0 = math.min(1.0, w0 * 6);
        double fx = x.toDouble(), fy = y.toDouble();
        if (down < 0 && y >= cy) {
          fy = y - down + mxH; // 줄인 만큼 + 넓힌 만큼 아래에서
        } else if (up < 0 && y < cy) {
          fy = y + up - mxH;
        } else if (left < 0 && x < cx) {
          fx = x + left - mxW;
        } else if (right < 0 && x >= cx) {
          fx = x - right + mxW;
        } else {
          continue;
        }
        fx = fx.clamp(0, src.width - 1).toDouble();
        fy = fy.clamp(0, src.height - 1).toDouble();
        final c = src.getPixelInterpolate(
          fx,
          fy,
          interpolation: img.Interpolation.linear,
        );
        final o = out.getPixel(x, y);
        out.setPixelRgb(
          x,
          y,
          (o.r * (1 - a0) + c.r * a0).round(),
          (o.g * (1 - a0) + c.g * a0).round(),
          (o.b * (1 - a0) + c.b * a0).round(),
        );
      }
    }
  }
  final xs0 = math.max(0, (nx0 - 3).floor()),
      xs1 = math.min(src.width - 1, (nx1 + 3).ceil());
  final ys0 = math.max(0, (ny0 - 3).floor()),
      ys1 = math.min(src.height - 1, (ny1 + 3).ceil());
  for (var y = ys0; y <= ys1; y++) {
    final sy = box.top + (y - ny0) * ky; // 늘린 자리 → 원래 치아 자리
    if (sy < 0 || sy > src.height - 1) continue;
    for (var x = xs0; x <= xs1; x++) {
      final sx = box.left + (x - nx0) * kx;
      if (sx < 0 || sx > src.width - 1) continue;
      final a =
          soft
              .getPixelInterpolate(
                sx * mx,
                sy * my,
                interpolation: img.Interpolation.linear,
              )
              .r /
          255.0;
      if (a <= 0.01) continue;
      final c = src.getPixelInterpolate(
        sx,
        sy,
        interpolation: img.Interpolation.linear,
      );
      final o = out.getPixel(x, y);
      out.setPixelRgb(
        x,
        y,
        (o.r * (1 - a) + c.r * a).round(),
        (o.g * (1 - a) + c.g * a).round(),
        (o.b * (1 - a) + c.b * a).round(),
      );
    }
  }
  return out;
}

/// 🔍 탭한 곳 주변만 잘라 크게 키워 SAM 에 보냄 → 작은 치아도 하나씩 정확히 (얼굴 사진처럼 치아가 작을 때 특히)
/// [negatives]: 빼고 싶은 점(0~1). 결과는 [small] 과 같은 크기의 마스크.
Future<img.Image> segmentAround(
  FalSam sam,
  img.Image small,
  Offset p, {
  List<Offset> negatives = const [],
  double frac = 0.12,
}) async {
  final w = small.width, h = small.height;
  for (var tryN = 0; tryN < 2; tryN++) {
    final half = math.max(
      48,
      (math.max(w, h) * frac * (tryN == 0 ? 1 : 2)).round(),
    );
    final cx = (p.dx * w).round(), cy = (p.dy * h).round();
    final int x0 = (cx - half).clamp(0, math.max(0, w - 2 * half)).toInt();
    final int y0 = (cy - half).clamp(0, math.max(0, h - 2 * half)).toInt();
    final cw = math.min(2 * half, w), ch = math.min(2 * half, h);
    final crop = img.copyCrop(small, x: x0, y: y0, width: cw, height: ch);
    final k = 1024 / math.max(cw, ch);
    final big = k > 1
        ? img.copyResize(
            crop,
            width: (cw * k).round(),
            height: (ch * k).round(),
            interpolation: img.Interpolation.cubic,
          )
        : crop;
    final kk = big.width / cw;
    final raw = await sam.segment(
      img.encodeJpg(big, quality: 92),
      ((cx - x0) * kk).round().clamp(0, big.width - 1),
      ((cy - y0) * kk).round().clamp(0, big.height - 1),
      negatives: [
        for (final n in negatives)
          if (n.dx * w >= x0 &&
              n.dx * w < x0 + cw &&
              n.dy * h >= y0 &&
              n.dy * h < y0 + ch)
            (((n.dx * w - x0) * kk).round(), ((n.dy * h - y0) * kk).round()),
      ],
    );
    final m = img.copyResize(
      raw,
      width: cw,
      height: ch,
      interpolation: img.Interpolation.nearest,
    );
    // 잘라낸 칸 가장자리에 많이 닿으면 → 치아가 칸보다 큼 → 더 넓게 다시
    var edge = 0, edgeAll = 0;
    for (var i = 0; i < cw; i++) {
      for (final y in [0, ch - 1]) {
        edgeAll++;
        if (m.getPixel(i, y).r > 127) edge++;
      }
    }
    for (var j = 0; j < ch; j++) {
      for (final x in [0, cw - 1]) {
        edgeAll++;
        if (m.getPixel(x, j).r > 127) edge++;
      }
    }
    if (tryN == 0 && edge > edgeAll * 0.08) continue;
    final out = img.Image(width: w, height: h, numChannels: 1);
    for (var j = 0; j < ch; j++) {
      for (var i = 0; i < cw; i++) {
        if (m.getPixel(i, j).r > 127) out.setPixelR(x0 + i, y0 + j, 255);
      }
    }
    return out;
  }
  throw StateError('unreachable');
}
