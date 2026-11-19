import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'sim_models.dart';

/// 위아래 치열 모양의 클릭형 덴탈 차트 (FDI 치식).
/// 치아를 누르면 선택/해제되고 [onToggle] 로 알려줍니다.
class DentalChart extends StatelessWidget {
  const DentalChart({
    super.key,
    required this.selected,
    required this.onToggle,
    this.enabled = true,
  });

  final Set<int> selected;
  final ValueChanged<int> onToggle;
  final bool enabled;

  static const double _vw = 320, _vh = 336;
  static final List<_ToothPos> _layout = _buildLayout();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340),
      child: AspectRatio(
        aspectRatio: _vw / _vh,
        child: FittedBox(
          child: SizedBox(
            width: _vw,
            height: _vh,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 110,
                  child: _ArchLabel('상악 (윗니)'),
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 218,
                  child: _ArchLabel('하악 (아랫니)'),
                ),
                const Positioned(
                  left: 0,
                  top: 164,
                  child: _SideLabel('환자 오른쪽'),
                ),
                const Positioned(
                  right: 0,
                  top: 164,
                  child: _SideLabel('환자 왼쪽'),
                ),
                for (final t in _layout) ..._tooth(t),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _tooth(_ToothPos t) {
    final on = selected.contains(t.number);
    return [
      Positioned(
        left: t.center.dx - t.size.width / 2 - 4,
        top: t.center.dy - t.size.height / 2 - 4,
        width: t.size.width + 8,
        height: t.size.height + 8,
        child: Semantics(
          button: true,
          selected: on,
          label: '${t.number}번 치아',
          child: Transform.rotate(
            angle: t.angle,
            child: MouseRegion(
              cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enabled ? () => onToggle(t.number) : null,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: t.size.width,
                    height: t.size.height,
                    decoration: BoxDecoration(
                      color: on ? AppColors.blue : Colors.white,
                      borderRadius: BorderRadius.circular(
                        math.min(t.size.width, t.size.height) * 0.42,
                      ),
                      border: Border.all(
                        color: on
                            ? AppColors.blueDeep
                            : const Color(0xFFAFBCCD),
                        width: 1.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      Positioned(
        left: t.label.dx - 12,
        top: t.label.dy - 7,
        width: 24,
        height: 14,
        child: IgnorePointer(
          child: Text(
            '${t.number}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9,
              height: 1.4,
              color: on ? AppColors.blueDeep : AppColors.gray500,
              fontWeight: on ? FontWeight.w800 : FontWeight.w400,
            ),
          ),
        ),
      ),
    ];
  }

  // 치아 폭(상대값)과 두께(px): 앞니는 좁고 어금니는 넓게
  static const _tw = {
    1: 8.6,
    2: 6.6,
    3: 7.6,
    4: 7.0,
    5: 6.8,
    6: 10.2,
    7: 9.4,
    8: 8.8,
  };
  static const _th = {
    1: 15.0,
    2: 14.0,
    3: 17.0,
    4: 18.0,
    5: 18.0,
    6: 24.0,
    7: 23.0,
    8: 21.0,
  };

  static List<_ToothPos> _buildLayout() {
    const cx = 160.0,
        rx = 124.0,
        ry = 108.0,
        cyU = 150.0,
        cyL = 186.0,
        s = 2.55,
        gap = 0.7;
    // 타원 호를 실제 길이 기준으로 고르게 나누기 위한 누적 길이 표
    const n = 600;
    final cum = <double>[0];
    for (var i = 1; i <= n; i++) {
      final a0 = math.pi * (1 - (i - 1) / n), a1 = math.pi * (1 - i / n);
      cum.add(
        cum[i - 1] +
            math.sqrt(
              math.pow(rx * (math.cos(a1) - math.cos(a0)), 2) +
                  math.pow(ry * (math.sin(a1) - math.sin(a0)), 2),
            ),
      );
    }
    final arcLen = cum[n];
    double thetaAt(double len) {
      var lo = 0, hi = n;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (cum[mid] < len) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      return math.pi * (1 - lo / n);
    }

    final out = <_ToothPos>[];
    for (final upper in [true, false]) {
      final list = upper ? kUpperArch : kLowerArch;
      final units =
          list.fold<double>(0, (a, t) => a + _tw[t % 10]!) +
          gap * (list.length - 1);
      final scale = arcLen / units;
      var acc = 0.0;
      for (final t in list) {
        final w = _tw[t % 10]!;
        final th = thetaAt((acc + w / 2) * scale);
        acc += w + gap;
        final x = cx + rx * math.cos(th);
        final y = upper ? cyU - ry * math.sin(th) : cyL + ry * math.sin(th);
        var nx = math.cos(th) / rx,
            ny = (upper ? -math.sin(th) : math.sin(th)) / ry;
        final nl = math.sqrt(nx * nx + ny * ny);
        nx /= nl;
        ny /= nl;
        final h = _th[t % 10]!;
        out.add(
          _ToothPos(
            number: t,
            center: Offset(x, y),
            size: Size(w * s * 0.92, h),
            angle: math.atan2(ny, nx) + math.pi / 2,
            label: Offset(x + nx * (h / 2 + 9), y + ny * (h / 2 + 9)),
          ),
        );
      }
    }
    return out;
  }
}

class _ToothPos {
  const _ToothPos({
    required this.number,
    required this.center,
    required this.size,
    required this.angle,
    required this.label,
  });
  final int number;
  final Offset center;
  final Size size;
  final double angle;
  final Offset label;
}

class _ArchLabel extends StatelessWidget {
  const _ArchLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: const TextStyle(
      fontSize: 11,
      color: AppColors.gray500,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _SideLabel extends StatelessWidget {
  const _SideLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(fontSize: 10, color: Color(0xFF9AA8BA)),
  );
}

/// 셰이드 칩 4개 (실제 치아 색 견본 모양)
class ShadePicker extends StatelessWidget {
  const ShadePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final String? value; // null: 선택 안 함
  final ValueChanged<String?> onChanged; // 선택된 칩을 다시 누르면 null (해제)
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < kShades.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: _chip(kShades[i])),
        ],
      ],
    );
  }

  Widget _chip(Shade s) {
    final on = s.id == value;
    return Semantics(
      button: true,
      selected: on,
      label: '셰이드 ${s.id} ${s.desc}',
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? () => onChanged(on ? null : s.id) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: on ? AppColors.blue : AppColors.gray200,
              width: 2,
            ),
            boxShadow: on
                ? const [BoxShadow(color: AppColors.blueSoft, spreadRadius: 3)]
                : null,
          ),
          child: Column(
            children: [
              Container(
                width: 30,
                height: 40,
                decoration: BoxDecoration(
                  color: s.chip,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(12),
                    bottom: Radius.circular(18),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                s.id,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              Text(
                s.desc,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.gray500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
