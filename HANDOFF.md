# B&A 치과 시뮬레이터 — 작업 인계 문서 (2026-11-19 기준)

> 새 세션에서 이어서 작업할 때: 세션 시작 화면에서 저장소 `yjdt0109/dental-simulator` 를 고르고
> "HANDOFF.md 읽고 이어서 작업해줘"라고 하면 됩니다. 답변은 항상 한글로.

## 1. 현재 버전
- 태블릿 앱(안드로이드 APK, Flutter): **2026.11.19-d** (`lib/cast/cast_service.dart`의 `appVersion`)
- 상담 PC 모니터(웹, Netlify에 폴더째 끌어다 놓기): **v3.26** (`monitor-web/`)
- 자동 테스트: 124개 모두 통과 (`flutter test`)

## 2. 구성
- `dental_app/` — Flutter 앱 (lib, test, android, web)
- `monitor-web/` — PC 상담 모니터 (index.html, app.js, style.css, sw.js …), Netlify: yejundentallabpcai.netlify.app
- Firebase 프로젝트: ai-yejundetallab (Realtime DB로 태블릿↔PC 연결, Firebase AI Logic로 나노바나나)
- Fal.ai: FLUX.1 Fill(1단계), SAM 2(치아 자동 선택). 키는 앱의 [🔑 API 키 설정]에 저장 (채팅에 키를 붙여넣지 않기)
- Vertex(옵션 C): API 키+프로젝트 ID (앱 설정)

## 3. 들어가 있는 기능 (요약)
1. **로그인 → 홈 → 시뮬레이터**: 개인/사업자 탭, 체험 로그인, 가입(시·구·동), 홈 카드, 사업자는 PRO(전문가용)
2. **변환**: 2단계(FLUX Fill → 마무리 A/B/C), 교정은 나노바나나 단독. 서비컬 라인·잇몸 잠금
3. **무삭제 라미네이트 보호**: 절단선 자동 감지/그리기, 짧아진 절단끝 원본 복원, 마진 띠 잠금, 숫자 검사(치아별 길이·마진) → 미달 시 최대 2회 재변환
4. **🪄 SAM 원클릭 치아 선택**: 탭 주변을 잘라 크게 보내서 정확도↑, 더하기/빼기 붓, 기준점(초록=잇몸 꼭대기, 노랑=절단끝) 드래그, 선택 영역이 FLUX 마스크로 연결, 선택 바깥은 원본 100% 보호
5. **원본 윤곽 겹쳐 보기**, **🦷 치아 크기 조절**(치아 윤곽만 키움, 확대/이동, 길게 누르기·오른쪽 클릭=같이 잡힌 옆 치아 빼기, 무삭제는 마진 고정)
6. **🤖 자동 QA**(정답지 선택, 자체 평가, 목표 80/90, A·B·C 비교, 채점 모델 자동 찾기), **📚 프롬프트 보관함**, **🖼 메인 화면으로 가져오기**
7. **🗂 환자 기록**: 날짜 › 환자이름 › 시각 폴더, 이름·날짜·치료종류 검색, 다시 불러오기, 미소 사진 같은 폴더에 저장
8. **😊 미소 미리보기**: 미소 사진의 입술 사이만 변환 치아로(나노바나나 2장 입력 + 입술·얼굴 원본 고정), 메인 화면 미소 비교, PC 패널
9. **🦷 보철 사진 정밀 매칭** (😊 미소 미리보기 화면 안): 1번 자연 미소 + 2번 개구기 보철 사진 → MediaPipe 얼굴 특징점(눈동자·코끝, 눈 가린 사진은 코 기준)으로 2번을 1번에 맞춤(Kotlin `DentalAlignmentHelper.kt`, 채널 `bna/dental_align`) → 입술 안쪽 마스크·보철 치아만 잘라 합성 → FLUX Fill(빈 곳만) → 나노바나나 Pro 리터칭(실패 시 2.1) → 입술·얼굴 원본 고정. Dart: `lib/ai/smile_match.dart`. APK 127MB(모델 3.8MB 포함). **실제 기기·실제 AI로는 아직 시험 안 함**. PC(v3.25)에서도 😊 미소 미리보기 창 아래 칸에서 2번 올리기/지금 결과 쓰기/시작, ①②③ 단계 탭, [이 사진을 미소 비교에 쓰기] (명령: matchPhoto·matchUseAfter·matchRun·matchPick, 계산은 태블릿)
10. **상담 PC**: 위 기능 대부분을 마우스로 (SAM, 기준점, 크기 조절, QA, 보관함, 기록, 미소)

