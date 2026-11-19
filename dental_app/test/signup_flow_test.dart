import 'package:dental_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(seconds: 1));
  await t.pump();
}

/// 시뮬레이터의 샘플 사진 그리기는 실제 비동기 작업이라 runAsync 로 기다림
Future<void> waitSimulator(WidgetTester t) async {
  for (var i = 0; i < 30 && find.text('상담 가이드').evaluate().isEmpty; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump();
  }
  expect(find.text('상담 가이드'), findsOneWidget);
}

Future<void> pickDropdown(WidgetTester t, String hint, String item) async {
  FocusManager.instance.primaryFocus?.unfocus(); // 입력칸 포커스 해제
  await t.pump();
  await t.ensureVisible(find.text(hint));
  await t.tap(find.text(hint));
  await settle(t);
  await t.tap(find.text(item).last);
  await settle(t);
}

void main() {
  const sizes = [Size(390, 844), Size(820, 1180), Size(1440, 900)];

  for (final size in sizes) {
    testWidgets('개인회원: 체험 로그인 → 홈 → 시뮬레이터(일반) → 홈으로 $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(const DentalApp());
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('개인회원'), findsOneWidget);
      expect(find.text('사업자회원'), findsOneWidget);
      expect(find.text('개인회원 로그인'), findsOneWidget);

      // 빈 값 로그인 → 에러 메시지
      await t.tap(find.text('개인회원 로그인'));
      await t.pump();
      expect(find.text('아이디를 입력해 주세요.'), findsOneWidget);

      await t.ensureVisible(find.text('개인회원 체험 로그인'));
      await t.tap(find.text('개인회원 체험 로그인'));
      await settle(t);
      // 2단계 홈
      expect(find.text('안녕하세요, 김민지님'), findsOneWidget);
      expect(find.text('B&A 치과 시뮬레이터'), findsOneWidget);
      expect(find.text('주위 치과 추천'), findsOneWidget);
      expect(find.text('추가 서비스 준비 중'), findsOneWidget);
      expect(find.text('시뮬레이터 불러오기'), findsOneWidget);
      expect(t.takeException(), isNull);

      await t.tap(find.text('주위 치과 추천'));
      await settle(t);
      expect(find.textContaining('서울특별시 강남구 역삼동 주변'), findsOneWidget);
      await t.tap(find.text('확인'));
      await settle(t);

      // 3단계 시뮬레이터 (일반)
      await t.tap(find.text('B&A 치과 시뮬레이터'));
      await settle(t);
      await waitSimulator(t);
      expect(find.text('B&A 치과 시뮬레이터'), findsOneWidget);
      expect(find.textContaining('PRO'), findsNothing);
      expect(find.text('김민지 님 · 개인회원'), findsOneWidget);
      expect(find.byTooltip('🤖 자동 QA'), findsNothing); // 전문가용 도구는 사업자만
      expect(find.text('🤖 자동 QA'), findsNothing);
      expect(t.takeException(), isNull);

      // ← 홈으로
      if (size.width < 1100) {
        await t.tap(find.byTooltip('홈으로'));
      } else {
        await t.tap(find.text('홈으로'));
      }
      await settle(t);
      expect(find.text('안녕하세요, 김민지님'), findsOneWidget);
    });
  }

  for (final size in sizes) {
    testWidgets('사업자회원: 소셜 → 기공소 가입 → 홈 → 시뮬레이터 PRO $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(const DentalApp());
      await t.pump(const Duration(milliseconds: 500));
      await t.tap(find.text('사업자회원'));
      await t.pump();
      expect(find.text('사업자회원 로그인'), findsOneWidget);
      expect(find.text('사업자회원 체험 로그인'), findsOneWidget);

      await t.ensureVisible(find.text('카카오'));
      await t.tap(find.text('카카오'));
      await t.pump(const Duration(milliseconds: 1400));
      await settle(t);
      expect(find.text('사업자회원 가입'), findsOneWidget);
      expect(find.text('카카오 계정이 연결되었습니다'), findsOneWidget);

      // 빈 제출 → 검증
      await t.ensureVisible(find.text('가입 완료 및 시작하기'));
      await t.tap(find.text('가입 완료 및 시작하기'));
      await t.pump();
      expect(find.text('병원명을 입력해 주세요.'), findsOneWidget);
      expect(find.text('시·도를 선택해 주세요.'), findsOneWidget);
      expect(find.text('읍·면·동을 입력해 주세요.'), findsOneWidget);
      expect(find.text('직책을 선택해 주세요.'), findsOneWidget);

      // 기공소로 바꾸기
      await t.ensureVisible(find.text('치과기공소'));
      await t.tap(find.text('치과기공소'));
      await t.pump();
      await t.enterText(find.byType(TextFormField).at(0), '바른치과기공소');
      await t.enterText(find.byType(TextFormField).at(1), '1234567890');
      await t.pump();
      expect(find.text('123-45-67890'), findsOneWidget);
      await t.tap(find.text('인증하기'));
      await settle(t);
      expect(find.text('✓ 정상 운영 중인 치과기공소 사업자로 확인되었습니다'), findsOneWidget);
      await t.enterText(find.byType(TextFormField).at(2), '0212345678');
      await t.pump();
      expect(find.text('02-1234-5678'), findsOneWidget);
      await pickDropdown(t, '시·도', '서울특별시');
      await pickDropdown(t, '시·군·구', '강남구');
      await t.enterText(find.byType(TextFormField).at(3), '역삼');
      await t.ensureVisible(find.text('가입 완료 및 시작하기'));
      await t.tap(find.text('가입 완료 및 시작하기'));
      await t.pump();
      expect(find.text('예) 역삼동, 동탄읍, 오창읍처럼 입력해 주세요.'), findsOneWidget);
      await t.enterText(find.byType(TextFormField).at(3), '역삼동');
      await pickDropdown(t, '직책을 선택하세요', '소장');
      await t.ensureVisible(find.textContaining('[필수]'));
      await t.tap(find.textContaining('[필수]'));
      await t.pump();
      await t.ensureVisible(find.text('가입 완료 및 시작하기'));
      await t.tap(find.text('가입 완료 및 시작하기'));
      await t.pump(const Duration(milliseconds: 900));
      await settle(t);
      expect(find.text('가입이 완료되었습니다'), findsOneWidget);
      expect(find.text('사업자회원 (치과기공소)'), findsOneWidget);
      expect(find.text('서울특별시 강남구 역삼동'), findsOneWidget);
      await t.tap(find.text('홈으로 시작하기'));
      await settle(t);

      // 홈 (사업자)
      expect(find.text('바른치과기공소 (소장)님, 환영합니다'), findsOneWidget);
      expect(find.text('B&A 치과 시뮬레이터\n전문가용'), findsOneWidget);
      expect(find.text('주위 기공소 추천'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.text('B&A 치과 시뮬레이터\n전문가용'));
      await settle(t);
      await waitSimulator(t);
      expect(find.text('바른치과기공소 · 소장'), findsOneWidget);
      expect(
        find.text(size.width < 600 ? 'PRO' : 'PRO (전문가용)'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('개인회원 가입: 이름·연락처·지역', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const DentalApp());
    await t.pump(const Duration(milliseconds: 500));
    await t.ensureVisible(find.text('개인회원 가입'));
    await t.tap(find.text('개인회원 가입'));
    await settle(t);
    expect(find.text('개인회원 가입'), findsOneWidget);
    expect(find.text('사업자등록번호'), findsNothing);
    await t.ensureVisible(find.text('가입 완료 및 시작하기'));
    await t.tap(find.text('가입 완료 및 시작하기'));
    await t.pump();
    expect(find.text('이름을 입력해 주세요.'), findsOneWidget);
    expect(find.text('휴대폰 번호를 입력해 주세요.'), findsOneWidget);
    await t.enterText(find.byType(TextFormField).at(0), '홍길동');
    await t.enterText(find.byType(TextFormField).at(1), '01098765432');
    await pickDropdown(t, '시·도', '부산광역시');
    await pickDropdown(t, '시·군·구', '금정구');
    await t.enterText(find.byType(TextFormField).at(2), '장전동');
    await t.ensureVisible(find.textContaining('[필수]'));
    await t.tap(find.textContaining('[필수]'));
    await t.ensureVisible(find.text('가입 완료 및 시작하기'));
    await t.tap(find.text('가입 완료 및 시작하기'));
    await t.pump(const Duration(milliseconds: 900));
    await settle(t);
    expect(find.text('개인회원'), findsWidgets);
    await t.tap(find.text('홈으로 시작하기'));
    await settle(t);
    expect(find.text('안녕하세요, 홍길동님'), findsOneWidget);
    expect(find.text('부산광역시 금정구 장전동'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
