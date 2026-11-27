import 'dart:math' as math;
import 'dart:ui' show Offset;

// -----------------------------------------------------------------------------
// 📸 촬영 가이드 · 실시간 자동 확인 계산 (화면·카메라와 무관한 순수 계산 → 테스트 가능)
//   얼굴 인식(ML Kit) 결과를 0~1 좌표(세로로 바로 선 화면 기준)로 받아
//   먼저 찍은 사진(기준)과 비교해 수평·정면·고개 숙임·거리·위치를 판정.
//   기준 사진이 없으면 화면 가이드(정중선·눈동자선·타원)와 비교.
// -----------------------------------------------------------------------------

/// 화면 가이드 위치 (0~1, 세로 사진 기준). 그림(GuidePainter)과 판정이 같은 값을 씀
class GuideGeom {
  static const midX = 0.5; // 수직 중앙선
  static const eyeY = 0.40; // 눈동자 수평선
  static const occY = 0.66; // 교합평면(입꼬리) 수평선 — 원본 1(미소)에서만
  static const ovalCx = 0.5, ovalCy = 0.50; // 얼굴 타원 중심
  static const ovalRx = 0.30, ovalRy = 0.30; // 반지름 (가로는 화면 폭, 세로는 화면 높이 비율)
  static const eyeDist = 0.24; // 타원에 맞게 섰을 때 두 눈동자 사이 (화면 폭 비율)
}

/// 얼굴 하나의 위치·각도
class FacePose {
  const FacePose({
    required this.eyeA,
    required this.eyeB,
    this.nose,
    this.yaw,
    this.pitch,
  });

  /// 두 눈 (화면에서 왼쪽 눈이 [eyeA]) — 0~1
  final Offset eyeA, eyeB;
  final Offset? nose;

  /// 고개 좌우 돌림·위아래 끄덕임 (도, ML Kit headEulerAngleY / X) — 없으면 비교 안 함
  final double? yaw, pitch;

  factory FacePose.fromEyes(
    Offset e1,
    Offset e2, {
    Offset? nose,
    double? yaw,
    double? pitch,
  }) => e1.dx <= e2.dx
      ? FacePose(eyeA: e1, eyeB: e2, nose: nose, yaw: yaw, pitch: pitch)
      : FacePose(eyeA: e2, eyeB: e1, nose: nose, yaw: yaw, pitch: pitch);

  /// 좌우 뒤집기 (셀카 화면은 거울처럼 보이므로 화면 기준으로 맞춤)
  FacePose mirrored() => FacePose.fromEyes(
    Offset(1 - eyeA.dx, eyeA.dy),
    Offset(1 - eyeB.dx, eyeB.dy),
    nose: nose == null ? null : Offset(1 - nose!.dx, nose!.dy),
    yaw: yaw == null ? null : -yaw!,
    pitch: pitch,
  );

  Offset get eyeMid => (eyeA + eyeB) / 2;
  double get eyeDist => (eyeB - eyeA).distance;

  /// 눈동자선 기울기 (도). + 면 화면 오른쪽 눈이 더 낮음
  double get roll =>
      math.atan2(eyeB.dy - eyeA.dy, eyeB.dx - eyeA.dx) * 180 / math.pi;
}

class AlignItem {
  const AlignItem(this.label, this.ok, this.hint);
  final String label; // 수평 · 정면 · 고개 · 거리 · 위치
  final bool ok;
  final String hint; // 안 맞을 때 안내 (맞으면 '')
}

class AlignResult {
  const AlignResult(this.items, {this.face = true});
  const AlignResult.noFace() : items = const [], face = false;
  final List<AlignItem> items;
  final bool face;
  bool get allOk => face && items.every((i) => i.ok);

  /// 가장 먼저 고칠 것 한 줄
  String get message {
    if (!face) return '얼굴을 화면 가운데에 맞춰 주세요';
    final bad = items.where((i) => !i.ok).toList();
    return bad.isEmpty ? '좋아요! 지금 찍으세요' : bad.first.hint;
  }
}

