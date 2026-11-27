# 작업 규칙 (이 저장소에서 일하는 Claude 용)

- **항상 한글로** 답한다. 사용자는 치과·기공소 실무자이며 개발자가 아니다. 쉬운 말로 설명한다.
- 시작할 때 `HANDOFF.md` 를 읽고 현재 상태와 "다음 할 일"을 확인한다.
- **작업이 끝날 때마다 자동 저장**: 변경 사항을 커밋하고 GitHub에 푸시한다
  (`git -c push.negotiate=true push -u origin main`). 동시에 `HANDOFF.md` 의 버전·기능·다음 할 일을 최신으로 고친다.
  커밋 메시지는 한글로 짧게.
- API 키·비밀번호·서비스 계정 JSON 은 절대 저장소에 넣지 않는다 (앱의 [🔑 API 키 설정]에만 저장됨).
  사용자가 채팅에 키를 붙여넣지 않도록 안내한다.
- 환자 사진·환자 정보 파일을 저장소에 올리지 않는다.

## 구조
- `dental_app/` Flutter 태블릿 앱 (안드로이드 APK). 버전: `lib/cast/cast_service.dart` 의 `appVersion`
- `monitor-web/` 상담 PC 모니터 (정적 웹, Netlify). 버전: `index.html` 의 v3.xx, `app.js` 의 "앱 20xx… 이상" 문구

## 개발 환경 준비 (새 클라우드 세션)
Flutter SDK 가 없으면 설치한다 (마지막 사용: Flutter 3.50.1 stable):
```bash
git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/flutter
export PATH=~/flutter/bin:$PATH
cd dental_app && flutter pub get
```
안드로이드 빌드에는 Android SDK 가 필요하다 (없으면 설치 후 `flutter build apk --release`).

## 확인 · 전달
- 바꾼 뒤 `flutter analyze`, `flutter test` 를 돌린다 (모두 통과해야 함).
- 앱을 바꾸면 APK 를 빌드해 사용자에게 파일로 보낸다. PC 모니터를 바꾸면 버전을 올리고 `monitor-web` 을 zip 으로 묶어 보낸다.
- PC 화면은 가짜 Firebase(fakefb)로 Playwright 브라우저 확인을 했었다.
