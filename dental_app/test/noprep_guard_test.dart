import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:dental_app/ai/noprep_guard.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 어두운 입안 + 잇몸(분홍) + 위 앞니(밝은 상아색) 블록. 절단끝 y = [edge]
img.Image mouth({int edge = 200, int r = 235, int g = 225, int b = 205}) {
  final im = img.Image(width: 400, height: 300)
    ..clear(img.ColorRgb8(40, 20, 25));
  img.fillRect(
    im,
    x1: 40,
    y1: 60,
    x2: 360,
    y2: 100,
    color: img.ColorRgb8(200, 110, 120),
  ); // 잇몸
  img.fillRect(
    im,
    x1: 50,
    y1: 100,
    x2: 350,
    y2: edge,
    color: img.ColorRgb8(r, g, b),
  ); // 치아
  // 치아 사이 틈(세로선) 몇 개
  for (final x in [100, 150, 200, 250, 300]) {
    img.fillRect(
      im,
      x1: x,
      y1: 100,
      x2: x + 1,
      y2: edge - 10,
      color: img.ColorRgb8(180, 170, 155),
    );
  }
  return im;
}

final cervical = GuideLine(
  upper: true,
  pts: [const Offset(60 / 400, 100 / 300), const Offset(340 / 400, 100 / 300)],
);

void main() {
  test('절단라인 자동 감지: 원본 치아 끝선(y=200)을 찾음', () {
    final l = detectIncisal(mouth(), cervical)!;
    expect(l.incisal, isTrue);
    expect(l.upper, isTrue);
    for (final p in l.pts) {
      expect(p.dy * 300, closeTo(200, 4));
    }
  });

  test('결과에서 절단끝이 짧아지면(170) 원본 길이(200)로 복원, 색은 결과(라미네이트)색으로', () {
    final orig = mouth();
    final inc = detectIncisal(orig, cervical)!;
    final res = mouth(edge: 170, r: 250, g: 248, b: 240); // 더 하얗고 짧아짐
    final f = restoreIncisal(orig, res, [cervical, inc]);
    expect(f.shortCols, greaterThan(0.8));
    expect(f.maxShort, closeTo(0.3, 0.06));
    final p = f.image.getPixel(200 - 25, 190); // 예전엔 입안(어두움) → 이제 치아
    expect(p.r, greaterThan(220));
    expect(p.b, greaterThan(225)); // 결과 색(하얀 라미네이트)에 맞춤
    // 다시 감지하면 원래 길이
    final again = detectIncisal(f.image, cervical)!;
    for (final q in again.pts) {
      expect(q.dy * 300, closeTo(200, 5));
    }
  });

  test('길어진 결과는 건드리지 않음 (길어지는 건 괜찮음)', () {
    final orig = mouth();
    final inc = detectIncisal(orig, cervical)!;
    final res = mouth(edge: 215);
    final f = restoreIncisal(orig, res, [cervical, inc]);
    expect(f.shortCols, 0);
  });

  test('검사 답 읽기 + 통과 기준', () {
    final v = NoPrepVerdict.parse(
      '```json\n{"incisal_shorter": true, "shorter_teeth": ["#11"], "margin_change": 2, "fix": "#11 절단끝 유지"}\n```',
    );
    expect(v.ok, isFalse);
    expect(v.label, '절단 짧아짐 의심 (#11) · 마진라인 변화 있음');
    expect(
      NoPrepVerdict.parse('{"incisal_shorter": false, "margin_change": 1}').ok,
      isTrue,
    );
    expect(
      buildNoPrepCheckPrompt(teeth: const [11, 21], measuredShort: 0.2),
      contains('짧아지면 안 됩니다'),
    );
  });

  test('반복: 1회차 미달 → 고친 지시로 2회차 → 통과하면 멈춤', () async {
    final orig = img.encodeJpg(mouth());
    final inc = detectIncisal(mouth(), cervical)!;
    final fixes = <String>[];
    final steps = <String>[];
    var n = 0;
    final out = await runNoPrepGuard(
      original: orig,
      lines: [cervical, inc],
      generate: (fix) async {
        fixes.add(fix);
        return img.encodeJpg(mouth(edge: 175));
      },
      check: (o, r, m) async => ++n == 1
          ? const NoPrepVerdict(
              incisalShorter: true,
              marginChange: 0,
              fix: '#11 길이 유지',
            )
          : const NoPrepVerdict(incisalShorter: false, marginChange: 0),
      onStep: steps.add,
      decode: (b) async => img.decodeJpg(b)!,
    );
    expect(out.tries, 2);
    expect(out.verdict!.ok, isTrue);
    expect(fixes.first, '');
    expect(fixes[1], contains('#11 길이 유지'));
    expect(fixes[1], contains('절대 짧아지면 안 됨'));
    expect(steps.any((s) => s.contains('다시 변환 (1/2)')), isTrue);
    // 결과는 픽셀 복원된 것 (짧았던 175 → 200 근처)
    final again = detectIncisal(img.decodeJpg(out.bytes)!, cervical)!;
    expect(
      again.pts.map((p) => p.dy * 300).reduce((a, b) => a + b) /
          again.pts.length,
      closeTo(200, 6),
    );
  });

  test('계속 미달이면 최대 2회 재변환 후 가장 나은 결과 + AI 검사 실패해도 결과는 줌', () async {
    var gens = 0;
    final out = await runNoPrepGuard(
      original: Uint8List.fromList(img.encodeJpg(mouth())),
      lines: const [],
      generate: (fix) async {
        gens++;
        return img.encodeJpg(mouth());
      },
      check: (o, r, m) async =>
          NoPrepVerdict(incisalShorter: false, marginChange: gens == 2 ? 2 : 3),
      onStep: (_) {},
      decode: (b) async => img.decodeJpg(b)!,
    );
    expect(gens, 3);
    expect(out.verdict!.marginChange, 2);
    final failed = await runNoPrepGuard(
      original: Uint8List.fromList(img.encodeJpg(mouth())),
      lines: const [],
      generate: (fix) async => img.encodeJpg(mouth()),
      check: (o, r, m) async => throw Exception('모델 없음'),
      onStep: (_) {},
      decode: (b) async => img.decodeJpg(b)!,
    );
    expect(failed.verdict, isNull);
    expect(failed.note, contains('AI 검사를 하지 못했습니다'));
  });
}
