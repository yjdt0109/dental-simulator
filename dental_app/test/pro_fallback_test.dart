import 'dart:typed_data';

import 'package:dental_app/ai/pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    TwoPassPipeline.debugGemini = null;
    TwoPassPipeline.debugFalPro = null;
    TwoPassPipeline.proViaFal = false;
    TwoPassPipeline.proActive = null;
  });

  test('옵션 B: Pro 모델이 없으면 다른 이름 → 다 없으면 fal.ai 나노바나나 Pro, 다음부터는 바로 fal', () async {
    final tried = <String>[];
    var fal = 0;
    TwoPassPipeline.debugGemini = (m, p, j, r) async {
      tried.add(m);
      throw Exception(
        'Publisher model `projects/x/models/$m` was not found or your project does not have access to it.',
      );
    };
    TwoPassPipeline.debugFalPro = (jpegs, p) async {
      fal++;
      if (fal == 1) {
        expect(jpegs.length, 2); // 사진 + 참고 사진
        expect(p, contains('reference only'));
      }
      return Uint8List.fromList([9]);
    };
    final s = PipelineSettings.instance;
    final pipe = TwoPassPipeline();
    final out = await pipe.proFinish(s, Uint8List.fromList([1]), '지시', [
      (label: 'ref', jpeg: Uint8List.fromList([2])),
    ]);
    expect(out, [9]);
    expect(tried, contains('gemini-3-pro-image'));
    expect(tried.toSet().length, tried.length); // 같은 이름 두 번 안 시도
    expect(TwoPassPipeline.proViaFal, isTrue);
    tried.clear();
    await pipe.proFinish(s, Uint8List.fromList([1]), '지시', const []);
    expect(tried, isEmpty); // 바로 fal
    expect(fal, 2);
  });

  test('옵션 B: 두 번째 이름이 되면 그 이름을 기억', () async {
    TwoPassPipeline.debugGemini = (m, p, j, r) async {
      if (m != 'gemini-3-pro-image') throw Exception('NOT_FOUND');
      return Uint8List.fromList([7]);
    };
    final out = await TwoPassPipeline().proFinish(
      PipelineSettings.instance,
      Uint8List(1),
      'x',
      const [],
    );
    expect(out, [7]);
    expect(TwoPassPipeline.proActive, 'gemini-3-pro-image');
    expect(TwoPassPipeline.proViaFal, isFalse);
  });

  test('옵션 B: 모델 문제가 아닌 오류는 그대로 알림', () async {
    TwoPassPipeline.debugGemini = (m, p, j, r) async =>
        throw Exception('요청이 많습니다');
    expect(
      () => TwoPassPipeline().proFinish(
        PipelineSettings.instance,
        Uint8List(1),
        'x',
        const [],
      ),
      throwsA(isA<Exception>()),
    );
  });
}
