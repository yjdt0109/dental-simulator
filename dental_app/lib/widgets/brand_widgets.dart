import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_theme.dart';

// -----------------------------------------------------------------------------
// 공통 레이아웃: 넓으면 [브랜드 패널 | 폼], 좁으면 [폼 카드] 가운데 정렬
// -----------------------------------------------------------------------------
class AuthShell extends StatelessWidget {
  const AuthShell({super.key, required this.child, this.onBack});

  final Widget child;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 960 && c.maxHeight >= 560;
          final form = _FormArea(onBack: onBack, child: child);
          if (!wide) return form;
          return Row(
            children: [
              Expanded(flex: 5, child: const BrandPanel()),
              Expanded(flex: 6, child: form),
            ],
          );
        },
      ),
    );
  }
}

class _FormArea extends StatelessWidget {
  const _FormArea({required this.child, this.onBack});
  final Widget child;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final phone = w < 600;
    return SafeArea(
      child: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: phone ? 16 : 32,
                vertical: 28,
              ),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Container(
                  padding: EdgeInsets.all(phone ? 22 : 36),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppColors.gray100),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.blueDeep.withValues(alpha: 0.07),
                        blurRadius: 40,
                        offset: const Offset(0, 16),
                      ),
                    ],
                  ),
                  child: child,
                ),
              ),
            ),
          ),
          if (onBack != null)
            Positioned(
              left: 8,
              top: 8,
              child: IconButton(
                tooltip: '뒤로',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
                color: AppColors.ink,
              ),
            ),
        ],
      ),
    );
  }
}

/// 넓은 화면 왼쪽의 브랜드 소개 패널
class BrandPanel extends StatelessWidget {
  const BrandPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B74DE), AppColors.blue, AppColors.blueDeep],
        ),
      ),
      child: Stack(
        children: [
          // 은은한 원형 장식
          Positioned(
            right: -120,
            top: -80,
            child: _Circle(size: 360, alpha: 0.07),
          ),
          Positioned(
            left: -90,
            bottom: -110,
            child: _Circle(size: 300, alpha: 0.06),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppLogo(size: 64, onBlue: true),
                    const SizedBox(height: 28),
                    const Text(
                      '환자와 함께 보는\n치료 전·후의 차이',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        height: 1.3,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '사진 두 장으로 상담을 시작하세요.\n슬라이더 한 번이면 설명이 끝납니다.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 15,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 36),
                    // 미니 비포/애프터 미리보기
                    const _MiniCompare(),
                    const SizedBox(height: 28),
                    const _Feature(
                      icon: Icons.compare_rounded,
                      text: 'Before / After 실시간 비교 슬라이더',
                    ),
                    const _Feature(
                      icon: Icons.auto_fix_high_rounded,
                      text: '미백·라미네이트·잇몸성형 시뮬레이션',
                    ),
                    const _Feature(
                      icon: Icons.verified_user_outlined,
                      text: '상담 메모와 동의 기록을 한 화면에',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Circle extends StatelessWidget {
  const _Circle({required this.size, required this.alpha});
  final double size;
  final double alpha;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white.withValues(alpha: alpha),
    ),
  );
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      ],
    ),
  );
}

/// 브랜드 패널 안의 작은 비교 슬라이더 그림 (장식용, 자동으로 좌우로 움직임)
class _MiniCompare extends StatefulWidget {
  const _MiniCompare();
  @override
  State<_MiniCompare> createState() => _MiniCompareState();
}

class _MiniCompareState extends State<_MiniCompare>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 2.2,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = 0.25 + Curves.easeInOut.transform(_c.value) * 0.5;
            return CustomPaint(painter: _MiniComparePainter(t));
          },
        ),
      ),
    );
  }
}

class _MiniComparePainter extends CustomPainter {
  _MiniComparePainter(this.t);
  final double t;

