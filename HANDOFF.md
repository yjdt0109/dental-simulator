# B&A 치과 시뮬레이터 — 작업 인계 문서 (2026-11-19 기준)

> 새 세션에서 이어서 작업할 때: 세션 시작 화면에서 저장소 `yjdt0109/dental-simulator` 를 고르고
> "HANDOFF.md 읽고 이어서 작업해줘"라고 하면 됩니다. 답변은 항상 한글로.

## 1. 현재 버전
- 태블릿 앱(안드로이드 APK, Flutter): **2026.11.27-b** (고정 열쇠 서명, analyze·test 153개·APK 빌드 확인) (`lib/cast/cast_service.dart`의 `appVersion`)
- 상담 PC 모니터(웹, Netlify에 폴더째 끌어다 놓기): **v3.43** (`monitor-web/`)
- 자동 테스트: 153개 모두 통과 (`flutter test`)

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
10. **비교 목록 정리 (2026.11.19-e)**: 첫 화면(변환 전)에도 [이전 변환 불러오기](환자 기록) · [😊 미소 미리보기] 버튼. 미소 미리보기는 변환 전에도 열림(보철 정밀 매칭 가능), 환자 기록 화면에서는 미소 버튼 뺌. 미소 사진은 갤러리 여러 장 / 🗂 환자 기록에서 여러 장(누른 차례) / PC 여러 장·기록에서 불러오기(`smileFromRec`). 불러온 사진은 모두 `PatientPhoto.extras`(번호 -1, -2 …)로 브리핑 왼쪽 '비교할 사진' 목록 끝에 차례대로 + [사진 추가]. 브리핑에서는 변환 전이라도 목록에서 1~2장 골라 비교. PC 에는 목록 위치 번호(items/subs/cmp)로 보냄
11. **기록 사진 한 장씩 불러오기 (2026.11.19-f)**: 기록 상세(태블릿·PC)의 사진마다 [이 사진만 불러오기] → 그 기록의 환자(없으면 원본만으로 만듦)에 원본/결과/미소/미소 미리보기를 한 장씩 차례대로 (`RecordPhotoLoader`, PC 명령 `recPhoto {id,f}`). 기존 버튼은 [시뮬레이터로 모두 불러오기]. 홈(시작 화면)에 [🗂 시뮬레이터 불러오기] 카드 → 시뮬레이터를 열며 바로 환자 기록 목록
12. **2026.11.26-c**: 기록 상세의 [시뮬레이터로 모두 불러오기] 없앰(태블릿·PC) → 사진마다 [이 사진만 불러오기]만. 불러온 사진은 **지금 화면 환자**의 비교 목록 끝에 (예시 사진 화면이면 그 기록 환자를 만듦, 같은 기록 환자면 결과→결과·미소→미소). 브리핑 목록 항목마다 ✕(목록에서 빼기, 원본 제외, 결과는 [이전으로] 가능, PC `cmpRemove`). 브리핑은 항상 목록 표시, [기록·사진 추가]. PC 목록 아래 [🗂 기록 사진]·[📷 사진 올리기](`extraPhoto`)
13. **2026.11.19-h / PC v3.30**: 태블릿 알림(_toast)을 PC 에도 띄움(state `notice`), PC 첫 화면에도 [🗂 기록 사진 불러오기], PC 비교 목록의 [기록 사진]·[사진 올리기]를 목록 위로(왼쪽 아래 버튼과 겹침 해결), PC 🪄 자동 선택 도구를 사진 위 → 사진 아래 [🪄 탭 한 번 자동 선택으로 치아 고르기] 체크 칸 + 도구 줄로 이동 (태블릿은 아직 그대로)
14. **2026.11.19-i / PC v3.31**: 🦷 치아 크기 조절에서 **줄이기**(−30% 까지, 무삭제는 불가). 줄어든 자리는 치아 바깥(절단끝→아래 입 안, 잇몸 쪽→위 잇몸)을 끌어와 채움 (`scaleToothMasked` 음수). **다시 변환 기준**: 예전엔 항상 원본(beforeBytes) → 이제 비교 목록에서 변환 결과를 누르면 그 결과가 기준(`PatientPhoto.basePick/baseIndex/baseBytes`), 결과 이름에 'N번 기준'. 변환 상자·PC 변환 버튼 위에 '기준 사진' 표시(state `base`)
15. **😊 원본 2장 방식 (2026.11.23-a / PC v3.32)**: 원본 1 = 개구기 사진(메인), 원본 2 = 미소 사진(p.smile). 변환할 때 미소 사진을 참고 사진으로 나노바나나(2단계 A·B, 단독)에 함께 보냄(`smileRefs`, `kSmileRefPrompt`: 스마일 아크·정중선·비율). FLUX 1단계와 옵션 C(Vertex)는 사진 1장만 받아 참고 못 함. 변환 끝나면 자동으로 미소 사진에 정밀 매칭(`_matchAfterConvert` → `_matchRun`) → 최종 목표 = 미소 결과(미소 ↔ 미소 미리보기 비교 화면 + 목록). 변환 상자·PC 패널에 체크 2개(`smileRef`, `autoMatch` 명령, state `smileRef`). 결과 이름에 '미소 참고'
16. **2026.11.23-b / PC v3.33**: 왼쪽 '비교할 사진' 목록을 브리핑이 아닐 때·변환 전 첫 화면에서도 표시(태블릿은 폭 700 이상). 목록에서 사진을 누르면 첫 화면(영역 지정)에서 빠져나와 그 사진을 보여 줌(`p.editing=false`), [처음 사진 보기]로 돌아감. `_mode`: 결과 없고 원본만 고르면 edit
17. **💾 PC 폴더 자동 저장 (2026.11.24-a / PC v3.34)**: PC [환자 기록] 창 위 [📁 저장 폴더 고르기](크롬·엣지 File System Access, 핸들은 IndexedDB `bna-pc` 에 기억, 다시 켤 때 권한 필요하면 [다시 연결]). 폴더 구조: `환자이름/2026-11-24 14시30분 상담 (치료)/` 원본·N번 시뮬레이션·미소 2장·상담내용.txt + `환자이름/치료완성/`(실제 완성 사진용, 비어 있음). 폴더 고른 뒤 저장되는 기록은 자동, 이전 기록은 [⬇ 빠진 기록 PC로 가져오기]. 목록 `_B&A 기록목록.json`(id→sig). 흐름: PC `recSyncReq id` → 태블릿 `pcSyncPayload` 를 `rooms/{방}/recSync` 에 → PC 가 쓰고 지움. 결과 수·미소가 늘면 sig 바뀌어 다시 저장. (테스트 메모: 이 컨테이너 크롬은 LANG=C.UTF-8 이어야 한글 파일 이름 OK)
18. **🖼 원본 2슬롯 + 2단계 Final Smile (2026.11.25-a / PC v3.35)**: 사진 위 카드 2개 [원본 1 · 자연스러운 미소] [원본 2 · 개구기] — 누르면 그 사진이 변환 대상(라디오), 빈 카드는 사진 올리기, '사진 바꾸기'(PC 우클릭). 구조: 슬롯마다 PatientPhoto(`slot` 1/2, `pair` 연결, Consult 공유 `sharedConsult`), 원본 2 쪽 `smile` = 원본 1. 변환 결과 아래 글씨 = **After**, 원본 라벨 '원본 1 (미소)'/'원본 2 (개구기)'. **[✨ 2단계 · 최종 미소 만들기]**: `lib/ai/final_smile.dart` `FalNanoBananaEdit`(https://fal.run/fal-ai/nano-banana/edit, image_urls=[원본 1, After] data URI, sync_mode) + 상수 `kFinalSmilePrompt`(사용자 문구 그대로) → 입술 사이를 찾으면 바깥은 원본 1 픽셀로 고정(`protectOutside`) → p.smileAfter + 목록 '✨ Final Smile', 미소 비교 화면. PC 명령 `slotSelect`·`slotPhoto {s,b}`·`finalSmile`, state `slots`, `slotImg`(카드 사진). 예전 '변환 후 자동 정밀 매칭'은 기본 끔. **fal 나노바나나 엔드포인트는 실제 호출로 아직 확인 안 함**
19. **2026.11.25-b / PC v3.36**: PC [💾 저장 및 상담 완료] 버튼(확인 창 → 명령 `confirmSave` → 태블릿 `_confirm(ask:false)` → 환자 기록 → PC 폴더 자동 저장, 아래에 PC 폴더 저장 켜짐/꺼짐 + 폴더 고르기 링크). 결과 이름 'OOO After N'(엔진은 작은 글씨 'After · 단독'). '😊 미소 비교' 버튼 없앰(태블릿 칩·PC 버튼, 왼쪽 목록에서 비교). PC [치아 크기 조절]을 아래 버튼 줄로 옮겨 목록과 안 겹치게. 서비컬 라인·🪄 치아 고르기 체크 칸을 어느 화면에서나 보이게, 체크하면 원본 화면으로(`before`, `_toEditView`). PC 슬롯 카드 사진이 없으면 `slotImgReq` 로 다시 받음
20. **2026.11.25-c / PC v3.37**: 치아 줄이기 잔상 제거(`scaleToothMasked`: 윤곽을 치아 크기 8%+3px 넓혀 덮고 그 바깥에서 배경을 끌어옴). 치아 크기 조절 대상 = 왼쪽 목록에서 마지막으로 누른 사진(`PatientPhoto.resizeTarget`: 원본·원본 1·미소 원본 제외, After·미소 미리보기·Final Smile·불러온 사진 가능). After 면 새 After, 다른 사진이면 '… · 크기조절' 로 목록에 추가(그 사진엔 치아 윤곽이 없으니 탭해서 고름). PC 는 state `rzOk`/`rzOf`
21. **2026.11.25-d / PC v3.38**: 보철 사진 정밀 매칭의 2번을 **오늘 만든 After 목록**에서 고르기(`_afterChoices`: 이 사진·짝 사진의 After 전부 + '크기 조절'·After 붙은 사진). PC 미소 창 [오늘 만든 After에서 고르기] 썸네일(smileImg `aft`, 명령 `matchUseResult key`), 태블릿 미소 미리보기 화면에도 가로 목록(`afterChoices`)
22. **2026.11.26-c**: 옵션 B 오류 수정 — Firebase 에 `gemini-3-pro-image-preview` 가 없음(Publisher model not found). `TwoPassPipeline.proFinish`: 설정 이름 → 후보(`gemini-3-pro-image` 등) 차례로 → 모두 없으면 fal.ai `nano-banana-pro/edit` 로(이후 계속 fal, `proViaFal`). PC 변경 없음(v3.38 그대로)
23. **2026.11.25-f ③② (치아 길이·형태·경계)**: ③ `marginLockedRegion`(tooth_select.dart): 🪄 고른 치아의 잇몸 쪽 경계만 고정, 절단 쪽 치아 길이 25%(가장 긴 곳 기준이라 깨진 치아도 채움) + 옆에 고른 치아가 있으면 틈까지 15% 열기 → FLUX 마스크·원본 복원 영역으로 사용. 라미네이트·올세라믹·임플란트·교정에 적용(무삭제는 기존 10% 길게, 미백은 윤곽 그대로). ② `align_fix.dart` `alignAiToSource`: AI 결과를 원본과 비교(160px 회색조, ±4% 크기·±5% 밀림, 바뀐 치아 영향 줄이게 차이 40에서 자름)해 3% 이상 나아질 때만 되돌림 → `_fullResult`(모든 전체 사진 AI 결과)에 적용
24. **🆕 단계형 새 시뮬레이터 화면 (2026.11.26-a / PC v3.39)**: `lib/simulator/step_flow.dart` (simulator_screen.dart 의 part, extension `_StepFlow`). 위 단계 표시줄 ① 사진 ② 치아 고르기 ③ 치료 정하기 ④ After 만들기 ⑤ 다듬기 ⑥ Final Smile ⑦ 저장 + 오른쪽(폰은 아래) 지금 단계 패널 + [이전]/[다음]. 기능은 기존 것 재사용(`_convertBox`, `_panel(only:{…})` 조각, `_openResize`, `_finalSmile`, `_confirm`), 비교 목록은 4단계부터. 기본(새 화면), 위쪽 아이콘·더보기로 [예전 화면] 전환(pref `ui.stepFlow`). 새 화면 처음 쓸 때 엔진 기본을 옵션 B 로(한 번만). 테스트는 `test/flutter_test_config.dart` 에서 `debugStepFlowOff=true`(예전 화면 기준), 새 화면 테스트는 `step_flow_test.dart`. **사진 돌리기** ⟲⟳(`rotatePhoto`, 슬롯 사진 새로 만듦 → 그 사진 After·치아 선택 지워짐 경고) + 올릴 때 EXIF 방향 자동 바로 세우기(`normalizeOrientation`). **＋ 새 작업**(위쪽 버튼·7단계 끝·PC 머리 버튼): 빈 자리(`PatientPhoto.blank`) 로 1단계부터. PC: 단계 표시줄(명령 `step`), 카드 ⟲⟳(`slotRotate`), [＋ 새 작업](`newCase`, 저장 안 했으면 확인)
25. **PC v3.40 (태블릿 변경 없음)**: 비교 목록 위 [기록 사진]·[사진 올리기]와 아래 [기록 사진 불러오기]를 **[📂 불러오기]** 하나로(메뉴: 💻 PC 파일에서 여러 장 → `extraPhoto` / 🗂 환자 기록에서 → 기록 창). 오른쪽 [PC에서 사진 올리기] → **[📷 사진 촬영]**(웹캠 getUserMedia, 카메라 여러 개면 고르기, 찍은 뒤 [원본 2로]/[원본 1로] → `slotPhoto`). 위쪽 [자동 QA]·[환자 기록]·[보관함]은 **🧪 전문가 모드** 체크(PC마다 localStorage `bna.expert`)일 때만 보임
26. **고급·전문가 정리 (2026.11.26-b / PC v3.41)**: 새 화면 ④는 간단하게(`_step4`: 엔진 한 줄 · 기준 사진 · 추가 요청 · 큰 [✨ After 만들기]). **⚙ 고급** 패널(`_advancedPanel`, 오른쪽 패널을 바꿔 보여 줌 `_advOpen`): AI 켜기·엔진·자동 지시(`_aiRow`), 적용 강도, 미소 사진 참고, 서비컬 선, 원본 윤곽, 눈 가리기, 예전 미소 미리보기(정밀 매칭), API 키. **🧪 전문가** 메뉴(`_expertMenu`): 자동 QA·보관함(PRO), 예전 화면으로, 상담 초기화, 로그아웃. 새 화면 위쪽 버튼 = ＋ 새 작업 · 🗂 환자 기록 · PC 연결 · ⚙ 고급 · 🧪 전문가(`_stepActions`). PC: 오른쪽 패널에 '엔진: …' 한 줄 + 추가 요청만 보이고, AI 켜기·엔진 목록·자동 지시·강도·미소 참고는 [⚙ 고급] 접기(`#pcAdv`)
27. **원본 1·2 넣는 길 늘림 (2026.11.26-c / PC v3.42)**: PC 왼쪽 목록 사진마다 ①② 버튼 → 그 사진을 원본 1·2 로(명령 `slotFromList {s, n}`). PC 원본 카드에 📷(그 카드로 바로 촬영)·📁(PC 파일), 빈 카드 클릭 = 그 카드로 촬영. 태블릿 원본 카드 사진 넣기에 '🗂 환자 기록에서'(`_slotFromRecords`)
28. **사용자 요청 정리 (2026.11.27-a / PC v3.43)**: PC 에서 ① 단계 표시줄 숨김(`renderStepBar` 항상 hidden) ② 😊 미소 미리보기 창의 [미소 사진 올리기]·[환자 기록에서 불러오기] 숨김 ③ 사진 아래 [서비컬 라인]·[🪄 탭 한 번 자동 선택] 체크 칸 숨김(`guideShow=false`). **👁 눈 가리기** 체크 칸을 PC 오른쪽(전문가 모드 옆, `#eyeRow`)에 추가 → 명령 `eyeMask` → 태블릿 `_setEyeMask`: 설정 기억 + 지금 원본 2(개구기) 사진에 바로 적용(가리기 전/후 사진을 `PatientPhoto.eyeOrig`/`eyeMasked` 에 두고 바꿔 끼움, state `eye {ok,on,has}`). 태블릿 ⚙ 고급·설정의 눈 가리기도 같은 함수. 슬롯 사진 눈 가리기가 바로 세운 사진(`data`)이 아니라 원래 사진(`bytes`)에 하던 버그 수정. **비교 목록에서 원본 1(미소) 사진을 ✕ 로 빼면 위 [원본 1] 카드에서도 빠짐**(`_isSlot1Photo`·`_clearSlot1`: 슬롯 1 사진 삭제, 짝 끊기, p.smile·미소 사진 목록 지움)
29. **2026.11.27-b**: App Check 오류(`[firebase_app_check/unknown] Too many attempts`)가 안내 없이 영어로만 뜨던 것 수정 — `AiError.from` 이 `app_check` 도 알아보고 '인증 토큰을 Firebase 콘솔 디버그 토큰 관리에 등록 → 앱 껐다 켜기, 안 되면 30분 뒤' 안내 (`test/ai_error_test.dart`)
30. **상담 PC**: 위 기능 대부분을 마우스로 (SAM, 기준점, 크기 조절, QA, 보관함, 기록, 미소)

## 4. 마지막 대화에서 논의 중이던 것 (다음 할 일)
- ③·② 넣음(2026.11.25-f) → 사용자 실제 테스트 결과 대기. 남은 제안: ④ 일반 라미네이트·크라운에도 원하는 절단선 지정, 경계 자동 검사(차이 크면 재시도)
- 다음 후보: 실제 보철·교정 **완성 사진**을 앱에서 환자 기록에 추가 → PC `환자이름/치료완성/날짜/` 로 저장 (사용자가 시뮬레이션과 구분 원함)
- **사용자 지적(결정 대기)**: [😊 미소에 입히기] 결과 치아가 변환(보철) 사진 치아와 안 닮음. 제안: ① 정밀 매칭 [지금 결과 쓰기]로 시험 ② 변환 치아만 잘라 보내기 + 결과 치아 숫자 검사·재시도 ③ 미소에 입히기를 정밀 매칭 방식으로 교체
- 브리핑 목록 '짝 자동 비교'는 사용자가 중지시킴 → 브랜치 `wip-pair-compare` 에 보관만 (main 에 없음)
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
- PC 모니터: `monitor-web` 폴더를 Netlify에 그대로 올림 (사용자에게는 `monitor-web-v3.xx.zip` 으로 묶어 전달). 새 버전 만들 때 index.html의 버전(3.42)을 올림
- 버전 올리기: `lib/cast/cast_service.dart`의 `appVersion` + PC `app.js` 안의 "2026.11.26-c 이상" 문구

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
- **🔑 앱 서명 열쇠 (2026-11-27)**: 예전 APK 는 세션마다 새로 생기는 임시(debug) 열쇠로 서명돼서, 새 세션 APK 가 "패키지가 기존 패키지와 충돌" 로 설치 안 됨. → 고정 열쇠(`dental_app/android/bna-release.jks` + `key.properties`, 저장소에는 안 올림)를 만들어 서명. 사용자에게 `BnA-앱서명열쇠-보관용.zip` 으로 보냄. **새 세션에서 APK 만들기 전에 사용자에게 이 zip 을 올려 달라고 해서 `dental_app/android/` 에 풀 것** (없으면 임시 열쇠로 서명돼 또 충돌). 2026.11.27-a 부터 이 열쇠 → 예전 앱은 한 번 지우고 설치해야 했음(태블릿 기록은 지워지므로 PC 폴더로 먼저 백업). **앱을 지우고 다시 깔면** Fal.ai·Vertex 키와 App Check 디버그 토큰(SharedPreferences `ai.appCheckDebugToken`)이 새로 바뀜 → 키 다시 넣고, 새 토큰을 Firebase 콘솔 App Check → 디버그 토큰 관리에 등록해야 나노바나나 변환이 됨
- **2026-11-27 두 번째 세션**: 네트워크가 풀려 Flutter 3.50.1 설치 → 2026.11.27-a `flutter analyze` 오류·경고 없음(참고 info 51개, material.dart deprecated 등), `flutter test` 151개 모두 통과. Android SDK(cmdline-tools, platform 36, build-tools 36) 설치 → AGP 9.1.0 → 9.1.1 (Flutter 3.50.1 최소 요구) → APK 빌드 성공(134.4MB). Maven 서버가 429(요청 너무 많음)로 몇 번 거부 → 쉬었다가 다시 돌리면 됨(`GRADLE_OPTS="-Dorg.gradle.parallel=false -Dorg.gradle.workers.max=2"`). 빌드 경고: Gradle 9.5.0·AGP 9.3.1·Kotlin 2.4.20 이상으로 곧 올려야 함, 일부 플러그인이 Built-in Kotlin 미지원 안내
- **2026-11-27 세션**: Flutter 가 Dart SDK 를 받는 주소(storage.googleapis.com)가 이 세션 네트워크에서 막혀(403) `flutter analyze`·`flutter test`·APK 빌드를 못 함. 2026.11.27-a 는 코드만 고쳐 올림 → **다음 세션에서 먼저 analyze·test·APK 빌드 확인할 것**
- 2026.11.19-b: PC 정밀 매칭에서 "Field platform_ for wz0 not found" → 릴리스 빌드의 코드 이름 줄이기(R8)가 MediaPipe 내부 이름을 바꿔서 생김. `android/app/proguard-rules.pro` 에 MediaPipe·protobuf 보호 규칙 추가 (2026.11.19-c)
- 2026.11.19-c 에서도 "com.google.mediapipe.framework.Graph" 오류 (Flogger 이름 바뀜) → 릴리스 빌드의 코드 이름 줄이기(R8)를 아예 끔 (`isMinifyEnabled = false`, APK 135MB). 오류 메시지는 원인 사슬 전체를 보여 줌 (2026.11.19-d, PC v3.26 긴 오류 줄바꿈)
