import 'package:flutter/material.dart';

// -----------------------------------------------------------------------------
// 색상 & 테마
// -----------------------------------------------------------------------------
class AppColors {
  AppColors._();
  static const blue = Color(0xFF0066CC); // 메인 메디컬 블루
  static const blueDeep = Color(0xFF004C99); // 진한 블루 (제목, 눌림)
  static const blueSoft = Color(0xFFE8F1FB); // 연한 블루 배경
  static const gray50 = Color(0xFFF5F7FA); // 소프트 그레이 배경
  static const gray100 = Color(0xFFEDF0F4);
  static const gray200 = Color(0xFFDDE2E9); // 테두리
  static const gray500 = Color(0xFF7A8699); // 보조 텍스트
  static const ink = Color(0xFF1A2433); // 본문 텍스트
  static const mint = Color(0xFF16A394); // 완료 표시
  static const error = Color(0xFFD14343);

  // 소셜 공식 컬러
  static const kakao = Color(0xFFFEE500);
  static const kakaoInk = Color(0xFF191919);
  static const naver = Color(0xFF03C75A);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.blue,
      primary: AppColors.blue,
      surface: Colors.white,
    ),
    scaffoldBackgroundColor: AppColors.gray50,
  );
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: c, width: w),
  );
  return base.copyWith(
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.gray50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      hintStyle: const TextStyle(color: AppColors.gray500, fontSize: 14),
      labelStyle: const TextStyle(color: AppColors.gray500),
      prefixIconColor: AppColors.gray500,
      border: border(AppColors.gray200),
      enabledBorder: border(AppColors.gray200),
      focusedBorder: border(AppColors.blue, 1.8),
      errorBorder: border(AppColors.error),
      focusedErrorBorder: border(AppColors.error, 1.8),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.blue,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(54),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.gray200),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.blue,
        side: const BorderSide(color: AppColors.gray200),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  );
}

// -----------------------------------------------------------------------------
// 화면 전환 애니메이션 (살짝 옆에서 밀려 들어오며 나타남)
// -----------------------------------------------------------------------------
Route<T> smoothRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 420),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (_, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0.06, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
