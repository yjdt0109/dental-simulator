import '../simulator/sim_models.dart' show kTreatments, kShades;

/// 치과 임상·기공 기준 AI 프롬프트 자동 조합 엔진
///
/// 우선순위: [최우선 규칙] > [치료 항목별 임상 지시] > [색상·강도] > [추가 요청] > [공통 규칙]
/// - 치료 항목만 골라도 항목별 기본 임상 지시가 들어감 (치아 미선택 시 전체적인 치료 개념)
/// - 치아를 고르면 그 부위 위주로 적용
class ClinicalPrompt {
  ClinicalPrompt._();

  static const laminate = '라미네이트';
  static const noPrep = '무삭제 라미네이트';
  static const whitening = '미백';
  static const ortho = '교정';
  static const gum = '잇몸 성형';
  static const crown = '올세라믹 크라운';
  static const implant = '임플란트';

  /// 1) 치료 항목별 기본 임상 프롬프트 (7가지)
  static const clinical = {
    laminate:
        '환자 입술과 잇몸 라인은 그대로 유지하고, 선택된 치아의 크기·길이·폭 비율을 좌우 대칭으로 반듯하게 정돈하며, '
        '자연스러운 절단연 투명감과 매끄러운 세라믹 질감의 라미네이트로 변환',
    // 무삭제 라미네이트: 기존 라미네이트의 '정돈(깎기)' 대신 덧붙이기만 (완전히 별도)
    noPrep:
        '치아를 전혀 삭제하지 않고 기존 치아 외곽선 위에 세라믹을 덧붙이는(Additive-Only) 시술. '
        '원본 치아의 세로 길이, 가로 폭, 절단연 끝단 위치를 절대 줄이거나 안쪽으로 깎지 말 것. '
        '모든 선택 치아는 반드시 원본 치아 실루엣을 100% 덮으면서 같거나 0.2mm 더 도톰하게 확장될 것. '
        '순면이 전방으로 미세하게 볼륨감 있고 매끄럽게 표현되며, 서비컬 라인 위쪽 잇몸은 100% 원본 그대로 고정할 것',
    ortho:
        '각 치아 고유의 크기, 세로 길이, 끝단 모양, 자연 색상은 절대 바꾸거나 늘리지 말고 그대로 유지한 채, '
        '벌어진 틈을 닫고 비뚤어진 치아의 위치와 교합만 가지런하게 평행 이동·정렬',
    whitening:
        '치아의 크기, 배열 위치, 표면 굴곡과 잇몸 색상은 단 1%도 바꾸지 말고, 치아 내부의 누런 착색만 제거하여 '
        '자연스러운 에나멜 광택이 살아있는 밝은 톤으로 개선',
    gum:
        '치아 위치와 각도는 그대로 두고, 웃을 때 과도하게 보이거나 좌우 높낮이가 비대칭인 잇몸 경계선(치은 정점)만 '
        '대칭으로 매끄럽게 다듬어 치아 비율을 시원하게 개선',
    crown:
        '지대치의 마진 라인 경계에 오차 없이 딱 맞게 안착되며, 인접 치아와 빈틈없는 컨택(Contact) 및 조화로운 '
        '교합면 높이를 갖춘 자연 치아 질감의 지르코니아·올세라믹 크라운으로 수복',
    implant:
        '치아가 빠져 비어 있는 결손 부위 잇몸 위에, 주변 인접 치아의 크기·형태·색조와 완벽하게 조화를 이루는 '
        '자연스러운 임플란트 최종 보철 크라운을 식립하여 빈틈을 복원',
  };

  /// 2) 서비컬 라인 = 보철 마진 절대 고정 (라미네이트·올세라믹 크라운 + 선을 그렸을 때)
  static const marginRule =
      '사용자가 지정한 서비컬 라인(치경부 경계선)을 보철물의 절대 마진 한계선으로 고정할 것. '
      '보철물이 서비컬 라인을 벗어나 잇몸 쪽으로 넘치거나(Overhang) 짧아지지 않게 정확히 일치시키고, '
      '원래 환자의 치은(잇몸) 모양·높이·치간유두 형태는 단 1%도 변형하지 말고 원본 그대로 보존할 것.';

  /// 잇몸 성형을 함께 골랐을 때 (잇몸선 수정 예외)
  static const marginRuleWithGum =
      '사용자가 지정한 서비컬 라인(치경부 경계선)을 보철물의 절대 마진 한계선으로 고정할 것. '
      '보철물이 서비컬 라인을 벗어나 잇몸 쪽으로 넘치거나(Overhang) 짧아지지 않게 정확히 일치시킬 것. '
      '(잇몸 성형을 함께 선택했으므로, 잇몸 경계선은 잇몸 성형 지시에 따라서만 다듬을 수 있음)';