  void _teeth(Canvas canvas, Size s, Color tooth, bool even) {
    final lip = Paint()..color = const Color(0xFFB04F5B);
    final mouth = Paint()..color = const Color(0xFF4A1A24);
    canvas.drawColor(const Color(0xFFF0D9CB), BlendMode.src);
    final c = Offset(s.width / 2, s.height * 0.55);
    canvas.drawOval(
      Rect.fromCenter(center: c, width: s.width * 0.78, height: s.height * 0.7),
      lip,
    );
    canvas.drawOval(
      Rect.fromCenter(center: c, width: s.width * 0.66, height: s.height * 0.5),
      mouth,
    );
    final p = Paint()..color = tooth;
    const n = 8;
    final tw = s.width * 0.066;
    final total = tw * n + 4.0 * (n - 1);
    var x = c.dx - total / 2;
    for (var i = 0; i < n; i++) {
      final mid = (i == 3 || i == 4);
      final h = s.height * (mid ? 0.26 : 0.21);
      final dy = even ? 0.0 : [3.0, -2.0, 4.0, 0.0, 5.0, -3.0, 3.0, 1.0][i];
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, c.dy - s.height * 0.2 + dy, tw, h),
        const Radius.circular(6),
      );
      canvas.save();
      if (!even) {
        canvas.translate(x + tw / 2, c.dy);
        canvas.rotate([0.05, -0.06, 0.07, 0.0, 0.06, -0.08, 0.04, 0.0][i]);
        canvas.translate(-(x + tw / 2), -c.dy);
      }
      canvas.drawRRect(r, p);
      canvas.restore();
      x += tw + 4;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final split = size.width * t;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(split, 0, size.width - split, size.height));
    _teeth(canvas, size, const Color(0xFFFAF9F4), true); // After
    canvas.restore();
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, split, size.height));
    _teeth(canvas, size, const Color(0xFFDCC88F), false); // Before
    canvas.restore();
    // 분할선 + 손잡이
    canvas.drawLine(
      Offset(split, 0),
      Offset(split, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      Offset(split, size.height / 2),
      13,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      Offset(split, size.height / 2),
      13,
      Paint()
        ..color = AppColors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_MiniComparePainter old) => old.t != t;
}

// -----------------------------------------------------------------------------
// 앱 로고 (치아 + 비교선 모양을 직접 그림)
// -----------------------------------------------------------------------------
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 56, this.onBlue = false});
  final double size;
  final bool onBlue;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: onBlue
            ? null
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A85F0), AppColors.blue],
              ),
        color: onBlue ? Colors.white : null,
        boxShadow: onBlue
            ? null
            : [
                BoxShadow(
                  color: AppColors.blue.withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: CustomPaint(
        painter: _ToothLogoPainter(onBlue ? AppColors.blue : Colors.white),
      ),
    );
  }
}

class _ToothLogoPainter extends CustomPainter {
  _ToothLogoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    // 치아 외곽선
    final tooth = Path()
      ..moveTo(w * 0.32, h * 0.24)
      ..cubicTo(w * 0.18, h * 0.24, w * 0.17, h * 0.42, w * 0.22, h * 0.52)
      ..cubicTo(w * 0.27, h * 0.62, w * 0.28, h * 0.80, w * 0.36, h * 0.80)
      ..cubicTo(w * 0.43, h * 0.80, w * 0.42, h * 0.62, w * 0.50, h * 0.62)
      ..cubicTo(w * 0.58, h * 0.62, w * 0.57, h * 0.80, w * 0.64, h * 0.80)
      ..cubicTo(w * 0.72, h * 0.80, w * 0.73, h * 0.62, w * 0.78, h * 0.52)
      ..cubicTo(w * 0.83, h * 0.42, w * 0.82, h * 0.24, w * 0.68, h * 0.24)
      ..cubicTo(w * 0.60, h * 0.24, w * 0.56, h * 0.29, w * 0.50, h * 0.29)
      ..cubicTo(w * 0.44, h * 0.29, w * 0.40, h * 0.24, w * 0.32, h * 0.24)
      ..close();
    // 왼쪽 반은 채우고 오른쪽 반은 선만 → Before / After 느낌
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, w * 0.5, h));
    canvas.drawPath(tooth, Paint()..color = color.withValues(alpha: 0.45));
    canvas.restore();
    canvas.drawPath(
      tooth,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.055
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawLine(
      Offset(w * 0.5, h * 0.14),
      Offset(w * 0.5, h * 0.88),
      Paint()
        ..color = color
        ..strokeWidth = w * 0.04
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ToothLogoPainter old) => old.color != color;
}

