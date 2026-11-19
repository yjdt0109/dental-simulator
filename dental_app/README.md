# Before & After 치과 시뮬레이터 — 1단계 앱

하나의 Flutter 코드로 **안드로이드(태블릿·폰)**, **Windows PC**, **웹**을 모두 빌드합니다.

## 들어 있는 기능
- 로그인 / 소셜 간편 가입(가상) / 치과 정보 등록(사업자 인증·연락처·우편번호·주소·직책)
- 시뮬레이터 메인
  - 상단 촬영실 사진 바 (샘플 3명 + 카메라 촬영·갤러리 등록)
  - 치아 영역 지정 → 상담 가이드에서 **[After 변환하기]**
  - 일반 화면: Before 위 / After 아래, 브리핑 모드: 손잡이 슬라이더 (Esc로 종료)
  - 클릭형 덴탈 차트(FDI), 셰이드 칩(BL1·A1·A2·B1), 적용 강도, 동의 완료
- 큰 화면: 태블릿을 HDMI·무선 화면 공유로 모니터에 연결 (브리핑 모드에서 상태바 자동 숨김)

## 폴더 구조
```
lib/
├─ main.dart                    앱 시작
├─ app_theme.dart               메디컬 블루 & 화이트 테마, 화면 전환 효과
├─ models/clinic_profile.dart   가입한 치과 정보
├─ utils/formatters.dart        전화번호·사업자번호 자동 하이픈
├─ widgets/brand_widgets.dart   로고, 소셜 버튼, 로그인 화면 틀
├─ screens/login_screen.dart    로그인
├─ screens/signup_screen.dart   치과 추가 정보 등록 + 가입 완료
└─ simulator/
   ├─ simulator_screen.dart     시뮬레이터 메인 화면
   ├─ compare_viewer.dart       영역 지정 / 위아래 비교 / 슬라이더 비교
   ├─ dental_chart.dart         덴탈 차트, 셰이드 칩
   ├─ whitening.dart            직접 등록한 사진의 미백 시뮬레이션
   ├─ sample_photos.dart        샘플 환자 예시 사진(코드로 그림)
   └─ sim_models.dart           셰이드·치아 번호·환자 데이터
test/                           자동 테스트 (flutter test)
```

## 실행
```
flutter pub get
flutter run -d chrome      # PC 브라우저로 확인
flutter run -d windows     # Windows 프로그램으로 확인 (Visual Studio C++ 필요)
flutter run                # USB로 연결한 안드로이드 태블릿
```

## Play 스토어 등록 전 할 일
1. `android/app/build.gradle.kts` 의 `applicationId` (현재 com.dental.simulator.dental_app) 를 병원 고유 ID로 변경
2. 앱 서명 키 만들기 → https://docs.flutter.dev/deployment/android
3. `flutter build appbundle --release` → `build/app/outputs/bundle/release/app-release.aab` 업로드

## 다음 단계 (2단계 이후)
- Firebase: 실제 로그인·소셜 연동, 상담 기록·사진 저장, 상담 PC 모니터 모드(웹)
- 국세청 사업자 상태조회, 도로명주소 검색 연동
- AI(Gemini) 연결: `simulator_screen.dart` 의 `_convert()` 안에서 미백 대신 AI 편집 호출