  /// 3) 교정 최우선 규칙
  static const orthoRule =
      '환자 원래 치아 하나하나의 크기, 세로 길이, 끝단 모양, 자연 색상은 절대 바꾸거나 늘리지 말고 100% 유지한 채, '
      '벌어진 틈을 닫고 비뚤어진 치아의 위치와 상하악 교합만 가지런하게 이동·정렬할 것.';

  /// 4) 미백 최우선 규칙
  static String whiteningRule(String? shade) =>
      '치아의 크기, 길이, 모양, 배열 위치, 잇몸 형태는 원본 그대로 100% 고정한 상태에서, 오직 치아 색상만 '
      '${shade == null ? '자연스러운 밝은 톤으로' : '선택한 셰이드(VITA $shade)로'} 개선할 것.';

  /// 미백을 형태를 바꾸는 치료(라미네이트·교정·크라운·임플란트)와 함께 골랐을 때:
  /// 형태 고정은 그 치료 대상이 아닌 나머지 치아에 적용 (서로 모순되지 않게)
  static const shapeChanging = {laminate, noPrep, ortho, crown, implant};
  static String whiteningScope(Iterable<String> others) =>
      '(${others.join('·')} 대상이 아닌 나머지 치아에 대해) ';

  /// 5) 보철·잇몸 성형 악궁 제한
  static const keepLower = '하악 치아와 하악 잇몸은 원본 그대로 유지하고 절대 바꾸지 말 것.';
  static const keepUpper = '상악 치아와 상악 잇몸은 원본 그대로 유지하고 절대 바꾸지 말 것.';
  static const archLimited = {laminate, noPrep, crown, implant, gum};

  /// 잇몸 성형을 고르지 않았을 때 (잇몸선 수정은 잇몸 성형에서만)
  /// 서비컬 라인을 그렸을 때: 잇몸 영역 마스크 잠금 (잇몸 성형을 고르면 잇몸을 다듬어야 하므로 빼요)
  static const gumLockUpper =
      '사용자가 그린 서비컬 라인 위쪽 잇몸 영역은 AI 이미지 생성 시 마스크(Mask)로 잠가서 픽셀이 절대 변하지 않도록 고정해 줘.';
  static const gumLockLower =
      '사용자가 그린 하악 서비컬 라인 아래쪽 잇몸 영역도 AI 이미지 생성 시 마스크(Mask)로 잠가서 픽셀이 절대 변하지 않도록 고정해 줘.';

  static const keepGum =
      '잇몸 경계선(치은 정점)·치간유두·잇몸 색은 원본 그대로 유지할 것 (잇몸 성형을 선택하지 않음).';

  static bool _isUpper(int t) => t ~/ 10 == 1 || t ~/ 10 == 2;
  static bool _isLower(int t) => t ~/ 10 == 3 || t ~/ 10 == 4;

  /// 선택 상태 → 적용되는 규칙 목록 (프롬프트와 화면 안내가 같은 계산을 씀)
  static _Plan _plan({
    required Iterable<String> treatments,
    required List<int> teeth,
    required bool hasGuide,
    bool guideUpper = false,
    bool guideLower = false,
  }) {
    final tx = [
      for (final t in kTreatments)
        if (treatments.contains(t)) t,
    ];
    // 라미네이트와 무삭제 라미네이트가 둘 다 들어오면(예전 기록 등) 무삭제만 사용
    if (tx.contains(noPrep)) tx.remove(laminate);
    final priority = <(String, String)>[]; // (화면 요약, 프롬프트 문장)
    final hasGum = tx.contains(gum);
    if (hasGuide &&
        (tx.contains(laminate) || tx.contains(noPrep) || tx.contains(crown))) {
      priority.add((
        '서비컬 라인 = 보철 마진 절대 고정${hasGum ? ' (잇몸 성형 예외)' : ' · 치은 형태 보존'}',
        hasGum ? marginRuleWithGum : marginRule,
      ));
    }
    if (tx.contains(ortho)) {
      priority.add(('교정: 치아 크기·길이·끝단·색 100% 유지, 위치·상하악 교합만 정렬', orthoRule));
    }
    // 잇몸 마스크 잠금은 맨 앞(가장 우선)
    if (hasGuide && !hasGum) {
      if (guideLower) {
        priority.insert(0, ('하악 서비컬 라인 아래 잇몸 = 마스크 잠금 (픽셀 고정)', gumLockLower));
      }
      if (guideUpper) {
        priority.insert(0, ('서비컬 라인 위쪽 잇몸 = 마스크 잠금 (픽셀 고정)', gumLockUpper));
      }
    }
    if (tx.contains(whitening)) {
      final others = tx.where(shapeChanging.contains);
      priority.add((
        '미백: ${others.isEmpty ? '' : '${others.join('·')} 외 치아는 '}크기·길이·모양·배열·잇몸 100% 고정, 색만 개선',
        '',
      ));
    }
    // 악궁 제한: 보철·잇몸 성형일 때만, 교정을 함께 고르면 붙이지 않음 (상하악 교합·정중선을 함께 맞춰야 함)
    if (!tx.contains(ortho) &&
        tx.any(archLimited.contains) &&
        teeth.isNotEmpty) {
      if (teeth.every(_isUpper)) priority.add(('하악 치아·하악 잇몸 원본 유지', keepLower));
      if (teeth.every(_isLower)) priority.add(('상악 치아·상악 잇몸 원본 유지', keepUpper));
    }
    if (!hasGum) priority.add(('잇몸선·치간유두 원본 유지 (잇몸 성형 미선택)', keepGum));
    return _Plan(tx, priority);
  }

