import 'dart:convert';
import 'dart:ui' show Offset, Rect;

import 'package:dental_app/ai/tooth_select.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

/// 400x300: 위 잇몸(분홍) 아래 치아 6개 (x=60+50i .. +44, y 100..200), 입안 어두움
img.Image photo({int edge = 200}) {
  final im = img.Image(width: 400, height: 300)
    ..clear(img.ColorRgb8(60, 25, 30));
  img.fillRect(
    im,
    x1: 40,
    y1: 60,
    x2: 360,
    y2: 100,
    color: img.ColorRgb8(200, 110, 120),
  );
  for (var i = 0; i < 6; i++) {
    final x = 60 + 50 * i;
    img.fillRect(
      im,
      x1: x,
      y1: 100,
      x2: x + 44,
      y2: edge,
      color: img.ColorRgb8(235, 225, 205),
    );
  }
  return im;
}

/// 가짜 SAM: i번째 치아 사각형 마스크
img.Image samMask(int i, {int w = 400, int h = 300}) {
  final m = img.Image(width: w, height: h, numChannels: 1);
  final x = 60 + 50 * i;
  img.fillRect(
    m,
    x1: x,
    y1: 100,
    x2: x + 44,
    y2: 200,
    color: img.ColorRgb8(255, 255, 255),
  );
  return m;
}

