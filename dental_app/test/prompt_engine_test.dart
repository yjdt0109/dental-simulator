import 'package:dental_app/ai/prompt_engine.dart';
import 'package:dental_app/simulator/sim_models.dart';
import 'package:flutter_test/flutter_test.dart';

String build(
  Set<String> tx,
  List<int> teeth, {
  String? shade = 'A1',
  bool guide = false,
  String req = '',
}) => ClinicalPrompt.build(
  treatments: tx,
  teeth: teeth,
  shade: shade,
  strength: 90,
  hasGuide: guide,
  request: req,
);

const upper6 = [13, 12, 11, 21, 22, 23];
const lower6 = [43, 42, 41, 31, 32, 33];

void main() {
  test('1) 치아를 안 골라도 치료 항목만으로 임상 지시가 들어감 (전체 개념)', () {
    for (final t in ClinicalPrompt.clinical.keys) {
      final p = build({t}, const []);
      expect(p, contains(ClinicalPrompt.clinical[t]!), reason: t);
      expect(p, contains('치아 번호 미지정'), reason: t);
    }
    final p = build({'라미네이트'}, const [11, 21]);
    expect(p, contains('적용 치아(FDI): 11, 21'));
    expect(p, contains('선택하지 않은 치아는 원본 그대로'));
  });

  test('2) 라미네이트·크라운 + 서비컬 라인 → 마진 절대 고정 (최우선), 잇몸 성형이면 예외', () {
    for (final t in ['라미네이트', '올세라믹 크라운']) {
      final p = build({t}, upper6, guide: true);
      expect(p, contains(ClinicalPrompt.marginRule), reason: t);
      expect(
        p.indexOf(ClinicalPrompt.marginRule),
        lessThan(p.indexOf('\n[치료 항목별 임상 지시]')),
      );
    }
    expect(
      build({'라미네이트'}, upper6),
      isNot(contains('절대 마진 한계선')),
    ); // 선을 안 그리면 없음
    expect(
      build({'교정'}, upper6, guide: true),
      isNot(contains('절대 마진 한계선')),
    ); // 보철이 아니면 없음
    final g = build({'라미네이트', '잇몸 성형'}, upper6, guide: true);
    expect(g, contains(ClinicalPrompt.marginRuleWithGum));
    expect(g, isNot(contains('단 1%도 변형하지 말고 원본 그대로 보존')));
    expect(g, isNot(contains(ClinicalPrompt.keepGum)));
    expect(
      build({'라미네이트'}, upper6),
      contains(ClinicalPrompt.keepGum),
    ); // 잇몸 성형 아니면 잇몸 유지
  });

  test('3) 교정: 상악만 골라도 하악 금지 문구 없음 + 형태 100% 유지 최우선', () {
    final p = build({'교정'}, upper6);
    expect(p, contains(ClinicalPrompt.orthoRule));
    expect(p, isNot(contains(ClinicalPrompt.keepLower)));
    expect(p, isNot(contains('하악 치아는 절대 바꾸지 말 것')));
    expect(p, contains('정렬에 필요한 범위에서 선택하지 않은 치아의 위치 이동도 허용'));
    // 교정 + 라미네이트여도 악궁 제한은 붙지 않음
    expect(
      build({'교정', '라미네이트'}, upper6),
      isNot(contains(ClinicalPrompt.keepLower)),
    );
  });

  test('4) 미백: 치아 선택과 관계없이 형태 고정·색만 개선', () {
    for (final teeth in [const <int>[], upper6]) {
      expect(
        build({'미백'}, teeth, shade: 'B1'),
        contains(ClinicalPrompt.whiteningRule('B1')),
      );
      expect(
        build({'미백'}, teeth, shade: null),
        contains(ClinicalPrompt.whiteningRule(null)),
      );
    }
    expect(ClinicalPrompt.whiteningRule(null), contains('자연스러운 밝은 톤으로 개선'));
    expect(ClinicalPrompt.whiteningRule('A1'), contains('셰이드(VITA A1)로 개선'));
    // 라미네이트와 함께면: 형태 고정은 라미네이트 대상이 아닌 치아에만 (모순 방지)
    final both = build({'라미네이트', '미백'}, upper6);
    expect(both, contains('(라미네이트 대상이 아닌 나머지 치아에 대해) 치아의 크기'));
    expect(build({'미백'}, upper6), isNot(contains('대상이 아닌 나머지 치아')));
  });

  test('5) 보철·잇몸 성형 악궁 제한 (상악만 → 하악 유지, 하악만 → 상악 유지)', () {
    for (final t in ['라미네이트', '올세라믹 크라운', '임플란트', '잇몸 성형']) {
      expect(build({t}, upper6), contains(ClinicalPrompt.keepLower), reason: t);
      expect(
        build({t}, upper6),
        isNot(contains(ClinicalPrompt.keepUpper)),
        reason: t,
      );
      expect(build({t}, lower6), contains(ClinicalPrompt.keepUpper), reason: t);
      expect(
        build({t}, [...upper6, ...lower6]),
        isNot(contains(ClinicalPrompt.keepLower)),
        reason: t,
      );
      expect(
        build({t}, const []),
        isNot(contains(ClinicalPrompt.keepLower)),
        reason: t,
      );
    }
    // 미백은 악궁 제한 대상이 아님
    expect(build({'미백'}, upper6), isNot(contains(ClinicalPrompt.keepLower)));
  });

  test('5) 셰이드 해제: 색 강제 적용 안 함', () {
    expect(build({'교정'}, upper6, shade: null), contains('치아 색상은 원본 그대로 유지'));
    expect(build({'교정'}, upper6, shade: null), isNot(contains('VITA')));
    expect(build({'잇몸 성형'}, upper6, shade: null), contains('치아 색상은 원본 그대로 유지'));
    expect(build({'라미네이트'}, upper6, shade: null), contains('인접 자연치의 색조와 조화'));
    expect(build({'교정'}, upper6, shade: 'A2'), contains('VITA A2'));
  });

  test('추가 요청·서비컬 참고 이미지·요약', () {
    final p = build({'라미네이트'}, upper6, guide: true, req: '11, 21 길이 1mm');
    expect(p, contains('[추가 요청]'));
    expect(p, contains('11, 21 길이 1mm'));
    expect(p, contains('초록 = 상악, 분홍 = 하악'));
    expect(build({}, const []), contains('선택된 치료 항목 없음'));
    final s = ClinicalPrompt.summary(
      treatments: {'교정'},
      teeth: upper6,
      shade: null,
      hasGuide: false,
    );
    expect(s.join('\n'), contains('교정 임상 지시'));
    expect(s.join('\n'), contains('최우선: 교정'));
    expect(s.join('\n'), contains('셰이드 미선택'));
    expect(s.join('\n'), isNot(contains('하악 치아·하악 잇몸 원본 유지')));
  });

  test('서비컬 라인을 그리면 잇몸 마스크 잠금 문장이 맨 앞에 (잇몸 성형이면 빠짐)', () {
    String b(Set<String> tx, {bool up = true, bool lo = false}) =>
        ClinicalPrompt.build(
          treatments: tx,
          teeth: const [],
          shade: 'A1',
          strength: 90,
          hasGuide: true,
          guideUpper: up,
          guideLower: lo,
        );
    final p = b({'라미네이트'});
    expect(p, contains(ClinicalPrompt.gumLockUpper));
    expect(p, isNot(contains(ClinicalPrompt.gumLockLower)));
    // 최우선 규칙의 첫 줄
    final first = p.split('\n[최우선 규칙]\n')[1].split('\n').first;
    expect(first, '- ${ClinicalPrompt.gumLockUpper}');
    expect(
      b({'교정'}, up: true, lo: true),
      contains(ClinicalPrompt.gumLockLower),
    );
    expect(b({}, up: true), contains(ClinicalPrompt.gumLockUpper)); // 치료 항목 없어도
    expect(b({'잇몸 성형'}, up: true, lo: true), isNot(contains('마스크(Mask)')));
    expect(
      ClinicalPrompt.build(
        treatments: {'라미네이트'},
        teeth: const [],
        shade: 'A1',
        strength: 90,
        hasGuide: false,
      ),
      isNot(contains('마스크(Mask)')),
    );
  });

  group('무삭제 라미네이트', () {
    const lam = '라미네이트', np = '무삭제 라미네이트';
    test('전용 지시만 들어가고 기존 라미네이트(정돈·깎기) 문장은 없음', () {
      final p = build({np}, const [11, 21]);
      expect(p, contains(ClinicalPrompt.clinical[np]!));
      expect(p, contains('Additive-Only'));
      expect(p, contains('0.2mm 더 도톰하게'));
      expect(p, isNot(contains(ClinicalPrompt.clinical[lam]!)));
      expect(p, isNot(contains('크기·길이·폭 비율을 좌우 대칭으로 반듯하게 정돈')));
      expect(p, contains('- $np: '));
    });
    test('둘 다 들어오면 무삭제만 사용 (서로 모순되지 않게)', () {
      final p = build({lam, np}, const [11, 21]);
      expect(p, contains(ClinicalPrompt.clinical[np]!));
      expect(p, isNot(contains(ClinicalPrompt.clinical[lam]!)));
    });
    test('서비컬 마진 고정·잇몸 마스크 잠금: 라미네이트와 같음', () {
      final p = ClinicalPrompt.build(
        treatments: {np},
        teeth: upper6,
        shade: 'A1',
        strength: 90,
        hasGuide: true,
        guideUpper: true,
      );
      expect(p, contains(ClinicalPrompt.marginRule));
      expect(p, contains(ClinicalPrompt.gumLockUpper));
    });
    test('상·하악 제한: 라미네이트와 같음', () {
      expect(build({np}, upper6), contains(ClinicalPrompt.keepLower));
      expect(build({np}, lower6), contains(ClinicalPrompt.keepUpper));
      expect(
        build({np, '교정'}, upper6),
        isNot(contains(ClinicalPrompt.keepLower)),
      ); // 교정 예외 유지
    });
    test('셰이드 미선택이면 보철물 색은 인접 치아와 조화 / 미백과 함께면 무삭제 대상 외 치아만 형태 고정', () {
      expect(build({np}, upper6, shade: null), contains('인접 자연치의 색조와 조화'));
      expect(
        build({np, '미백'}, upper6),
        contains('(무삭제 라미네이트 대상이 아닌 나머지 치아에 대해)'),
      );
    });
    test('버튼: 둘 중 하나만 선택됨', () {
      final tx = <String>{};
      toggleTreatment(tx, lam);
      toggleTreatment(tx, np);
      expect(tx, {np});
      toggleTreatment(tx, lam);
      expect(tx, {lam});
      toggleTreatment(tx, '미백');
      toggleTreatment(tx, np);
      expect(tx, {'미백', np});
      toggleTreatment(tx, np);
      expect(tx, {'미백'});
    });
  });
}