  /// AI 에 보낼 전체 지시문
  static String build({
    required Iterable<String> treatments,
    required List<int> teeth,
    required String? shade,
    required int strength,
    required bool hasGuide,
    bool guideUpper = false,
    bool guideLower = false,
    String request = '',
  }) {
    final plan = _plan(
      guideUpper: guideUpper,
      guideLower: guideLower,
      treatments: treatments,
      teeth: teeth,
      hasGuide: hasGuide,
    );
    final tx = plan.tx;
    final scope = teeth.isEmpty
        ? '치아 번호 미지정 → 웃을 때 보이는 치아 전체에 치료 개념으로 적용'
        : '적용 치아(FDI): ${teeth.join(', ')} → 이 부위 위주로 적용';
    final degree = strength >= 85
        ? '뚜렷하게'
        : strength >= 60
        ? '보통으로'
        : '약하게';
    final s = shade == null
        ? null
        : kShades.where((x) => x.id == shade).firstOrNull;
    final prosthetic = tx.any(
      (t) => t == laminate || t == noPrep || t == crown || t == implant,
    );
    final colorLine = s != null
        ? '변경하는 치아(보철물)의 색은 VITA ${s.id}(${s.desc}) 셰이드에 맞출 것.'
        : tx.contains(whitening)
        ? '셰이드 미선택: 자연스러운 밝은 톤으로.'
        : prosthetic
        ? '셰이드 미선택: 보철물 색은 인접 자연치의 색조와 조화롭게 맞추고, 나머지 치아 색은 원본 유지.'
        : '셰이드 미선택: 치아 색상은 원본 그대로 유지할 것 (색을 바꾸지 말 것).';
    return [
      'You are editing a dental patient\'s smile photo to create a realistic AFTER-treatment simulation '
          'for a dental consultation. Follow the Korean clinical instructions below exactly. '
          'Priority order: [최우선 규칙] > [치료 항목별 임상 지시] > [색상·강도] > [추가 요청]. '
          'Teeth use FDI numbering; the patient\'s right side is on the image left.',
      if (plan.priority.isNotEmpty) ...[
        '',
        '[최우선 규칙]',
        for (final (_, line) in plan.priority)
          if (line.isNotEmpty) '- $line',
        if (tx.contains(whitening))
          '- ${tx.any(shapeChanging.contains) ? whiteningScope(tx.where(shapeChanging.contains)) : ''}${whiteningRule(s?.id)}',
      ],
      '',
      '[치료 항목별 임상 지시] ($scope)',
      if (tx.isEmpty) '- 선택된 치료 항목 없음: 아래 추가 요청을 따르고, 요청이 없으면 치아 형태를 크게 바꾸지 말고 자연스럽고 가지런한 미소로 가볍게 개선.',
      for (final t in tx) '- $t: ${clinical[t]}.',
      if (teeth.isNotEmpty && !tx.contains(ortho))
        '- 선택하지 않은 치아는 원본 그대로 최대한 유지.',
      if (teeth.isNotEmpty && tx.contains(ortho))
        '- 교정은 상하악 교합과 정중선을 함께 맞춰야 하므로, 정렬에 필요한 범위에서 선택하지 않은 치아의 위치 이동도 허용.',
      '',
      '[색상·강도]',
      '- $colorLine',
      '- 변화 정도: $degree (임상적으로 실제 가능한 범위에서).',
      if (hasGuide) ...[
        '',
        '[서비컬 라인 참고 이미지]',
        '- 두 번째 이미지는 같은 사진에 원장님이 서비컬 라인(치경부 경계선)을 그린 것: 초록 = 상악, 분홍 = 하악. '
            '이 선을 기준선으로 사용하고, 결과 사진에는 선을 절대 그리지 말 것.',
      ],
      if (request.trim().isNotEmpty) ...[
        '',
        '[추가 요청]',
        '"""${request.trim()}"""',
      ],
      '',
      'Common rules: keep the lips, skin, facial hair, face shape, lighting, camera angle, image size and framing '
          'exactly the same. Keep the same number of teeth${tx.contains(implant) ? ' (except restoring missing teeth with implant crowns)' : ''}. '
          'If there is a black privacy bar over the eyes, keep it exactly as it is. '
          'Photorealistic, natural enamel texture and translucency, no cartoon look, no text, no lines, no watermark.',
    ].join('\n');
  }