void main() {
  test('SAM 호출: 탭 좌표를 보내고 마스크(data URI)를 받아 읽음', () async {
    Map<String, dynamic>? sent;
    final client = MockClient((r) async {
      expect(r.url.toString(), 'https://fal.run/fal-ai/sam2/image');
      expect(r.headers['Authorization'], 'Key k');
      sent = jsonDecode(r.body) as Map<String, dynamic>;
      final png = base64Encode(img.encodePng(samMask(2)));
      return http.Response(
        jsonEncode({
          'image': {
            'url': 'data:image/png;base64,$png',
            'width': 400,
            'height': 300,
          },
        }),
        200,
      );
    });
    final m = await FalSam(
      'k',
      client: client,
    ).segment(img.encodeJpg(photo()), 182, 150);
    expect(sent!['prompts'], [
      {'x': 182, 'y': 150, 'label': 1},
    ]);
    expect(sent!['apply_mask'], false);
    expect(
      (sent!['image_url'] as String).startsWith('data:image/jpeg;base64,'),
      isTrue,
    );
    expect(m.getPixel(182, 150).r, 255);
    expect(m.getPixel(10, 10).r, 0);
    final bad = MockClient((r) async => http.Response('{}', 401));
    expect(
      () => FalSam('k', client: bad).segment(img.encodeJpg(photo()), 1, 1),
      throwsA(isA<Object>()),
    );
  });

  test('선택 분석: 상악 판별 · 기준점(정점/절단끝) · 너무 큰 마스크 거절', () {
    final s = analyzeSel(photo(), samMask(2), const Offset(0.45, 0.5))!;
    expect(s.upper, isTrue);
    expect(s.zenith.dy * 300, closeTo(100, 1));
    expect(s.incisal.dy * 300, closeTo(200, 1));
    expect(s.box.left * 400, closeTo(160, 1));
    final big = img.Image(width: 400, height: 300, numChannels: 1)
      ..clear(img.ColorRgb8(255, 255, 255));
    expect(analyzeSel(photo(), big, Offset.zero), isNull);
    final sels = [
      for (final i in [3, 2]) analyzeSel(photo(), samMask(i), Offset.zero)!,
    ];
    labelTeeth(sels, const [11, 21]);
    expect(sels.map((s) => s.label), ['#21', '#11']); // 사진 왼쪽이 11
  });

  test('합치기 + 손으로 더하기/빼기 + 절단 쪽 여유 + 하이라이트', () {
    final u = unionMask(
      400,
      300,
      [samMask(2), samMask(3)],
      [
        MaskStroke(r: 0.01, erase: true, pts: [const Offset(0.45, 0.5)]),
        MaskStroke(r: 0.01, erase: false, pts: [const Offset(0.05, 0.05)]),
      ],
    );
    expect(u.getPixel(170, 120).r, 255);
    expect(u.getPixel(230, 120).r, 255);
    expect(u.getPixel(180, 150).r, 0); // 빼기
    expect(u.getPixel(20, 15).r, 255); // 더하기
    expect(u.getPixel(130, 120).r, 0); // 안 고른 치아
    final s = analyzeSel(photo(), samMask(2), Offset.zero)!;
    final r = editRegion(u, [s], grow: 0.1);
    expect(r.getPixel(170, 208).r, 255); // 절단 쪽으로 10px 여유
    expect(r.getPixel(170, 95).r, 0); // 잇몸 쪽은 늘리지 않음
    expect(img.decodePng(overlayPng(u))!.getPixel(170, 120).a, greaterThan(50));
  });

  test('선택 바깥 100% 보호: 잇몸·인접 치아는 원본 그대로', () {
    final src = photo();
    final ai = img.Image(width: 400, height: 300)
      ..clear(img.ColorRgb8(255, 255, 255));
    final region = unionMask(400, 300, [samMask(2)], const []);
    final out = img.decodeJpg(
      protectOutside((src, img.encodeJpg(ai), region)),
    )!;
    expect(out.getPixel(180, 150).r, greaterThan(245)); // 선택 치아는 AI 결과
    final gum = out.getPixel(180, 80), orig = src.getPixel(180, 80);
    expect((gum.g - orig.g).abs(), lessThan(8)); // 잇몸 원본
    final nb = out.getPixel(130, 150);
    expect((nb.b - 205).abs(), lessThan(8)); // 옆 치아 원본
  });

  test('윤곽선 → 마진 띠 잠금 · 숫자 측정(짧아짐 감지) · 겹쳐 보기 PNG', () {
    final s = analyzeSel(photo(), samMask(2), Offset.zero)!;
    final lines = contourLines([s]);
    expect(
      lines.where((l) => l.incisal).single.pts.first.dy * 300,
      closeTo(200, 1.5),
    );
    // 결과: 치아가 짧아지고(180) 마진 쪽이 잇몸색으로 칠해짐(100~110)
    final res = photo(edge: 180);
    img.fillRect(
      res,
      x1: 160,
      y1: 100,
      x2: 204,
      y2: 110,
      color: img.ColorRgb8(200, 110, 120),
    );
    final marks = [
      (label: '#11', upper: true, zenith: s.zenith, incisal: s.incisal),
    ];
    final m = measureTeeth(photo(), res, marks).single;
    expect(m.length, closeTo(0.8, 0.05));
    expect(m.shorter, isTrue);
    expect(m.marginMoved, isTrue);
    expect(m.text, startsWith('#11 길이 8'));
    expect(m.text, endsWith('⚠'));
    expect(measureTeeth(photo(), photo(), marks).single.ok, isTrue);
    applyMarginBand(photo(), res, lines);
    expect(res.getPixel(182, 103).b, greaterThan(190)); // 마진 바로 아래는 원본 치아색
    final ov = img.decodePng(contourOverlayPng(lines, 400, 300))!;
    expect(ov.width, 400);
  });

  test('치아 크기 조절: 아래로 10px 키우면 절단끝이 10px 내려감, 멀리 있는 곳은 그대로', () {
    final src = photo();
    final out = warpTooth(
      src,
      const Rect.fromLTRB(160, 100, 205, 201),
      down: 10,
      left: 4,
    );
    expect(out.getPixel(182, 205).b, greaterThan(190)); // 원래 입안(어두움) → 치아
    expect(out.getPixel(182, 215).r, lessThan(120));
    expect(out.getPixel(5, 5), src.getPixel(5, 5));
    expect(out.getPixel(156, 150).b, greaterThan(150)); // 왼쪽으로 넓어짐
  });

  test('🔍 탭 주변만 잘라 크게 보내기: 잘라낸 칸 좌표 · 빼기 점 · 마스크를 원래 자리로', () async {
    Map<String, dynamic>? sent;
    final client = MockClient((r) async {
      sent = jsonDecode(r.body) as Map<String, dynamic>;
      final b = base64Decode((sent!['image_url'] as String).split(',').last);
      final im = img.decodeJpg(b)!;
      // 가짜 SAM: 받은 사진 가운데 40% 사각형 = 치아
      final m = img.Image(width: im.width, height: im.height, numChannels: 1);
      img.fillRect(
        m,
        x1: (im.width * 0.3).round(),
        y1: (im.height * 0.3).round(),
        x2: (im.width * 0.7).round(),
        y2: (im.height * 0.7).round(),
        color: img.ColorRgb8(255, 255, 255),
      );
      return http.Response(
        jsonEncode({
          'image': {
            'url': 'data:image/png;base64,${base64Encode(img.encodePng(m))}',
          },
        }),
        200,
      );
    });
    final small = photo(); // 400x300
    final out = await segmentAround(
      FalSam('k', client: client),
      small,
      const Offset(0.45, 0.5),
      negatives: [const Offset(0.5, 0.5), const Offset(0.95, 0.95)],
    );
    final b = base64Decode((sent!['image_url'] as String).split(',').last);
    expect(img.decodeJpg(b)!.width, 1024); // 잘라서 크게 (원래 400px 사진)
    final prompts = sent!['prompts'] as List;
    expect(prompts.first, containsPair('label', 1));
    expect(
      prompts.where((p) => (p as Map)['label'] == 0).length,
      1,
    ); // 칸 밖 빼기 점은 제외
    expect(out.width, 400);
    expect(out.getPixel(180, 150).r, 255); // 탭한 곳 근처가 선택됨
    expect(out.getPixel(20, 20).r, 0); // 먼 곳은 선택 안 됨
  });
}