## 4. 마지막 대화에서 논의 중이던 것 (다음 할 일)
- **먼저**: 보철 정밀 매칭을 실제 태블릿에서 시험 → 정렬 오차·결과 확인. 이어서 제안(결정 대기): 수동 3점 미세조정 화면, FLUX Kontext 확인 후 엔진 비교, 하악 치아/스티커 기준 정렬
사용자 지적: 살짝 웃는 미소 사진(잇몸 안 보이고 치아 일부만 보임)을 **교정**으로 변환하면 잇몸까지 새로 만들고 과하게 가지런해져서 실패.
제안했던 순서 (사용자 결정 대기):
1. **바로 개선(추천)** — ① 미소 사진이면 입술 사이만 변환(입술 자동 찾기 마스크, 원래 안 보이던 잇몸은 만들지 않음) ② 미소 사진 전용 지시문(치아 노출량·입술 위치 유지, 치아 크기 원본, 배열만 살짝) ③ "개구기 사진에서 시뮬레이션 → 😊 미소 미리보기로 입히기" 흐름 안내 ④ 교정은 원본 치아 이식(모양 그대로, 위치만 AI)
2. **다음** — FLUX Kontext(Fal.ai)를 미소 사진용 엔진 D로 추가 → 자동 QA로 비교 (fal.ai 문서 사이트는 이 환경에서 막혀 있어 fal.run 으로 직접 확인 필요)
3. **장기** — 실제 치료 후 사진이 쌓이면 FLUX LoRA 학습(동의 받은 기록만), 기록에 [실제 치료 후 사진 추가]·학습 동의 체크·학습 데이터 내보내기
- 그 밖에 제안만 하고 아직 안 한 것: 11·21 좌우 대칭 맞추기, QA 숫자 대칭 검사, PC에서 미소 사진 2장/비교 1장 내려받기, 태블릿 🪄 도구 모음 위치 이동

## 5. 빌드 방법
```bash
cd dental_app
flutter pub get
flutter test
flutter build apk --release   # build/app/outputs/flutter-apk/app-release.apk
```
- PC 모니터: `monitor-web` 폴더를 Netlify에 그대로 올림 (사용자에게는 `monitor-web-v3.xx.zip` 으로 묶어 전달). 새 버전 만들 때 index.html의 버전(3.26)을 올림
- 버전 올리기: `lib/cast/cast_service.dart`의 `appVersion` + PC `app.js` 안의 "2026.11.19-d 이상" 문구

## 6. 주요 파일
- `lib/simulator/simulator_screen.dart` — 메인 화면(변환·PC 명령 처리 `_onRemoteCmd`·상태 전송 `_pushCast`)
- `lib/ai/pipeline.dart`(2단계·Fal FLUX·Vertex), `ai_service.dart`(나노바나나·채점), `prompt_engine.dart`(임상 지시)
- `lib/ai/tooth_select.dart`(SAM·마스크·측정·크기 조절 계산), `noprep_guard.dart`(무삭제 보호), `smile.dart`(미소)
- `lib/simulator/compare_viewer.dart`(편집기·비교 화면), `tooth_resize.dart`·`resize_session.dart`, `smile_screen.dart`, `sim_import.dart`
- `lib/qa/*`(자동 QA·보관함·PC 연결 `qa_remote.dart`), `lib/records/*`(환자 기록), `lib/screens/*`(로그인·가입·홈)

## 7. 주의
- 환자 사진은 민감정보: 미소 사진은 눈을 가리지 않음 → 동의 안내. AI 학습에 쓰려면 별도 동의
- API 키·비밀번호는 채팅에 붙여넣지 말고 앱 설정에만 입력

## 8. 알려진 문제·해결 기록
- 2026.11.19-b: PC 정밀 매칭에서 "Field platform_ for wz0 not found" → 릴리스 빌드의 코드 이름 줄이기(R8)가 MediaPipe 내부 이름을 바꿔서 생김. `android/app/proguard-rules.pro` 에 MediaPipe·protobuf 보호 규칙 추가 (2026.11.19-c)
- 2026.11.19-c 에서도 "com.google.mediapipe.framework.Graph" 오류 (Flogger 이름 바뀜) → 릴리스 빌드의 코드 이름 줄이기(R8)를 아예 끔 (`isMinifyEnabled = false`, APK 135MB). 오류 메시지는 원인 사슬 전체를 보여 줌 (2026.11.19-d, PC v3.26 긴 오류 줄바꿈)