  /// 화면에 보여 줄 "자동 포함" 요약 (한 줄씩)
  static List<String> summary({
    required Iterable<String> treatments,
    required List<int> teeth,
    required String? shade,
    required bool hasGuide,
    bool guideUpper = false,
    bool guideLower = false,
  }) {
    final plan = _plan(
      treatments: treatments,
      teeth: teeth,
      hasGuide: hasGuide,
      guideUpper: guideUpper,
      guideLower: guideLower,
    );
    final where = teeth.isEmpty ? '전체' : teeth.join(', ');
    return [
      if (plan.tx.isEmpty) '치료 항목 미선택 → 추가 요청만 적용 (항목을 고르면 임상 지시가 자동으로 들어가요)',
      for (final t in plan.tx) '$t 임상 지시 ($where)',
      for (final (label, _) in plan.priority) '최우선: $label',
      shade == null
          ? '셰이드 미선택 → ${plan.tx.contains(whitening) ? '자연스러운 밝은 톤' : '색 강제 적용 안 함'}'
          : '셰이드 $shade',
      if (hasGuide) '그린 서비컬 라인을 기준선으로 전달',
    ];
  }

  /// 1단계(FLUX.1 Fill)용 지시: FLUX 는 영어를 가장 잘 이해해서 같은 뜻의 영어를 먼저,
  /// 그 뒤에 기존 치료별 임상 지시(한국어) 원문을 붙임. 마스크(치아 영역) 안만 새로 그림.
  static const fluxEnglish = {
    laminate: 'porcelain laminate veneers: keep the lips and gum line unchanged; make the selected teeth size, length and width proportions symmetric and neat, with natural incisal translucency and smooth ceramic texture',
    noPrep: 'no-prep additive-only veneers: never shorten, narrow or cut back any tooth; every selected tooth must fully cover its original silhouette and be equal or about 0.2 mm fuller, with a slightly fuller, smooth labial surface; gums above the cervical line unchanged',
    whitening: 'whitening only: do not change tooth size, position, surface contour or gum color; only remove yellow stains for a natural bright enamel shade',
    crown: 'all-ceramic / zirconia crowns seated exactly at the margin line, tight contacts with neighboring teeth, harmonious occlusal height, natural tooth texture',
    implant: 'implant crowns that fill missing-tooth gaps, matching the neighboring teeth in size, shape and shade',
  };

  static String fluxPrompt({
    required Iterable<String> treatments,
    required List<int> teeth,
    required String? shade,
    String extra = '', // 추가 요청 (자동 QA 가 고친 지시 등)
  }) {
    final tx = [
      for (final t in kTreatments)
        if (treatments.contains(t) && fluxEnglish.containsKey(t)) t,
    ];
    if (tx.contains(noPrep)) tx.remove(laminate);
    final s = shade == null
        ? null
        : kShades.where((x) => x.id == shade).firstOrNull;
    return [
      'Photorealistic intraoral dental photo. Redraw ONLY the masked tooth area; the mask edges are the cervical margin lines, '
          'so tooth crowns must start exactly at the mask edge and nothing outside the mask may change.',
      for (final t in tx) '- ${fluxEnglish[t]}.',
      if (teeth.isNotEmpty) '- Focus on teeth (FDI): ${teeth.join(', ')}.',
      s != null
          ? '- Tooth shade: VITA ${s.id}.'
          : '- Keep natural tooth color harmony.',
      'Same number of teeth, natural anatomy, no text.',
      '임상 지시(원문):',
      for (final t in tx) '- $t: ${clinical[t]}.',
      if (extra.trim().isNotEmpty) '추가 요청: ${extra.trim()}',
    ].join('\n');
  }
}

class _Plan {
  _Plan(this.tx, this.priority);
  final List<String> tx;
  final List<(String, String)> priority;
}