// -----------------------------------------------------------------------------
// 소셜 로고 (공식 컬러를 반영해 직접 그림 — 이미지 파일 없이 동작)
// -----------------------------------------------------------------------------
enum SocialProvider { google, kakao, naver }

extension SocialInfo on SocialProvider {
  String get label => switch (this) {
    SocialProvider.google => '구글',
    SocialProvider.kakao => '카카오',
    SocialProvider.naver => '네이버',
  };
  Color get bg => switch (this) {
    SocialProvider.google => Colors.white,
    SocialProvider.kakao => AppColors.kakao,
    SocialProvider.naver => AppColors.naver,
  };
  Color get fg => switch (this) {
    SocialProvider.google => AppColors.ink,
    SocialProvider.kakao => AppColors.kakaoInk,
    SocialProvider.naver => Colors.white,
  };
}

class SocialLogo extends StatelessWidget {
  const SocialLogo(this.provider, {super.key, this.size = 22});
  final SocialProvider provider;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _SocialLogoPainter(provider)),
  );
}

class _SocialLogoPainter extends CustomPainter {
  _SocialLogoPainter(this.p);
  final SocialProvider p;

  @override
  void paint(Canvas canvas, Size s) {
    switch (p) {
      case SocialProvider.google:
        _google(canvas, s);
      case SocialProvider.kakao:
        _kakao(canvas, s);
      case SocialProvider.naver:
        _naver(canvas, s);
    }
  }

  void _google(Canvas canvas, Size s) {
    final stroke = s.width * 0.2;
    final rect = Rect.fromCircle(
      center: Offset(s.width / 2, s.height / 2),
      radius: s.width / 2 - stroke / 2,
    );
    Paint arc(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const deg = math.pi / 180;
    canvas.drawArc(
      rect,
      -40 * deg,
      -100 * deg,
      false,
      arc(const Color(0xFFEA4335)),
    );
    canvas.drawArc(
      rect,
      -140 * deg,
      -90 * deg,
      false,
      arc(const Color(0xFFFBBC05)),
    );
    canvas.drawArc(
      rect,
      130 * deg,
      -95 * deg,
      false,
      arc(const Color(0xFF34A853)),
    );
    canvas.drawArc(
      rect,
      35 * deg,
      -35 * deg,
      false,
      arc(const Color(0xFF4285F4)),
    );
    // 가로 막대
    canvas.drawRect(
      Rect.fromLTWH(
        s.width * 0.5,
        s.height * 0.5 - stroke / 2,
        s.width * 0.5 - stroke * 0.05,
        stroke,
      ),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  void _kakao(Canvas canvas, Size s) {
    final paint = Paint()..color = AppColors.kakaoInk;
    final body = Rect.fromLTWH(0, s.height * 0.08, s.width, s.height * 0.7);
    canvas.drawOval(body, paint);
    final tail = Path()
      ..moveTo(s.width * 0.25, s.height * 0.62)
      ..lineTo(s.width * 0.18, s.height * 0.95)
      ..lineTo(s.width * 0.45, s.height * 0.72)
      ..close();
    canvas.drawPath(tail, paint);
  }

  void _naver(Canvas canvas, Size s) {
    final paint = Paint()..color = Colors.white;
    final w = s.width, h = s.height;
    final n = Path()
      ..moveTo(w * 0.14, h * 0.14)
      ..lineTo(w * 0.40, h * 0.14)
      ..lineTo(w * 0.60, h * 0.47)
      ..lineTo(w * 0.60, h * 0.14)
      ..lineTo(w * 0.86, h * 0.14)
      ..lineTo(w * 0.86, h * 0.86)
      ..lineTo(w * 0.60, h * 0.86)
      ..lineTo(w * 0.40, h * 0.53)
      ..lineTo(w * 0.40, h * 0.86)
      ..lineTo(w * 0.14, h * 0.86)
      ..close();
    canvas.drawPath(n, paint);
  }

  @override
  bool shouldRepaint(_SocialLogoPainter old) => old.p != p;
}

class SocialButton extends StatelessWidget {
  const SocialButton({super.key, required this.provider, required this.onTap});
  final SocialProvider provider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${provider.label}로 계속하기',
      child: Material(
        color: provider.bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: provider == SocialProvider.google
                  ? Border.all(color: AppColors.gray200)
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SocialLogo(provider, size: 20),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    provider.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: provider.fg,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