/// 판정 기준 (기준 사진과의 차이)
class AlignTol {
  static const roll = 2.5; // 도
  static const yaw = 6.0; // 도
  static const pitch = 6.0; // 도
  static const scale = 0.06; // 눈 사이 거리 ±6%
  static const pos = 0.035; // 눈 가운데 위치 (화면 비율)
}

/// [live]: 지금 카메라 얼굴, [ref]: 먼저 찍은 사진 얼굴 (없으면 화면 가이드 기준).
/// 둘 다 '화면에 보이는 대로'의 좌표. [selfie]: 셀카(앞 카메라) — 거울 화면이라 좌우로 옮길 방향이 반대
AlignResult checkAlign(FacePose? live, FacePose? ref, {bool selfie = false}) {
  if (live == null) return const AlignResult.noFace();
  final items = <AlignItem>[];

  // ① 수평 (고개 갸우뚱)
  final dRoll = live.roll - (ref?.roll ?? 0);
  items.add(
    AlignItem(
      '수평',
      dRoll.abs() <= (ref == null ? 3.0 : AlignTol.roll),
      dRoll > 0
          ? '고개가 기울었어요 (화면 오른쪽이 낮음) · 고개를 바로 세워 주세요'
          : '고개가 기울었어요 (화면 왼쪽이 낮음) · 고개를 바로 세워 주세요',
    ),
  );

  // ② 정면 (좌우로 돌림)
  final ly = live.yaw, ry = ref?.yaw;
  if (ly != null) {
    final d = ly - (ry ?? 0);
    items.add(
      AlignItem(
        '정면',
        d.abs() <= AlignTol.yaw,
        '얼굴이 옆으로 돌아갔어요 · 카메라를 정면으로 보게 해 주세요',
      ),
    );
  }

  // ③ 고개 숙임·듦 (기준 사진이 있을 때만: 사진마다 원래 각도가 다름)
  final lp = live.pitch, rp = ref?.pitch;
  if (lp != null && rp != null) {
    final d = lp - rp;
    items.add(
      AlignItem(
        '고개',
        d.abs() <= AlignTol.pitch,
        d > 0 ? '턱이 들렸어요 · 턱을 조금 내려 주세요' : '고개를 숙였어요 · 턱을 조금 들어 주세요',
      ),
    );
  }

  // ④ 거리 (눈 사이 거리 = 얼굴 크기)
  final want = ref?.eyeDist ?? GuideGeom.eyeDist;
  final k = live.eyeDist / math.max(1e-6, want);
  final tolK = ref == null ? 0.12 : AlignTol.scale;
  items.add(
    AlignItem(
      '거리',
      (k - 1).abs() <= tolK,
      k > 1 ? '너무 가까워요 · 조금 뒤로 물러나 주세요' : '너무 멀어요 · 조금 더 가까이 와 주세요',
    ),
  );

  // ⑤ 위치 (눈 가운데)
  final wantMid = ref?.eyeMid ?? const Offset(GuideGeom.midX, GuideGeom.eyeY);
  final d = live.eyeMid - wantMid;
  final tolP = ref == null ? 0.05 : AlignTol.pos;
  final ok = d.dx.abs() <= tolP && d.dy.abs() <= tolP;
  String hint;
  if (d.dx.abs() >= d.dy.abs()) {
    final right = d.dx > 0;
    // 후면: 카메라를 얼굴 쪽으로 / 셀카(거울 화면): 휴대폰을 반대쪽으로
    final move = (right != selfie) ? '오른쪽' : '왼쪽';
    hint =
        '얼굴이 화면 ${right ? '오른쪽' : '왼쪽'}에 있어요 · '
        '${selfie ? '휴대폰을' : '카메라를'} $move으로 조금 옮겨 주세요';
  } else {
    hint = d.dy > 0
        ? '얼굴이 화면 아래쪽에 있어요 · 카메라를 조금 내려 주세요'
        : '얼굴이 화면 위쪽에 있어요 · 카메라를 조금 올려 주세요';
  }
  items.add(AlignItem('위치', ok, hint));
  return AlignResult(items);
}
