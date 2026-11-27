// 상담 모니터 v3 (상담실 PC) — 태블릿 앱 화면을 크게 보여주고, 마우스로 앱과 같은 조작을 합니다.
// 태블릿이 항상 기준(원본)이고, PC 는 rooms/{방}/cmds 에 명령을 보내면 태블릿이 처리한 뒤
// 바뀐 상태(state)·사진(images)을 다시 보내 줍니다. 데이터 구조는 앱 lib/cast/cast_service.dart 참고.
import { initializeApp } from 'https://www.gstatic.com/firebasejs/11.10.0/firebase-app.js';
import { getAuth, signInAnonymously } from 'https://www.gstatic.com/firebasejs/11.10.0/firebase-auth.js';
import { getDatabase, ref, set, update, remove, push, get, onValue, onDisconnect, serverTimestamp } from 'https://www.gstatic.com/firebasejs/11.10.0/firebase-database.js';

const firebaseConfig = {
  apiKey: 'AIzaSyBk4rSohjlS0WwfpCeczRgGI9TJyAnmiz4',
  authDomain: 'ai-yejundetallab.firebaseapp.com',
  databaseURL: 'https://ai-yejundetallab-default-rtdb.asia-southeast1.firebasedatabase.app',
  projectId: 'ai-yejundetallab',
  storageBucket: 'ai-yejundetallab.firebasestorage.app',
  messagingSenderId: '572066074232',
  appId: '1:572066074232:web:0f5730d8cb780c65aba78d',
};

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* 저장 불가 */ } },
};

// ---- 방 번호(추측 불가 24자): 상담 모니터를 열 때마다 새로 만듦 → QR 을 스캔해야만 연결 (자동 연결 없음) ----
function randomId(n) {
  const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const buf = new Uint32Array(n); crypto.getRandomValues(buf);
  return Array.from(buf, (x) => abc[x % abc.length]).join('');
}
const oldRoom = store.get('bna.room'); // 지난번 방은 시작할 때 서버에서 지움
const room = randomId(24);
store.set('bna.room', room);
let roomName = store.get('bna.roomName') || '상담실 1';

// ---- 앱과 같은 선택지 ----
const SHADES = [
  { id: 'BL1', name: '최대 미백', color: '#F7F5EE' },
  { id: 'A1', name: '밝은 자연색', color: '#F0E6D0' },
  { id: 'A2', name: '일반 자연색', color: '#E8D9B9' },
  { id: 'B1', name: '맑은 톤', color: '#F3ECDA' },
];
const SHADE_COLOR = Object.fromEntries(SHADES.map((s) => [s.id, s.color]));
const ENGINES = [
  { id: 'a', tag: '옵션 A', label: 'FLUX + 나노바나나 2.1', desc: '가성비 마무리', fin: '나노바나나 2.1' },
  { id: 'b', tag: '옵션 B', label: 'FLUX + 나노바나나 Pro', desc: '최고 화질 마무리', fin: '나노바나나 Pro' },
  { id: 'c', tag: '옵션 C', label: 'FLUX + Vertex AI', desc: '무료 크레딧 활용 마무리', fin: 'Vertex AI Imagen' },
  { id: 'solo', tag: '교정·단독', label: '나노바나나 단독', desc: '1단계 없이 기존 방식', fin: '나노바나나 2.1' },
];
const TREATMENTS = ['라미네이트', '무삭제 라미네이트', '미백', '교정', '잇몸 성형', '올세라믹 크라운', '임플란트'];
const UPPER = [18, 17, 16, 15, 14, 13, 12, 11, 21, 22, 23, 24, 25, 26, 27, 28];
const LOWER = [48, 47, 46, 45, 44, 43, 42, 41, 31, 32, 33, 34, 35, 36, 37, 38];
const UPPER6 = [13, 12, 11, 21, 22, 23], LOWER6 = [43, 42, 41, 31, 32, 33];
const sortTeeth = (l) => [...l].sort((a, b) => [...UPPER, ...LOWER].indexOf(a) - [...UPPER, ...LOWER].indexOf(b));
function teethSummary(list) {
  const has = (g) => g.every((t) => list.includes(t));
  if (list.length === 6 && has(UPPER6)) return '상악 앞니 6개';
  if (list.length === 6 && has(LOWER6)) return '하악 앞니 6개';
  if (list.length === 12 && has(UPPER6) && has(LOWER6)) return '상·하악 앞니 12개';
  return list.length <= 4 ? list.map((t) => '#' + t).join(' ') : `#${list[0]} 외 ${list.length - 1}개`;
}

// ---- 화면 전환 ----
const screens = ['pairScreen', 'standbyScreen', 'workScreen', 'errorScreen'];
function show(id) { screens.forEach((s) => ($('#' + s).hidden = s !== id)); }
function status(on, text) { $('#status').className = 'status' + (on ? ' on' : ''); $('#status span').textContent = text; }

let tabletOnline = false, forcePair = false, wasPaired = false;
let state = null, images = null, shownImgVer = null;
let localView = null, lastTabletView = null;     // PC 에서 고른 보기 방식 (태블릿이 바꾸면 다시 따라감)
let pos = 0.5, localPosUntil = 0;                // PC 에서 움직인 직후엔 태블릿 값으로 덮지 않음
let memoDirtyUntil = 0, nameDirtyUntil = 0, reqDirtyUntil = 0, strengthDirtyUntil = 0;
let panelOn = store.get('bna.panel') !== '0';
let db = null;

function standby(title, html) {
  show('standbyScreen');
  $('#standbyTitle').textContent = title;
  $('#standbyText').innerHTML = html;
}

// ---- PC → 태블릿 명령 ----
let ackWaitSince = 0, lastAck = null;
function cmd(t, v) {
  if (!db) return;
  if (!ackWaitSince) ackWaitSince = Date.now();
  window.__cmdSent = (window.__cmdSent || 0) + 1;
  push(ref(db, 'rooms/' + room + '/cmds'), { t, v: v === undefined ? null : v, at: serverTimestamp() })
    .then(() => { window.__cmdOk = (window.__cmdOk || 0) + 1; })
    .catch((e) => { console.warn('cmd 실패', t, e && e.message); });
}
const locked = () => !!(state && state.done);

function render() {
  // 태블릿이 연결돼 있지 않으면 항상 QR 화면
  if (forcePair || !tabletOnline) {
    show('pairScreen');
    $('#closePair').hidden = !tabletOnline;
    $('#pairLost').hidden = !(wasPaired && !tabletOnline);
    return;
  }
  if (!state) return standby('상담 화면 준비 중', '태블릿 앱 화면을 불러오는 중입니다…');
  show('workScreen');
  document.body.classList.toggle('no-panel', !panelOn);
  $('#panelBtn').setAttribute('aria-pressed', String(panelOn));

  showNotice(state.notice);
  renderSlots();
  const tabletView = state.view || 'edit';
  if (tabletView !== lastTabletView) { lastTabletView = tabletView; localView = null; }
  const items = Array.isArray(state.items) ? state.items.map(String) : ['원본'];
  const subs = Array.isArray(state.subs) ? state.subs.map(String) : []; // 태블릿 2026.11.27-a 이상: 불러온 사진 설명
  const cmp = Array.isArray(state.cmp) ? state.cmp.filter((n) => Number.isInteger(n) && n < items.length) : [0];
  const hasAfterShown = tabletView !== 'edit' && images && images.after;
  // one: 비교 목록에서 1장만 고름 → 그 사진만 크게
  const imgBehind = Number.isFinite(state.imgVer) && images && Number(images.ver) < state.imgVer;
  let view = tabletView === 'edit' ? 'edit'
    : cmp.length === 1 ? 'one'
      : !hasAfterShown ? 'edit' : (localView || tabletView);
  if (imgBehind && curView) view = curView; // 맞는 사진이 도착하기 전에는 보기 방식을 바꾸지 않음
  const smileV = !!(state.smile && state.smile.view);
  const lbl = (id, n) => { const el = $(id); if (!el) return; if (smileV) { el.querySelector('b').textContent = n ? '미소 미리보기' : '미소'; el.querySelector('span').textContent = n ? '시뮬레이션' : '치료 전'; el.classList.toggle('after', !!n); return; } el.querySelector('b').textContent = items[n] || '원본'; el.querySelector('span').textContent = subs[n] != null ? subs[n] : n ? '시뮬레이션' : '치료 전'; el.classList.toggle('after', !!n); };
  if (view === 'one') lbl('#lblSingle', cmp[0]); else { const e = $('#lblSingle'); e.querySelector('b').textContent = '원본'; e.querySelector('span').textContent = '치료 전'; e.classList.remove('after'); }
  if (cmp.length === 2) { lbl('#lblL', cmp[0]); lbl('#lblR', cmp[1]); lbl('#lblSB', cmp[0]); lbl('#lblSA', cmp[1]); }
  $('#lblR').classList.remove('after'); $('#lblL').classList.toggle('after', !!cmp[0] && cmp.length === 2);
  renderPicker(items, cmp, true); // 브리핑이 아닐 때·변환 전에도 왼쪽 목록 (불러온 사진 확인)
  curView = view;

  // 사진 (다른 환자 사진이면 확대 초기화)
  if (state.photoId !== lastPhotoId) { lastPhotoId = state.photoId; Z.s = 1; Z.x = 0; Z.y = 0; }
  const haveBefore = images && images.before;
  if (images && images.ver !== shownImgVer) {
    shownImgVer = images.ver;
    const b = images.before ? 'data:image/jpeg;base64,' + images.before : '';
    const a = images.after ? 'data:image/jpeg;base64,' + images.after : '';
    $('#singleImg').src = b; $('#beforeImg').src = b; $('#stackBefore').src = b;
    if (a) { $('#afterImg').src = a; $('#stackAfter').src = a; }
  }
  const contain = state.fit === 'contain';
  $('#stage').classList.toggle('contain', contain); $('#stack').classList.toggle('contain', contain);
  $('#single').hidden = view !== 'edit' && view !== 'one';
  $('#stage').hidden = view !== 'slider';
  $('#stack').hidden = view !== 'stack';
  $('#viewSeg').hidden = view === 'edit' || view === 'one';
  $('#vStack').setAttribute('aria-pressed', String(view === 'stack'));
  $('#vSlider').setAttribute('aria-pressed', String(view === 'slider'));
  const busy = !!state.converting;
  // 태블릿이 보낸 화면 정보보다 사진이 늦게 오면, 맞는 사진이 올 때까지 '불러오는 중'
  $('#loading').hidden = !(busy || !haveBefore || imgBehind);
  $('#loadingText').textContent = busy ? (state.convertMsg || 'After를 만드는 중…') : '사진을 불러오는 중…';

  // 서비컬 라인 (AI 사용 + 변환 전 화면)
  // 서비컬 라인·🪄 치아 고르기 체크 칸은 늘 보임 (체크하면 태블릿이 원본 화면으로)
  const guideOk = view === 'edit' && state.useAi;
  const guideShow = false; // v3.43: 서비컬 라인·🪄 치아 고르기 체크 칸 숨김 (사용자 요청)
  $('#guideCheck').hidden = !guideShow;
  $('#drawLines').checked = !!state.drawLines;
  $('#drawLines').disabled = locked();
  const drawing = guideOk && state.drawLines && !locked();
  $('#lineTools').hidden = !drawing;
  const n = Array.isArray(state.lines) ? state.lines.length : 0;
  const v6 = Number(state.v) >= 6;
  // 되돌리기: 새 앱은 '마지막 변경(그리기·지우개·다듬기·모두 지움) 취소'
  $('#lineUndo').disabled = v6 ? !state.lineUndo : n === 0;
  $('#lineClear').disabled = n === 0;
  $('#toolEraser').hidden = !v6; $('#lineSmooth').hidden = !v6;
  $('#toolEraser').disabled = n === 0 && tool !== 'eraser';
  $('#lineSmooth').disabled = n === 0;
  if (!v6 && tool === 'eraser') setTool('upper');
  const noPrep = Array.isArray(state.tx) && state.tx.includes('무삭제 라미네이트');
  $('#toolIncisal').hidden = !noPrep; $('#incisalAuto').hidden = !noPrep;
  $('#incisalAuto').disabled = !(Array.isArray(state.lines) && state.lines.some((l) => !l.i));
  if (!noPrep && tool === 'incisal') setTool('upper');
  // 🪄 자동 선택 (태블릿에 Fal.ai 키가 있을 때)
  const samShow = guideOk && !!state.samOn && !locked();
  $('#samCheck').hidden = !(guideShow && !!state.samOn && !locked());
  $('#samTools').hidden = !samShow || !$('#samOnChk').checked;
  if ((!samShow || !$('#samOnChk').checked) && samMode) setSamMode(false);
  $('#samUndo').disabled = !state.samUndo;
  $('#samClear').disabled = !(state.sam > 0);
  $('#samN').textContent = state.samBusy ? '🪄 찾는 중…' : state.sam > 0 ? `치아 ${state.sam}개` : '';
  if (!samShow && markMode) setMarkMode(false);
  $('#samMarkTool').disabled = !(Array.isArray(state.marks) && state.marks.length);
  $('#single').classList.toggle('drawing', drawing || (samShow && (samMode || markMode)));
  $('#single').classList.toggle('sam-mode', samShow && samMode);
  $('#single').classList.toggle('mark-mode', samShow && markMode);
  renderRz(view);
  renderSmile(view);
  const nLines = Array.isArray(state.lines) ? state.lines.length : 0;
  $('#guideHint').textContent = drawing
    ? `[상악선]/[하악선]을 고르고 마우스로 잇몸선을 따라 그리세요${nLines ? ` · 그린 선 ${nLines}개` : ''}`
    : '체크하면 사진 위에 마우스로 상악·하악 잇몸선을 그릴 수 있어요';
  applyZoom();
  // 태블릿 앱이 예전 버전이면 PC 조작이 전달되지 않음 → 안내
  const old = !(Number(state.v) >= 4);
  $('#oldBanner').hidden = !old;
  $('#panel').classList.toggle('old', old);
  $('#appVer').textContent = '태블릿 앱 버전: ' + (state.appVer || '예전 버전 (새 APK 설치 필요)');
  if (state.ack !== lastAck) { lastAck = state.ack; ackWaitSince = 0; }
  $('#ackBanner').hidden = !(ackWaitSince && Date.now() - ackWaitSince > 4000 && !old);

  $('#hint').textContent = view === 'slider'
    ? '마우스로 손잡이를 끌거나 키보드 ← → 키로 움직일 수 있어요 (Shift+← → 크게) · 태블릿 화면도 함께 움직입니다'
    + ' · 확대: 마우스 휠 / 이동: 오른쪽 버튼 끌기'
    : view === 'stack' ? '[겹쳐 보기 (손잡이)]를 누르면 마우스·키보드로 Before/After를 비교할 수 있어요 · 확대: 마우스 휠 / 이동: 끌기'
      : '오른쪽 패널에서 치료 부위·셰이드를 고르고 [After 변환하기]를 누르면 태블릿에서 변환됩니다 · 확대: 마우스 휠 / 이동: '
        + ($('#single').classList.contains('drawing') ? '오른쪽 버튼 끌기' : '끌기');
  if (Date.now() > localPosUntil) pos = Math.min(1, Math.max(0, Number(state.pos) || 0.5));
  applyPos();

  const teeth = Array.isArray(state.teeth) ? state.teeth.filter((t) => Number.isInteger(t)) : [];
  const tx = Array.isArray(state.tx) ? state.tx.map(String) : [];
  const shade = SHADE_COLOR[state.shade] ? state.shade : null;
  $('#info').innerHTML = `<b>${state.name ? esc(state.name) + ' 님' : '환자'}</b>`
    + tx.map((t) => `<span class="pill">${esc(t)}</span>`).join('')
    + (teeth.length ? `<span class="pill">${esc(teethSummary(teeth))}</span>` : '')
    + (shade ? `<span class="pill"><i class="sw" style="background:${SHADE_COLOR[shade]}"></i>셰이드 ${shade}</span>` : '');

  // 상담 메모: PC 에서 입력 중이 아닐 때만 태블릿 내용으로 맞춤
  syncText($('#memo'), state.memo, memoDirtyUntil);
  $('#memo').disabled = locked();
  renderPanel(teeth, tx, view);
}

function syncText(el, incoming, dirtyUntil) {
  const v = typeof incoming === 'string' ? incoming : '';
  if (document.activeElement !== el && Date.now() > dirtyUntil && el.value !== v) el.value = v;
}

// ---- 비교 사진 목록 (원본 + 1번, 2번 …) ----
let pickKey = '';
function renderPicker(items, cmp, on) {
  $('#picker').hidden = !on;
  if (!on) return;
  const thumbs = images && Array.isArray(images.thumbs) ? images.thumbs : [];
  const key = items.join('|') + '#' + (images ? images.ver : '') + '#' + cmp.join(',') + '#' + locked();
  if (key === pickKey) return;
  pickKey = key;
  $('#pickList').innerHTML = items.map((label, n) => {
    const sel = cmp.includes(n);
    const src = thumbs[n] ? 'data:image/jpeg;base64,' + thumbs[n] : '';
    return `<button type="button" class="pick${sel ? ' on' : ''}" data-n="${n}" aria-pressed="${sel}">`
      + (src ? `<img src="${src}" alt="">` : '<i class="noimg"></i>')
      + `<span><b>${sel ? '☑' : '☐'}</b> ${esc(label)}</span>`
      + (n > 0 ? `<i class="pick-del" data-del="${n}" title="목록에서 빼기">✕</i>` : '')
      + '</button>'; // v3.44: 사진 왼쪽 위 ①②(원본 1·2로 넣기) 버튼 없앰 (사용자 요청, 원본 카드 📷·📁 로 대신)
  }).join('');
}
$('#pickList').addEventListener('click', (e) => {
  const del = e.target.closest('[data-del]');
  if (del) { cmd('cmpRemove', Number(del.dataset.del)); return; } // ✕ 목록에서 빼기
  const b = e.target.closest('.pick'); if (!b) return;
  cmd('cmpToggle', Number(b.dataset.n));
});

// ---- 오른쪽 조작 패널 ----
function renderPanel(teeth, tx, view) {
  const lk = locked(), busy = !!state.converting;
  $('#doneBanner').hidden = !lk;
  $('#panel').classList.toggle('locked', lk);
  syncText($('#pname'), state.name, nameDirtyUntil);
  $('#pname').disabled = lk;
  $('#txChips').querySelectorAll('button').forEach((b) => {
    b.setAttribute('aria-pressed', String(tx.includes(b.dataset.v))); b.disabled = lk;
  });
  document.querySelectorAll('.arch button').forEach((b) => {
    b.setAttribute('aria-pressed', String(teeth.includes(Number(b.dataset.t)))); b.disabled = lk;
  });
  document.querySelectorAll('[data-group], #clearTeeth').forEach((b) => (b.disabled = lk));
  $('#shadeChips').querySelectorAll('button').forEach((b) => {
    b.setAttribute('aria-pressed', String(state.shade === b.dataset.v)); b.disabled = lk;
  });
  // AI
  $('#useAi').checked = !!state.useAi;
  $('#useAi').disabled = lk || !state.aiReady;
  $('#aiNote').textContent = !state.aiReady ? 'AI 연결 준비 안 됨 · 기본 미백 방식 사용 (태블릿 AI 설정 확인)'
    : state.useAi ? '아래에서 엔진을 하나 고르세요 · 같은 사진으로 옵션을 바꿔 가며 비교할 수 있어요' : '꺼짐 · 기본 미백 방식(색만 변경)';
  $('#aiReqBox').hidden = !state.useAi;
  syncText($('#aiReq'), state.aiReq, reqDirtyUntil);
  $('#aiReq').disabled = lk;
  $('#aiDefault').hidden = !!state.aiReqDefault || lk;
  // 자동 임상 지시: 태블릿이 계산한 그대로 표시 (같은 엔진)
  $('#aiAuto').textContent = String(state.aiAuto || '').split('\n').filter(Boolean).map((l) => '＋ ' + l).join('\n');
  $('#aiPrompt').textContent = String(state.aiPrompt || '');
  // 강도
  if (Date.now() > strengthDirtyUntil && Number.isFinite(state.strength)) $('#strength').value = state.strength;
  $('#strengthVal').textContent = $('#strength').value + '%';
  $('#strength').disabled = lk;
  // 사진 이동
  $('#undoBtn').hidden = !state.undo;
  $('#undoBtn').textContent = state.undo ? `↶ 이전으로 (${state.undo} 취소)` : '↶ 이전으로';
  $('#undoBtn').disabled = busy;
  $('#redoBtn').hidden = !state.redo;
  $('#redoBtn').textContent = state.redo ? `↷ 다시 돌아가기 (${state.redo})` : '↷ 다시 돌아가기';
  $('#redoBtn').disabled = busy;
  $('#beforeBtn').hidden = !(state.hasAfter && view !== 'edit');
  $('#afterBtn').hidden = !(state.hasAfter && view === 'edit');
  $('#briefing').checked = !!state.briefing;
  // 변환 엔진 (태블릿 앱 v7 이상)
  const engOn = !!state.useAi && 'engine' in state;
  $('#engineBox').hidden = !engOn;
  if (engOn) {
    $('#engines').querySelectorAll('button').forEach((b) => {
      const e = ENGINES.find((x) => x.id === b.dataset.v);
      const needKey = (e.id !== 'solo' && !state.falReady) || (e.id === 'c' && !state.vertexReady);
      b.setAttribute('aria-pressed', String(state.engine === e.id));
      b.querySelector('small').textContent = needKey ? `${e.desc} · 키 필요` : e.desc;
      b.disabled = lk || busy;
    });
    const eff = ENGINES.find((x) => x.id === state.engineEff);
    $('#engineNote').textContent = state.engineNote ? '⚠ ' + state.engineNote
      : eff && eff.id !== 'solo' ? `1단계 FLUX(마진·형태 고정) → 2단계 ${eff.fin}(리얼리즘 마무리)` : '';
    $('#engineNote').classList.toggle('warn', !!state.engineNote);
  }
  // 변환 버튼
  const cb = $('#convertBtn');
  cb.disabled = lk || busy;
  cb.classList.toggle('busy', busy);
  // 🔁 기준 사진 고르기 (태블릿 2026.11.27-f 이상: state.bases) — 예전 태블릿이면 예전 안내 글
  const bases = Array.isArray(state.bases) ? state.bases : null;
  $('#basePickBox').hidden = !bases;
  $('#convertBase').hidden = !!bases;
  if (bases) {
    const sel = $('#baseSel');
    const key = JSON.stringify(bases);
    if (sel.dataset.key !== key) {
      sel.dataset.key = key;
      sel.innerHTML = bases.map((b) => `<option value="${b.k}:${b.n}">${esc(b.l)}</option>`).join('');
    }
    if (document.activeElement !== sel) sel.value = state.baseNow || '';
    sel.disabled = lk || busy;
  } else {
    $('#convertBase').textContent = state.base ? `🔁 기준 사진: ${state.base} → 이 결과를 다듬어요 (원본으로 하려면 비교 목록에서 원본 클릭)` : '기준 사진: 원본 · 브리핑 비교 목록에서 변환 결과를 클릭하면 그 결과를 기준으로 다시 변환해요';
    $('#convertBase').classList.toggle('on', !!state.base);
  }
  // 지금 엔진 한 줄 (바꾸기는 ⚙ 고급)
  const ENG = { a: '옵션 A · FLUX + 나노바나나 2.1', b: '옵션 B · FLUX + 나노바나나 Pro', c: '옵션 C · FLUX + Vertex AI', solo: '교정·단독 · 나노바나나 단독' };
  $('#engineNow').textContent = !state.useAi ? '엔진: AI 꺼짐 (기본 미백 방식) · 켜기는 ⚙ 고급' : `엔진: ${ENG[state.engineEff || state.engine] || '-'}${state.engineNote ? ' · ' + state.engineNote : ''} · 바꾸기는 ⚙ 고급`;
  // 💾 저장 버튼 · PC 폴더 저장 상태
  $('#saveBtn').disabled = !state.hasAfter || locked() || !!state.converting;
  $('#saveBtn').textContent = locked() ? '✓ 저장·상담 완료됨' : '💾 저장 및 상담 완료';
  if (!/저장하는 중/.test($('#saveNote').textContent) || locked()) {
    $('#saveNote').innerHTML = locked() ? '환자 기록에 저장됐어요' + (pcDirState === 'on' ? ` · 💾 PC 폴더(${esc(pcDir.name)})에도 저장` : '')
      : pcDirState === 'on' ? `💾 저장하면 PC 폴더(${esc(pcDir.name)})에도 자동 저장돼요`
        : '⚠ PC 폴더 저장이 꺼져 있어요 · <a href="#" id="savePick">📁 PC 저장 폴더 고르기</a>';
  }
  // 👁 눈 가리기 (태블릿 2026.11.27-a 이상)
  const eye = state.eye;
  $('#eyeRow').hidden = !eye || !eye.ok;
  if (eye) { $('#eyeMask').checked = !!eye.on; $('#eyeMask').disabled = locked(); }
  // 😊 원본 2장 (태블릿 2026.11.27-a 이상)
  const sr = state.smileRef;
  $('#smRef').hidden = !sr || locked();
  if (sr) {
    $('#smRefNone').hidden = !!sr.has; $('#smRefHas').hidden = !sr.has;
    $('#smRefOn').checked = !!sr.on && !!state.useAi; $('#smRefOn').disabled = !state.useAi;
    $('#smRefAuto').checked = !!sr.auto;
  }
  cb.textContent = busy ? '⏳ 태블릿에서 변환 중…' : state.hasAfter && state.stale ? '🔄 바뀐 설정으로 다시 변환' : state.hasAfter ? '✨ 다시 변환하기' : '✨ After 변환하기';
  $('#convertNote').textContent = lk ? '' : !state.useAi && !teeth.length ? '기본 방식은 치료 부위를 먼저 골라 주세요'
    : !state.useAi && !state.shade ? '기본 방식은 희망 셰이드를 골라 주세요' : state.hasAfter && state.stale ? '설정이 바뀌었어요 · 다시 변환하면 반영됩니다' : '';
}

const pendingFlush = [];
(function buildPanel() {
  $('#txChips').innerHTML = TREATMENTS.map((t) => `<button type="button" class="chipbtn" data-v="${esc(t)}" aria-pressed="false">${esc(t)}</button>`).join('');
  const arch = (list) => list.map((t, i) => `${i === 8 ? '<i class="mid"></i>' : ''}<button type="button" data-t="${t}" aria-pressed="false" title="${t}번">${t}</button>`).join('');
  $('#upperArch').innerHTML = '<span class="arch-l">상악</span>' + arch(UPPER);
  $('#lowerArch').innerHTML = '<span class="arch-l">하악</span>' + arch(LOWER);
  $('#shadeChips').innerHTML = SHADES.map((s) => `<button type="button" class="chipbtn shade" data-v="${s.id}" aria-pressed="false"><i class="sw" style="background:${s.color}"></i><b>${s.id}</b> <small>${esc(s.name)}</small></button>`).join('');

  $('#txChips').addEventListener('click', (e) => { const b = e.target.closest('button'); if (b && !locked()) cmd('tx', b.dataset.v); });
  document.querySelectorAll('.arch').forEach((a) => a.addEventListener('click', (e) => {
    const b = e.target.closest('button'); if (b && !locked()) cmd('tooth', Number(b.dataset.t));
  }));
  document.querySelectorAll('[data-group]').forEach((b) => b.addEventListener('click', () => cmd('group', b.dataset.group.split(',').map(Number))));
  $('#clearTeeth').addEventListener('click', () => cmd('clearTeeth'));
  // 셰이드: 선택된 칩을 한 번 더 누르면 해제 (null)
  $('#shadeChips').addEventListener('click', (e) => {
    const b = e.target.closest('button'); if (!b || locked()) return;
    const id = b.dataset.v;
    if (Number(state && state.v) >= 4) cmd('shadeToggle', id); // 태블릿이 순서대로 판단 (빠른 연속 클릭도 정확)
    else cmd('shade', state && state.shade === id ? null : id); // 예전 태블릿 앱
    // 태블릿 응답 전에도 화면에 바로 반영
    if (state) { state.shade = state.shade === id ? null : id; render(); }
  });
  $('#useAi').addEventListener('change', (e) => cmd('useAi', e.target.checked));
  $('#aiDefault').addEventListener('click', () => { reqDirtyUntil = 0; cmd('aiReqDefault'); });
  $('#strength').addEventListener('input', (e) => { strengthDirtyUntil = Date.now() + 1500; $('#strengthVal').textContent = e.target.value + '%'; });
  $('#strength').addEventListener('change', (e) => { strengthDirtyUntil = Date.now() + 1500; cmd('strength', Number(e.target.value)); });
  // 입력 중이던 이름·요청 내용을 먼저 보낸 뒤 변환 (순서 보장)
  $('#engines').innerHTML = ENGINES.map((e) => `<button type="button" class="engine" data-v="${e.id}" aria-pressed="false"><b>${e.tag} · ${esc(e.label)}</b><small>${esc(e.desc)}</small></button>`).join('');
  $('#engines').addEventListener('click', (ev) => {
    const b = ev.target.closest('button'); if (!b || locked()) return;
    cmd('engine', b.dataset.v); state.engine = b.dataset.v; render();
  });
  $('#smRefOn').addEventListener('change', (e) => cmd('smileRef', e.target.checked));
  $('#smRefAuto').addEventListener('change', (e) => cmd('autoMatch', e.target.checked));
  $('#smRefAdd').addEventListener('click', () => $('#smOpen').click());
  // 💾 저장 및 상담 완료 (PC 에서도) → 태블릿이 환자 기록에 저장 → PC 폴더 자동 저장
  $('#saveBtn').addEventListener('click', () => {
    if (!state) return;
    const who = (state.name || '').trim();
    if (!who) { $('#saveNote').textContent = '⚠ 환자 이름을 먼저 입력해 주세요'; return; }
    const pc = pcDirState === 'on' ? `\n💾 PC 폴더(${pcDir.name})에도 자동 저장됩니다.` : '\n⚠ PC 폴더 저장이 꺼져 있어요 (태블릿에만 저장).';
    if (!confirm(`${who} 님 시뮬레이션 결과를 저장하고 상담을 완료할까요?${pc}`)) return;
    pendingFlush.forEach((f) => f());
    cmd('confirmSave');
    $('#saveNote').textContent = '💾 저장하는 중…';
  });
  $('#convertBtn').addEventListener('click', () => { pendingFlush.forEach((f) => f()); cmd('convert'); });
  $('#undoBtn').addEventListener('click', () => cmd('undo'));
  $('#redoBtn').addEventListener('click', () => cmd('redo'));
  $('#beforeBtn').addEventListener('click', () => cmd('before'));
  $('#afterBtn').addEventListener('click', () => cmd('after'));
  $('#briefing').addEventListener('change', (e) => {
    const on = e.target.checked;
    cmd('briefing', on);
    // 손잡이와 같은 통로로도 보냄 (태블릿이 어느 쪽으로든 받으면 켜짐/꺼짐)
    if (db) update(ref(db, 'rooms/' + room + '/control'), { briefing: on, briefingAt: serverTimestamp() }).catch(() => {});
  });
  $('#drawLines').addEventListener('change', (e) => cmd('drawLines', e.target.checked));
  // 🪄 체크하면 아래에 자동 선택 도구 + 바로 치아 클릭 모드
  $('#samOnChk').addEventListener('change', (e) => {
    if (e.target.checked && state && state.view !== 'edit') cmd('before'); // 원본 화면으로
    setSamMode(e.target.checked); render();
  });

  // 글자 입력: 잠깐 멈추면 태블릿에 반영
  const typed = (el, t, setDirty) => {
    let timer = null;
    const send = () => { clearTimeout(timer); timer = null; cmd(t, el.value.slice(0, 2000)); };
    el.addEventListener('input', () => {
      setDirty(Date.now() + 2000);
      clearTimeout(timer);
      timer = setTimeout(send, 400);
    });
    pendingFlush.push(() => { if (timer) send(); });
  };
  typed($('#pname'), 'name', (v) => (nameDirtyUntil = v));
  typed($('#aiReq'), 'aiReq', (v) => (reqDirtyUntil = v));

})();

// ---- 서비컬 라인 그리기 (마우스·펜) ----
let tool = 'upper', live = null, curView = 'edit';
function imgRect() {
  // 사진이 실제로 보이는 영역 (object-fit: contain)
  const im = $('#singleImg'), box = $('#single').getBoundingClientRect();
  const iw = im.naturalWidth || 1, ih = im.naturalHeight || 1;
  const k = Math.min(box.width / iw, box.height / ih);
  const w = iw * k, h = ih * k;
  return { x: (box.width - w) / 2, y: (box.height - h) / 2, w, h, box };
}
function drawLines() {
  const cv = $('#lineCanvas'); if ($('#single').hidden) return;
  const r = imgRect(), dpr = (window.devicePixelRatio || 1) * Math.min(Z.s, 3); // 확대해도 선이 선명하게
  if (cv.width !== Math.round(r.box.width * dpr) || cv.height !== Math.round(r.box.height * dpr)) {
    cv.width = Math.round(r.box.width * dpr); cv.height = Math.round(r.box.height * dpr);
  }
  const g = cv.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, r.box.width, r.box.height);
  if (state && state.useAi && curView === 'edit' && samImg && samImg.complete && state.sam > 0) {
    g.drawImage(samImg, r.x, r.y, r.w, r.h); // 🪄 고른 치아 하이라이트
  }
  if (state && state.useAi && curView === 'edit' && (samMode || markMode) && Array.isArray(state.marks)) {
    // 📍 기준점: 초록 = 잇몸 꼭대기, 노랑 = 절단끝
    state.marks.forEach((m, n) => {
      const pts = [[m.z, '#00C853', false], [m.i, '#FFC400', true]];
      const md = markDrag && markDrag.n === n ? markDrag : null;
      const at = (p, inc) => (md && md.inc === inc ? md.p : p);
      const z = at(m.z, false), i = at(m.i, true);
      g.strokeStyle = 'rgba(255,255,255,.8)'; g.lineWidth = 1.2 / Z.s;
      g.beginPath(); g.moveTo(r.x + z[0] * r.w, r.y + z[1] * r.h); g.lineTo(r.x + i[0] * r.w, r.y + i[1] * r.h); g.stroke();
      for (const [p0, c, inc] of pts) {
        const p = at(p0, inc);
        g.beginPath(); g.arc(r.x + p[0] * r.w, r.y + p[1] * r.h, 7 / Z.s, 0, Math.PI * 2); g.fillStyle = 'rgba(0,0,0,.65)'; g.fill();
        g.beginPath(); g.arc(r.x + p[0] * r.w, r.y + p[1] * r.h, 5.5 / Z.s, 0, Math.PI * 2); g.fillStyle = c; g.fill();
      }
      g.font = `800 ${12 / Z.s}px sans-serif`; g.fillStyle = '#fff'; g.textAlign = 'center';
      g.shadowColor = 'rgba(0,0,0,.8)'; g.shadowBlur = 3;
      g.fillText(m.l || '', r.x + z[0] * r.w, r.y + z[1] * r.h - 12 / Z.s); g.shadowBlur = 0;
    });
  }
  if (!state || !state.useAi || !state.drawLines || curView !== 'edit') return; // 선은 원본 화면에서만
  let lines = (Array.isArray(state.lines) ? state.lines : []).map((l) => ({ u: !!l.u, i: !!l.i, p: Array.isArray(l.p) ? l.p : [] }));
  if (erasePath) {
    const im = $('#singleImg');
    lines = eraseLines(lines, erasePath.p, erasePath.r, (im.naturalHeight || 3) / (im.naturalWidth || 4)); // 지우는 중 미리보기
  }
  if (live) lines.push(live);
  g.lineCap = 'round'; g.lineJoin = 'round';
  for (const l of lines) {
    if (l.p.length < 4) continue;
    g.beginPath();
    for (let i = 0; i + 1 < l.p.length; i += 2) {
      const x = r.x + l.p[i] * r.w, y = r.y + l.p[i + 1] * r.h;
      i ? g.lineTo(x, y) : g.moveTo(x, y);
    }
    g.strokeStyle = 'rgba(0,0,0,.6)'; g.lineWidth = 2.6 / Z.s; g.stroke();
    g.strokeStyle = l.i ? '#FFC400' : l.u ? '#00C853' : '#FF2D95'; g.lineWidth = 1.4 / Z.s; g.stroke();
  }
  if (erasePath && erasePath.p.length >= 2) { // 지우개 동그라미
    const n = erasePath.p.length;
    g.beginPath();
    g.arc(r.x + erasePath.p[n - 2] * r.w, r.y + erasePath.p[n - 1] * r.h, eraserPx / Z.s, 0, Math.PI * 2);
    g.fillStyle = 'rgba(255,255,255,.25)'; g.fill();
    g.strokeStyle = '#fff'; g.lineWidth = 1.5 / Z.s; g.stroke();
  }
}
// 지우개: 지나간 길 근처의 선 부분만 지움 (태블릿과 같은 계산 → 미리보기용)
function eraseLines(lines, path, r, aspect) {
  const dist = (ax, ay, bx, by) => Math.hypot(ax - bx, (ay - by) * aspect);
  const toSeg = (px, py, ax, ay, bx, by) => {
    const vx = bx - ax, vy = (by - ay) * aspect, wx = px - ax, wy = (py - ay) * aspect;
    const l2 = vx * vx + vy * vy, t = l2 ? Math.max(0, Math.min(1, (wx * vx + wy * vy) / l2)) : 0;
    return Math.hypot(ax + vx * t - px, (ay * aspect + vy * t) - py * aspect);
  };
  // 지우개 길: 점 1개면 그 자리, 여러 개면 이웃한 점끼리 선분
  const segs = [];
  if (path.length === 2) segs.push([path[0], path[1], path[0], path[1]]);
  for (let i = 2; i + 1 < path.length; i += 2) segs.push([path[i - 2], path[i - 1], path[i], path[i + 1]]);
  const hit = (x, y) => segs.some((g) => toSeg(x, y, g[0], g[1], g[2], g[3]) <= r);
  const out = [];
  for (const l of lines) {
    const p = l.p, dense = [];
    for (let i = 0; i + 1 < p.length; i += 2) {
      if (i === 0) { dense.push([p[0], p[1]]); continue; }
      const ax = p[i - 2], ay = p[i - 1], bx = p[i], by = p[i + 1];
      const k = Math.max(1, Math.ceil(dist(ax, ay, bx, by) / (r / 3)));
      for (let j = 1; j <= k; j++) dense.push([ax + (bx - ax) * j / k, ay + (by - ay) * j / k]);
    }
    if (!dense.some(([x, y]) => hit(x, y))) { out.push(l); continue; }
    let cur = [];
    const flush = () => { if (cur.length > 1) out.push({ u: l.u, i: l.i, p: cur.flat() }); cur = []; };
    for (const [x, y] of dense) { if (hit(x, y)) flush(); else cur.push([x, y]); }
    flush();
  }
  return out;
}
let erasePath = null;
const eraserPx = 14;
let samMode = false, samImg = null, samDown = null, markMode = false, markDrag = null;
function setSamMode(on) {
  samMode = on;
  if (on) markMode = false;
  $('#samTool').setAttribute('aria-pressed', String(on));
  $('#samMarkTool').setAttribute('aria-pressed', String(markMode));
  if (state) render();
  drawLines();
}
function setMarkMode(on) {
  markMode = on;
  if (on) samMode = false;
  $('#samTool').setAttribute('aria-pressed', String(samMode));
  $('#samMarkTool').setAttribute('aria-pressed', String(on));
  if (state) render();
  drawLines();
}
const setTool = (t) => {
  tool = t;
  if (samMode) setSamMode(false);
  if (markMode) setMarkMode(false);
  $('#toolUpper').setAttribute('aria-pressed', String(t === 'upper'));
  $('#toolLower').setAttribute('aria-pressed', String(t === 'lower'));
  $('#toolEraser').setAttribute('aria-pressed', String(t === 'eraser'));
  $('#toolIncisal').setAttribute('aria-pressed', String(t === 'incisal'));
  $('#single').classList.toggle('erasing', t === 'eraser');
};
(() => {
  const cv = $('#lineCanvas');
  const pt = (e) => {
    const r = imgRect(), b = cv.getBoundingClientRect(); // b 는 확대된 크기 → 배율로 나눔
    const x = ((e.clientX - b.left) / Z.s - r.x) / r.w, y = ((e.clientY - b.top) / Z.s - r.y) / r.h;
    return [Math.round(Math.min(1, Math.max(0, x)) * 1000) / 1000, Math.round(Math.min(1, Math.max(0, y)) * 1000) / 1000];
  };
  const aspect = () => { const im = $('#singleImg'); return (im.naturalHeight || 3) / (im.naturalWidth || 4); };
  const eraserR = () => eraserPx / (imgRect().w * Z.s); // 화면 14px → 사진 가로 기준 비율
  cv.addEventListener('pointerdown', (e) => {
    if (!$('#single').classList.contains('drawing') || e.button !== 0) return;
    if (samMode) { samDown = { id: e.pointerId, p: pt(e), x: e.clientX, y: e.clientY }; e.preventDefault(); return; }
    if (markMode) {
      // 가장 가까운 기준점 (화면 16px 안)
      const r = imgRect(), b = cv.getBoundingClientRect(), [px, py] = pt(e);
      let best = null, bd = 16;
      (state.marks || []).forEach((m, n) => [[m.z, false], [m.i, true]].forEach(([p, inc]) => {
        const d = Math.hypot((p[0] - px) * r.w * Z.s, (p[1] - py) * r.h * Z.s);
        if (d < bd) { bd = d; best = { n, inc, p: [p[0], p[1]], id: e.pointerId }; }
      }));
      if (best) { markDrag = best; cv.setPointerCapture(e.pointerId); }
      e.preventDefault(); return;
    }
    cv.setPointerCapture(e.pointerId);
    if (tool === 'eraser') erasePath = { id: e.pointerId, p: pt(e), r: eraserR() };
    else live = { u: tool !== 'lower', i: tool === 'incisal', p: pt(e), id: e.pointerId };
    e.preventDefault(); drawLines();
  });
  cv.addEventListener('pointermove', (e) => {
    if (markDrag && markDrag.id === e.pointerId) { markDrag.p = pt(e); drawLines(); return; }
    const cur = live || erasePath;
    if (!cur || cur.id !== e.pointerId) return;
    const [x, y] = pt(e), n = cur.p.length;
    if (Math.abs(x - cur.p[n - 2]) + Math.abs(y - cur.p[n - 1]) < 0.002) return;
    cur.p.push(x, y); drawLines();
  });
  const end = (e) => {
    if (markDrag && markDrag.id === e.pointerId) {
      const d = markDrag; markDrag = null;
      cmd('samMark', { n: d.n, inc: d.inc, x: d.p[0], y: d.p[1] });
      const m = state.marks && state.marks[d.n];
      if (m) m[d.inc ? 'i' : 'z'] = d.p; // 태블릿 응답 전에도 바로
      drawLines(); return;
    }
    if (samDown && samDown.id === e.pointerId) {
      const d = samDown; samDown = null;
      // 클릭(거의 안 움직임)만 선택으로 봄
      if (Math.abs(e.clientX - d.x) + Math.abs(e.clientY - d.y) < 8) cmd('samTap', { x: d.p[0], y: d.p[1] });
      return;
    }
    if (erasePath && erasePath.id === e.pointerId) {
      const er = erasePath; erasePath = null;
      const lines = Array.isArray(state.lines) ? state.lines : [];
      const next = eraseLines(lines, er.p, er.r, aspect());
      if (next.length !== lines.length || next.some((l, i) => l !== lines[i])) {
        cmd('lineErase', { p: er.p, r: Math.round(er.r * 10000) / 10000 });
        state.lines = next; state.lineUndo = true;
      }
      render(); return;
    }
    if (!live || live.id !== e.pointerId) return;
    const l = live; live = null;
    if (l.p.length >= 4) {
      const lines = (Array.isArray(state.lines) ? state.lines : []).map((x) => ({ u: x.u ? 1 : 0, ...(x.i ? { i: 1 } : {}), p: x.p }));
      const add = { u: l.u ? 1 : 0, ...(l.i ? { i: 1 } : {}), p: l.p };
      lines.push(add);
      // 새 태블릿 앱: 한 줄만 보냄 (태블릿이 순서대로 처리) / 예전 앱: 전체 목록
      if (Number(state.v) >= 5) cmd('lineAdd', add); else cmd('lines', lines);
      state.lines = lines; state.lineUndo = true; // 태블릿 응답 전에도 바로 보이게
    }
    render();
  };
  cv.addEventListener('pointerup', end); cv.addEventListener('pointercancel', end);
  $('#toolUpper').addEventListener('click', () => setTool('upper'));
  $('#toolLower').addEventListener('click', () => setTool('lower'));
  $('#toolEraser').addEventListener('click', () => setTool('eraser'));
  $('#toolIncisal').addEventListener('click', () => setTool('incisal'));
  $('#samTool').addEventListener('click', () => setSamMode(!samMode));
  $('#samMarkTool').addEventListener('click', () => setMarkMode(!markMode));
  $('#samUndo').addEventListener('click', () => cmd('samUndo'));
  $('#samClear').addEventListener('click', () => cmd('samClear'));
  $('#incisalAuto').addEventListener('click', () => cmd('incisalAuto'));
  // 되돌리기·모두 지움·다듬기: 전용 명령 (태블릿이 순서대로 처리, 빈 목록 문제 없음)
  const newApp = () => Number(state && state.v) >= 5;
  $('#lineUndo').addEventListener('click', () => {
    if (newApp()) { cmd('linesUndo'); return; } // 태블릿이 이전 상태를 알려 줌
    const lines = (Array.isArray(state.lines) ? state.lines : []).slice(0, -1);
    cmd('lines', lines); state.lines = lines; render();
  });
  $('#lineClear').addEventListener('click', () => {
    if (newApp()) cmd('linesClear'); else cmd('lines', []);
    state.lines = []; state.lineUndo = true; render();
  });
  $('#lineSmooth').addEventListener('click', () => cmd('linesSmooth'));
  new ResizeObserver(() => drawLines()).observe($('#single'));
  $('#singleImg').addEventListener('load', () => drawLines());
})();

// ---- 확대/축소 (마우스 휠, ＋/－ 버튼, 끌어서 이동) — 세 가지 보기에 같은 배율 적용 ----
const Z = { s: 1, x: 0, y: 0 }; // x, y: 화면 크기 대비 이동 비율
let lastPhotoId = null;
const MAXZ = 6, MINZ = 0.5;
const clampZ = () => {
  Z.s = Math.min(MAXZ, Math.max(MINZ, Z.s));
  if (Z.s <= 1) { Z.x = (1 - Z.s) / 2; Z.y = (1 - Z.s) / 2; return; } // 축소: 가운데
  Z.x = Math.min(0, Math.max(1 - Z.s, Z.x));
  Z.y = Math.min(0, Math.max(1 - Z.s, Z.y));
};
function applyZoom() {
  clampZ();
  document.querySelectorAll('.zw').forEach((el) => {
    const p = el.parentElement.getBoundingClientRect();
    el.style.transform = Z.s === 1 ? '' : `translate(${Z.x * p.width}px, ${Z.y * p.height}px) scale(${Z.s})`;
  });
  const zoomed = Z.s > 1.01, changed = Math.abs(Z.s - 1) > 0.01;
  $('#zLabel').hidden = !changed; $('#zLabel').textContent = Z.s.toFixed(1) + '배';
  $('#zOut').disabled = Z.s <= MINZ + 0.01; $('#zFit').disabled = !changed; $('#zIn').disabled = Z.s >= MAXZ;
  $('#single').classList.toggle('zoomed', zoomed); $('#stack').classList.toggle('zoomed', zoomed);
  drawLines();
}
function zoomAt(fx, fy, ns) { // fx, fy: 기준점 (0~1)
  ns = Math.min(MAXZ, Math.max(MINZ, ns));
  Z.x = fx - (fx - Z.x) * (ns / Z.s); Z.y = fy - (fy - Z.y) * (ns / Z.s); Z.s = ns;
  applyZoom();
}
(() => {
  const area = document.querySelector('.view-area');
  const boxOf = (t) => t.closest('.single, .stage, .pane') || area;
  const frac = (e, el) => { const r = el.getBoundingClientRect(); return [(e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height, r]; };
  area.addEventListener('wheel', (e) => {
    if (e.target.closest('.zoom-tools, .line-tools, .rz')) return;
    e.preventDefault();
    const [fx, fy] = frac(e, boxOf(e.target));
    zoomAt(fx, fy, Z.s * Math.exp(-e.deltaY / 500));
  }, { passive: false });
  $('#zIn').addEventListener('click', () => zoomAt(0.5, 0.5, Z.s * 1.5));
  $('#zOut').addEventListener('click', () => zoomAt(0.5, 0.5, Z.s / 1.5));
  $('#zFit').addEventListener('click', () => { Z.s = 1; Z.x = 0; Z.y = 0; applyZoom(); });
  // 끌어서 이동: 오른쪽 버튼(어디서나) / 왼쪽 버튼(선 그리기 중이 아닌 Before 화면, 위아래 보기)
  let pan = null;
  area.addEventListener('contextmenu', (e) => { if (!e.target.closest('.panel')) e.preventDefault(); });
  area.addEventListener('pointerdown', (e) => {
    if (e.target.closest('.zoom-tools, .line-tools, .rz')) return; // 크기 조절·미소 창은 자체 조작
    const box = boxOf(e.target);
    const leftPan = e.button === 0 && Z.s > 1.01 && ((box.id === 'single' && !box.classList.contains('drawing')) || box.classList.contains('pane'));
    if (e.button !== 2 && !leftPan) return;
    const [, , r] = frac(e, box);
    pan = { id: e.pointerId, x: e.clientX, y: e.clientY, zx: Z.x, zy: Z.y, w: r.width, h: r.height };
    area.setPointerCapture(e.pointerId); area.classList.add('panning');
    e.preventDefault(); e.stopPropagation();
  }, true);
  area.addEventListener('pointermove', (e) => {
    if (!pan || pan.id !== e.pointerId) return;
    Z.x = pan.zx + (e.clientX - pan.x) / pan.w; Z.y = pan.zy + (e.clientY - pan.y) / pan.h; applyZoom();
  });
  const endPan = (e) => { if (pan && pan.id === e.pointerId) { pan = null; area.classList.remove('panning'); } };
  area.addEventListener('pointerup', endPan); area.addEventListener('pointercancel', endPan);
  area.addEventListener('dblclick', (e) => {
    const box = boxOf(e.target);
    if (box.id === 'stage' || box.classList.contains('drawing') || e.target.closest('.zoom-tools, .line-tools')) return;
    const [fx, fy] = frac(e, box);
    if (Math.abs(Z.s - 1) > 0.05) { Z.s = 1; Z.x = 0; Z.y = 0; applyZoom(); } else zoomAt(fx, fy, 2.5);
  });
  new ResizeObserver(() => applyZoom()).observe(area);
})();

function applyPos() {
  const v = pos * 100;
  $('#beforeClip').style.clipPath = `inset(0 ${100 - v}% 0 0)`;
  $('#divider').style.left = v + '%';
  $('#lblL').style.opacity = v > 14 ? 1 : 0;
  $('#lblR').style.opacity = v < 86 ? 1 : 0;
  $('#stage').setAttribute('aria-valuenow', String(Math.round(v)));
}

// ---- 손잡이(마우스·키보드), 보기 방식, 상담 메모 → 태블릿에 반영 ----
let posTimer = null, memoTimer = null;
function sendPos() {
  if (posTimer || !db) return;
  posTimer = setTimeout(() => {
    posTimer = null;
    update(ref(db, 'rooms/' + room + '/control'), { pos: Math.round(pos * 1000) / 1000, posAt: serverTimestamp() }).catch(() => {});
  }, 90);
}
function setLocalPos(v) {
  pos = Math.min(1, Math.max(0, v));
  localPosUntil = Date.now() + 900;
  applyPos(); sendPos();
}
(() => {
  const stage = $('#stage');
  let drag = null;
  const fromEvent = (e) => { const r = stage.getBoundingClientRect(); setLocalPos((e.clientX - r.left) / r.width); };
  stage.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    drag = e.pointerId; stage.setPointerCapture(e.pointerId); stage.classList.add('dragging'); stage.focus(); fromEvent(e);
  });
  stage.addEventListener('pointermove', (e) => { if (e.pointerId === drag) fromEvent(e); });
  const end = (e) => { if (e.pointerId === drag) { drag = null; stage.classList.remove('dragging'); } };
  stage.addEventListener('pointerup', end); stage.addEventListener('pointercancel', end);
  document.addEventListener('keydown', (e) => {
    const tag = document.activeElement && document.activeElement.tagName;
    if (tag === 'TEXTAREA' || tag === 'INPUT' || $('#workScreen').hidden || $('#stage').hidden) return;
    const step = e.shiftKey ? 0.1 : 0.02;
    if (e.key === 'ArrowLeft') setLocalPos(pos - step);
    else if (e.key === 'ArrowRight') setLocalPos(pos + step);
    else if (e.key === 'Home') setLocalPos(0);
    else if (e.key === 'End') setLocalPos(1);
    else return;
    e.preventDefault();
  });
  $('#vStack').addEventListener('click', () => { localView = 'stack'; render(); });
  $('#vSlider').addEventListener('click', () => { localView = 'slider'; render(); $('#stage').focus(); });
  const memo = $('#memo');
  memo.addEventListener('input', () => {
    memoDirtyUntil = Date.now() + 2000;
    $('#memoSt').textContent = '입력 중…';
    clearTimeout(memoTimer);
    memoTimer = setTimeout(() => {
      if (!db) return;
      update(ref(db, 'rooms/' + room + '/control'), { memo: memo.value.slice(0, 2000), memoAt: serverTimestamp() })
        .then(() => { $('#memoSt').textContent = '✓ 태블릿에 저장됨'; })
        .catch(() => { $('#memoSt').textContent = '저장 실패 · 인터넷 확인'; });
    }, 400);
  });
})();

// ---- QR + 숫자 코드 (10분마다 새 코드) ----
let code = null, codeTimer = null, uid = null;
function drawQr() {
  const url = location.origin + location.pathname + '#pair-' + room;
  const box = $('#qr'); box.innerHTML = '';
  if (window.QRCode) new window.QRCode(box, { text: url, width: 262, height: 262, colorDark: '#0B2E5C', colorLight: '#ffffff', correctLevel: window.QRCode.CorrectLevel.M });
  else box.textContent = 'QR을 표시할 수 없습니다. 오른쪽 숫자를 입력해 주세요.';
}
async function newCode() {
  if (code) { try { await remove(ref(db, 'codes/' + code)); } catch (e) { /* 이미 만료 */ } }
  for (let i = 0; i < 8; i++) {
    const c = String(Math.floor(1000 + Math.random() * 9000));
    try {
      await set(ref(db, 'codes/' + c), { room, uid, exp: Date.now() + 10 * 60 * 1000 });
      code = c; $('#code').textContent = c; $('#codeExp').textContent = '10분마다 새 숫자로 바뀝니다';
      return;
    } catch (e) { /* 다른 PC 가 쓰는 숫자 → 다시 */ }
  }
  $('#code').textContent = '----';
}

// ---- 시작 ----
async function start() {
  $('#roomName').value = roomName;
  $('#pairRoom').textContent = roomName;
  $('#sub').textContent = roomName + ' · B&A 치과 시뮬레이터';
  drawQr();
  status(false, '서버 연결 중');
  try {
    const app = initializeApp(firebaseConfig);
    const cred = await signInAnonymously(getAuth(app));
    uid = cred.user.uid;
    db = getDatabase(app);
  } catch (e) {
    console.error(e);
    show('errorScreen');
    $('#errTitle').textContent = '서버에 연결할 수 없습니다';
    $('#errText').textContent = '인터넷 연결을 확인한 뒤 새로고침(F5) 해 주세요.';
    status(false, '연결 실패');
    return;
  }
  const base = 'rooms/' + room;
  // 지난번 방 정리: 그 상담 모니터 창이 닫혀 있을 때만 (다른 창에서 쓰는 중이면 지우지 않음)
  if (oldRoom && oldRoom !== room && oldRoom.length >= 20) {
    get(ref(db, 'rooms/' + oldRoom + '/monitor')).then((s) => {
      const m = s.val();
      if (!m || !m.online) remove(ref(db, 'rooms/' + oldRoom)).catch(() => {});
    }).catch(() => {});
  }
  try {
    await update(ref(db, base + '/monitor'), { name: roomName, online: true, at: serverTimestamp(), ver: 3 });
    onDisconnect(ref(db, base + '/monitor')).update({ online: false });
    // 인터넷이 잠깐 끊겼다 돌아오면 다시 '켜짐'으로 (안 하면 15초 뒤 태블릿 연결이 풀림)
    let firstConn = true;
    onValue(ref(db, '.info/connected'), (s) => {
      if (s.val() !== true) { if (!firstConn) status(false, '인터넷 연결 확인 중…'); return; }
      if (firstConn) { firstConn = false; return; }
      update(ref(db, base + '/monitor'), { name: roomName, online: true, at: serverTimestamp() }).catch(() => {});
      onDisconnect(ref(db, base + '/monitor')).update({ online: false }).catch(() => {});
      status(tabletOnline, tabletOnline ? `${roomName} · 태블릿 연결됨` : `${roomName} · 태블릿 대기 중`);
    });
  } catch (e) {
    console.error(e);
    show('errorScreen');
    $('#errTitle').textContent = '데이터베이스 권한이 없습니다';
    $('#errText').innerHTML = 'Firebase 콘솔 → Realtime Database → <b>규칙</b>에 안내받은 보안 규칙을 붙여넣고 <b>[게시]</b>했는지 확인해 주세요.';
    status(false, '권한 없음');
    return;
  }
  await newCode();
  codeTimer = setInterval(newCode, 9 * 60 * 1000);
  onValue(ref(db, base + '/tablet'), (s) => {
    const v = s.val();
    tabletOnline = !!(v && v.online);
    if (tabletOnline) { wasPaired = true; forcePair = false; }
    status(tabletOnline, tabletOnline ? `${roomName} · 태블릿 연결됨` : `${roomName} · 태블릿 대기 중`);
    render();
  });
  onValue(ref(db, base + '/state'), (s) => { state = s.val(); render(); renderQa(); });
  onValue(ref(db, base + '/images'), (s) => { images = s.val(); render(); renderQa(); });
  // 🤖 자동 QA · 📚 보관함 (태블릿이 보내 줌)
  onValue(ref(db, base + '/qa'), (s) => { qa = s.val(); renderQa(); });
  onValue(ref(db, base + '/qaImg'), (s) => { qaImg = s.val(); renderQa(); });
  onValue(ref(db, base + '/archive'), (s) => { archive = s.val(); renderArchive(); });
  onValue(ref(db, base + '/archiveFull'), (s) => { const v = s.val(); if (v) gotBackup(v); });
  onValue(ref(db, base + '/slotImg'), (s) => { slotImg = s.val() || {}; renderSlots(); });
  onValue(ref(db, base + '/smileImg'), (s) => {
    smileData = s.val();
    showSmileImg();
    if (state && smOpen) render(); // 오늘 만든 After 작은 사진 갱신
  });
  onValue(ref(db, base + '/rzImg'), (s) => {
    const v = s.val();
    rzPreview = v && v.img ? 'data:image/jpeg;base64,' + v.img : null;
    if (rzPreview) $('#rzImg').src = rzPreview;
  });
  onValue(ref(db, base + '/samOv'), (s) => {
    const v = s.val();
    if (!v || !v.png) { samImg = null; drawLines(); return; }
    const im = new Image(); im.onload = () => { samImg = im; drawLines(); }; im.src = 'data:image/png;base64,' + v.png;
  });
  onValue(ref(db, base + '/records'), (s) => { records = s.val(); renderRecords(); pcCheck(false); });
  onValue(ref(db, base + '/recSync'), (s) => { pcGot(s.val()); });
  onValue(ref(db, base + '/recordFull'), (s) => { const v = s.val(); if (v) gotRecordFull(v); });
  onValue(ref(db, base + '/archiveMsg'), (s) => { const v = s.val(); if (v && v.at > openedAt) archMsg(v.text); });
  render();
}

$('#roomName').addEventListener('change', (e) => {
  roomName = e.target.value; store.set('bna.roomName', roomName);
  $('#pairRoom').textContent = roomName; $('#sub').textContent = roomName + ' · B&A 치과 시뮬레이터';
  if (db) update(ref(db, 'rooms/' + room + '/monitor'), { name: roomName }).catch(() => {});
  status(tabletOnline, tabletOnline ? `${roomName} · 태블릿 연결됨` : `${roomName} · 태블릿 대기 중`);
});
$('#panelBtn').addEventListener('click', () => { panelOn = !panelOn; store.set('bna.panel', panelOn ? '1' : '0'); render(); });
$('#pairBtn').addEventListener('click', () => { forcePair = true; render(); });
$('#closePair').addEventListener('click', () => { forcePair = false; render(); });
setInterval(() => { renderQa(); renderArchive(); }, 3000); // 태블릿 연결 상태 반영
$('#fullBtn').addEventListener('click', () => {
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  else document.documentElement.requestFullscreen().catch(() => {});
});
document.addEventListener('fullscreenchange', () => document.body.classList.toggle('full', !!document.fullscreenElement));

// 명령을 보냈는데 태블릿 응답(ack)이 없으면 안내
setInterval(() => { if (state && tabletOnline) render(); }, 2000);


// =============================================================================
// 🤖 자동 QA 에이전트 · 📚 프롬프트 보관함 (v3.13)
//   실행은 태블릿(AI 키·크레딧이 태블릿에 있음)에서, PC 는 정답지 올리기·시작/중지·결과 보기·저장
// =============================================================================
let qa = null, qaImg = null, archive = null, archFolder = '전체 보기', waitBackup = null;
const openedAt = Date.now();
const CRIT = ['기준 1 공간 폐쇄·아치 정렬', '기준 2 교합·맞물림', '기준 3 치아 형태·크기·색조 보존', '기준 4 잇몸·서비컬·주변 조직'];
function setHtml(el, html) { if (el._h !== html) { el._h = html; el.innerHTML = html; } }
const imgUrl = (b64) => (b64 ? 'data:image/jpeg;base64,' + b64 : '');
function openOv(id) { $('#' + id).hidden = false; }
function closeOv(id) { $('#' + id).hidden = true; if (id === 'camOv') camStop(); }
document.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => closeOv(b.dataset.close)));
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  for (const id of ['cmpOv', 'recDetOv', 'recOv', 'archOv', 'qaOv']) if (!$('#' + id).hidden) { closeOv(id); break; }
});
$('#qaBtn').addEventListener('click', () => { openOv('qaOv'); renderQa(); });
$('#archBtn').addEventListener('click', () => { openOv('archOv'); renderArchive(); });
$('#qaToArch').addEventListener('click', () => { openOv('archOv'); renderArchive(); });

function qaConnected() { return !!(db && tabletOnline); }

function renderQa() {
  if ($('#qaOv').hidden) return;
  const q = qa || {};
  const running = !!q.running;
  const newApp = !!qa;
  const warn = !qaConnected() ? '태블릿이 연결되어 있지 않습니다. QR 로 연결해 주세요.'
    : !newApp ? '태블릿 앱을 최신 버전(2026.11.27-a 이상)으로 업데이트해야 자동 QA 를 PC 에서 쓸 수 있습니다.'
    : !(images && images.before) ? '태블릿에서 환자 사진을 먼저 올려 주세요 (PC 의 [사진 올리기] 도 가능).'
    : q.ready === false ? '태블릿의 AI 연결이 준비되지 않았습니다 (태블릿 [API 키 설정] 확인).' : '';
  $('#qaWarn').hidden = !warn; $('#qaWarn').textContent = warn;
  const st = state || {};
  const eng = q.engine || ENGINES.find((e) => e.id === st.engine) || ENGINES[1];
  $('#qaOneLabel').textContent = `현재 선택한 엔진만 테스트 (${eng.tag} · ${eng.label})`;
  $('#qaCond').innerHTML = `치료 종류: <b>${esc((st.tx || []).join(', ') || '없음')}</b> · 치아: ${esc(st.teeth && st.teeth.length ? teethSummary(sortTeeth(st.teeth)) : '전체')}`
    + ` · 셰이드: ${esc(st.shade || '미선택')} · 서비컬 라인 ${(st.lines || []).length}개 · 시작 강도 ${st.strength || 90}%`
    + `<br>지금 태블릿에 선택된 조건 그대로 테스트합니다 (조건은 오른쪽 조작 패널에서 바꿀 수 있어요).`;
  const setBg = (el, b64) => { el.style.backgroundImage = b64 ? `url(${imgUrl(b64)})` : ''; };
  setBg($('#qaOrig'), images && images.before);
  $('#qaOrig').textContent = images && images.before ? '' : '사진 없음';
  const tg = $('#qaTarget');
  setBg(tg, q.hasTarget && qaImg && qaImg.target);
  tg.classList.toggle('has', !!q.hasTarget);
  tg.style.pointerEvents = running ? 'none' : '';
  setBg($('#qaLatest'), qaImg && qaImg.latest);
  $('#qaLatest').textContent = qaImg && qaImg.latest ? '' : (running ? '변환 중…' : '아직 없음');
  $('#qaLatest').classList.toggle('busy', running);
  $('#qaTgtActs').hidden = !q.hasTarget || running;
  const pass = Date.now() < qaPassUntil ? qaPassLocal : (q.pass || 90);
  document.querySelectorAll('input[name=qaPass]').forEach((r) => { r.checked = Number(r.value) === pass; r.disabled = running; });
  $('#qaPassNote').textContent = `목표 ${pass}점`;
  const cmpAll = Date.now() < qaModeUntil ? qaModeLocal : !!q.compareAll;
  document.querySelectorAll('input[name=qaMode]').forEach((r) => { r.checked = (r.value === 'all') === cmpAll; r.disabled = running; });
  if (document.activeElement !== $('#qaScorer') && q.scorer !== undefined && !$('#qaScorer').dataset.touched) $('#qaScorer').value = q.scorer || '';
  $('#qaScorer').disabled = running;
  $('#qaStart').hidden = running; $('#qaStop').hidden = !running;
  $('#qaStart').disabled = !!warn;
  $('#qaStart').textContent = q.hasTarget ? '자동 QA 테스트 시작' : '자동 QA 테스트 시작 (정답지 없이 자체 평가)';
  $('#qaStatus').textContent = q.status || '';
  // 순위 리포트
  const runs = q.runs || [];
  const byE = Object.fromEntries(runs.map((r) => [r.e, r]));
  if (q.rank && q.rank.length > 1) {
    const rows = q.rank.map((e, i) => {
      const r = byE[e]; if (!r) return '';
      const medal = r.unranked ? '-' : ['🥇', '🥈', '🥉'][i] + ' ' + (i + 1) + '위';
      return `<tr><td>${medal}</td><td>${esc(r.tag)} · ${esc(r.label)}</td><td>${r.unranked ? '못 돌림' : r.passed ? r.passRound + '회차' : `미합격 (${r.tries}회)`}</td><td>${r.unranked ? '-' : r.best + '점'}</td></tr>`;
    }).join('');
    setHtml($('#qaReport'), `<div class="report"><h3>🏆 옵션 A·B·C 비교 리포트</h3><small class="p-note">순위: 합격 여부 → 적은 시도 횟수 → 높은 점수</small>
      <table class="rank"><thead><tr><th>순위</th><th>엔진</th><th>합격 회차</th><th>최고 점수</th></tr></thead><tbody>${rows}</tbody></table>
      ${q.recommend ? `<p class="recommend">추천: ${esc(q.recommend)}</p>` : '<p class="p-note">점수가 나온 엔진이 없어 추천할 수 없습니다.</p>'}</div>`);
  } else setHtml($('#qaReport'), '');
  setHtml($('#qaRuns'), runs.map((r) => {
    const atts = (r.attempts || []).map((a) => {
      const bars = a.c ? `<div class="bars">${a.c.map((v, i) => `<div><span>${CRIT[i]}</span><i><b style="width:${v * 4}%"></b></i><span>${v}/25</span></div>`).join('')}</div>` : '';
      const ded = a.ded && a.ded.length ? `<b>감점 원인</b><ul>${a.ded.map((d) => `<li>${esc(d)}</li>`).join('')}</ul>` : '';
      const nx = !a.passed && a.next && a.total != null ? `<p class="next">➡️ 다음 회차 수정: ${esc(a.next)} · 강도 ${a.nextStrength}%</p>` : '';
      const head = a.total != null ? `${a.round}회차 · ${a.total}점${a.passed ? ' 합격 🎉' : ''}` : `${a.round}회차 · ${esc(a.error || '진행 중…')}`;
      return `<details><summary>${head} · 강도 ${a.strength}%</summary>${a.summary ? `<p>${esc(a.summary)}</p>` : ''}${bars}${ded}${nx}
        <p class="meta">이 회차 추가 요청: ${esc(a.request || '(없음)')}</p></details>`;
    }).join('');
    const saveBtn = r.canSave && !running
      ? `<button class="btn primary" type="button" data-save="${esc(r.e)}" ${r.saved ? 'disabled' : ''}>${r.saved ? '✓ 보관함에 저장됨' : '💾 프롬프트 & 사진 보관함에 저장'}</button>
         <button class="btn" type="button" data-import="${esc(r.e)}">🖼 메인 화면으로 가져오기</button>
         <small class="p-note">→ ${esc((st.tx || []).join('·') || '미분류')} 폴더로 자동 분류</small>` : '';
    return `<div class="run"><h3>${esc(r.tag)} · ${esc(r.label)}</h3>
      <div class="badge ${r.passed ? 'ok' : 'no'}">${esc(r.badge)}</div>
      <div class="timeline">점수 기록: ${esc(r.timeline)}${q.selfScore ? ' <small class="p-note">(정답지 없이 AI 자체 평가)</small>' : ''}</div>${atts}${saveBtn}</div>`;
  }).join(''));
}

$('#qaRuns').addEventListener('click', (e) => {
  const im = e.target.closest('[data-import]');
  if (im) { cmd('qaImport', im.dataset.import); closeOv('qaOv'); closeOv('archOv'); return; }
  const b = e.target.closest('[data-save]');
  if (!b) return;
  b.disabled = true; b.textContent = '저장하는 중…';
  cmd('qaSave', b.dataset.save);
});
let qaPassLocal = 90, qaPassUntil = 0;
document.querySelectorAll('input[name=qaPass]').forEach((r) => r.addEventListener('change', () => {
  if (!r.checked) return;
  qaPassLocal = Number(r.value); qaPassUntil = Date.now() + 3000;
  cmd('qaPass', qaPassLocal); renderQa();
}));
$('#qaTgtChange').addEventListener('click', () => $('#qaFile').click());
$('#qaTgtClear').addEventListener('click', () => { cmd('qaTargetClear'); $('#qaUpSt').textContent = '정답지를 지웠습니다'; });
let qaModeLocal = false, qaModeUntil = 0; // 클릭 직후엔 태블릿 확인 전이라도 고른 대로 보이게
document.querySelectorAll('input[name=qaMode]').forEach((r) => r.addEventListener('change', () => {
  if (!r.checked) return;
  qaModeLocal = r.value === 'all'; qaModeUntil = Date.now() + 3000;
  cmd('qaCompare', qaModeLocal);
}));
$('#qaScorer').addEventListener('input', () => { $('#qaScorer').dataset.touched = '1'; });
$('#qaTarget').addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); $('#qaFile').click(); } });
$('#qaFile').addEventListener('change', async (e) => {
  const f = e.target.files && e.target.files[0];
  e.target.value = '';
  if (!f) return;
  const st = $('#qaUpSt');
  try {
    st.textContent = '정답지를 태블릿으로 보내는 중…';
    const bmp = await createImageBitmap(f, { imageOrientation: 'from-image' });
    const k = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    cmd('qaTarget', c.toDataURL('image/jpeg', 0.9).split(',')[1]);
    st.textContent = '✓ 보냈습니다';
    setTimeout(() => { if (st.textContent.startsWith('✓')) st.textContent = ''; }, 4000);
  } catch (err) {
    console.error(err);
    st.textContent = '사진을 보내지 못했습니다 · 다른 사진으로 시도해 주세요';
  }
});
$('#qaStart').addEventListener('click', () => {
  const all = Date.now() < qaModeUntil ? qaModeLocal : !!(qa && qa.compareAll);
  const n = all ? 15 : 5;
  const self = !(qa && qa.hasTarget) ? '🎯 정답지가 없어 AI가 원본과 결과만 보고 \'이 치료의 이상적인 결과\' 기준으로 자체 채점합니다.\n' : '';
  if (!confirm(`${self}${all ? '옵션 A·B·C를 차례로' : '현재 엔진으로'} 최대 ${n}회 변환하고 같은 횟수만큼 비전 AI가 채점합니다.\n${Date.now() < qaPassUntil ? qaPassLocal : ((qa && qa.pass) || 90)}점이 되면 그 엔진은 바로 멈춥니다.\n\n변환·채점마다 크레딧(또는 Fal.ai 요금)이 사용됩니다. 시작할까요?`)) return;
  cmd('qaStart', { scorer: $('#qaScorer').value.trim() });
  $('#qaStatus').textContent = '태블릿에 시작을 요청했습니다…';
});
$('#qaStop').addEventListener('click', () => cmd('qaStop'));

// ---- 📚 보관함 ----
function renderArchive() {
  if ($('#archOv').hidden) return;
  const a = archive;
  if (!qaConnected() || !a) {
    setHtml($('#archFolders'), '');
    setHtml($('#archGrid'), `<p class="empty">${!qaConnected() ? '태블릿을 연결하면 태블릿에 저장된 보관함이 보입니다.' : '보관함이 비어 있거나, 태블릿 앱 업데이트(2026.11.27-a 이상)가 필요합니다.'}</p>`);
    return;
  }
  const folders = a.folders || [];
  setHtml($('#archFolders'), folders.map((f) =>
    `<button type="button" role="tab" data-folder="${esc(f.name)}" aria-selected="${f.name === archFolder}">${f.name === '전체 보기' ? '' : '📁 '}${esc(f.name)}<em>${f.count}</em></button>`).join(''));
  const cases = (a.cases || []).filter((c) => archFolder === '전체 보기' || (c.folders || []).includes(archFolder));
  if (!cases.length) { setHtml($('#archGrid'), `<p class="empty">'${esc(archFolder)}' 폴더에 저장된 케이스가 없습니다.</p>`); return; }
  setHtml($('#archGrid'), cases.map((c) => {
    const th = c.thumbs || {};
    const d = new Date(c.date);
    const date = isNaN(d) ? '' : `${d.getFullYear()}.${String(d.getMonth() + 1).padStart(2, '0')}.${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
    const t = (k, label) => `<button type="button" data-cmp="${esc(c.id)}" title="크게 비교">${th[k] ? `<img src="${imgUrl(th[k])}" alt="${label}">` : `<span class="empty">${k === 'target' ? '정답지 없음 (자체 평가)' : '사진 없음'}</span>`}<small>${label}</small></button>`;
    return `<article class="acase">
      <h3>${esc(c.title)}</h3>
      <div class="tags">${(c.folders || []).map((f) => `<span>📁 ${esc(f)}</span>`).join('')}</div>
      <div class="badge ${c.passed ? 'ok' : 'no'}">${c.passed ? '🎉 ' : ''}${esc(c.badge)}${c.selfScored ? ' <small>· AI 자체 평가</small>' : ''}</div>
      <div class="meta">${date} · ${esc(c.engine)} · 권장 적용 강도: ${c.strength}%</div>
      <div class="thumbs">${t('original', '① 원본')}${t('target', '② 실제 정답지')}${t('result', '③ AI 최종 결과')}</div>
      <div class="meta">${esc(c.timeline || '')}</div>
      <details><summary>황금 프롬프트 전문 보기</summary><pre>${esc(c.prompt || '')}</pre></details>
      <div class="acts">
        <button class="btn sm" type="button" data-copy="${esc(c.id)}">프롬프트 복사</button>
        <button class="btn sm" type="button" data-apply="${esc(c.id)}">이 치료의 기본 설정으로 적용</button>
        <button class="btn sm primary" type="button" data-import="${esc(c.id)}">🖼 메인 화면으로 가져오기</button>
        <button class="btn sm" type="button" data-backup="${esc(c.id)}">데이터 백업 다운로드</button>
        <button class="btn sm danger" type="button" data-del="${esc(c.id)}">삭제</button>
      </div></article>`;
  }).join(''));
}
function archMsg(t) {
  $('#archMsg').textContent = t;
  clearTimeout(archMsg.t);
  archMsg.t = setTimeout(() => { $('#archMsg').textContent = ''; }, 5000);
}
const caseOf = (id) => ((archive && archive.cases) || []).find((c) => c.id === id);
$('#archFolders').addEventListener('click', (e) => {
  const b = e.target.closest('[data-folder]');
  if (b) { archFolder = b.dataset.folder; renderArchive(); }
});
$('#archGrid').addEventListener('click', async (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  if (b.dataset.import) { cmd('archImport', b.dataset.import); closeOv('archOv'); closeOv('qaOv'); return; }
  if (b.dataset.cmp) {
    const c = caseOf(b.dataset.cmp); if (!c) return;
    const th = c.thumbs || {};
    $('#cmpRow').innerHTML = [['original', '① 원본'], ['target', '② 실제 정답지'], ['result', '③ AI 최종 결과']]
      .map(([k, l]) => `<figure><figcaption>${l}</figcaption>${th[k] ? `<img src="${imgUrl(th[k])}" alt="${l}">` : ''}</figure>`).join('');
    openOv('cmpOv');
    // 큰 사진은 백업 내용에서 다시 받아 바꿔 끼움
    waitBackup = { id: c.id, mode: 'view' };
    cmd('archFull', c.id);
  } else if (b.dataset.copy) {
    const c = caseOf(b.dataset.copy); if (!c) return;
    try { await navigator.clipboard.writeText(c.prompt || ''); archMsg('✓ 프롬프트를 복사했습니다'); }
    catch (err) { archMsg('복사하지 못했습니다 · 프롬프트 전문을 펼쳐 직접 복사해 주세요'); }
  } else if (b.dataset.apply) {
    const c = caseOf(b.dataset.apply); if (!c) return;
    const tx = (c.treatments || []).join('·') || '미분류';
    if (!confirm(`'${tx}' 버튼의 기본 설정을 이 케이스로 영구히 바꿀까요?\n\n· 추가 요청: ${c.request || '(없음)'}\n· 적용 강도: ${c.strength}%\n\n이후 태블릿에서 그 치료 버튼을 켜면 자동으로 들어갑니다.`)) return;
    cmd('archApply', c.id);
  } else if (b.dataset.backup) {
    waitBackup = { id: b.dataset.backup, mode: 'download' };
    archMsg('태블릿에서 백업 파일을 받는 중…');
    cmd('archFull', b.dataset.backup);
  } else if (b.dataset.del) {
    const c = caseOf(b.dataset.del); if (!c) return;
    if (!confirm(`'${c.title}' 케이스를 보관함에서 삭제할까요? (태블릿에서도 지워집니다)`)) return;
    cmd('archDel', c.id);
  }
});
function download(name, text, type) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement('a');
  a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 5000);
}
function gotBackup(v) {
  const w = waitBackup;
  if (!w || v.id !== w.id) return;
  waitBackup = null;
  if (w.mode === 'download') {
    download(v.name + '.html', v.html, 'text/html;charset=utf-8');
    download(v.name + '.json', v.json, 'application/json');
    archMsg('✓ 백업 파일 2개(HTML 리포트 · JSON)를 내려받았습니다');
  } else if (!$('#cmpOv').hidden) {
    try {
      const imgs = JSON.parse(v.json).images_base64_jpeg || {};
      const figs = $('#cmpRow').querySelectorAll('figure');
      ['original', 'target', 'result'].forEach((k, i) => { const im = figs[i] && figs[i].querySelector('img'); if (im && imgs[k]) im.src = imgUrl(imgs[k]); });
    } catch (err) { /* 작은 사진 그대로 */ }
  }
  remove(ref(db, 'rooms/' + room + '/archiveFull')).catch(() => {});
}


// =============================================================================
// 🗂 환자 기록 (v3.16): 태블릿이 [저장 및 상담 완료] 때 날짜 › 환자이름 폴더로 저장한 기록
// =============================================================================
let records = null, recTx = null, recOpen = null, recWait = null, recFull = null;
const TX_ALL = ['라미네이트', '무삭제 라미네이트', '미백', '교정', '잇몸 성형', '올세라믹 크라운', '임플란트'];
const two = (n) => String(n).padStart(2, '0');
function recMatches(r, q) {
  q = q.trim().toLowerCase();
  if (!q) return true;
  const d = new Date(r.savedAt);
  const dates = isNaN(d) ? [r.day || ''] : [r.day, r.dayText, `${d.getFullYear()}.${d.getMonth() + 1}.${d.getDate()}`,
    `${two(d.getMonth() + 1)}.${two(d.getDate())}`, `${d.getMonth() + 1}.${d.getDate()}`, `${d.getMonth() + 1}월 ${d.getDate()}일`,
    `${d.getMonth() + 1}월${d.getDate()}일`, `${d.getFullYear()}${two(d.getMonth() + 1)}${two(d.getDate())}`];
  const hay = [r.name, ...dates, ...(r.treatments || []), r.memo || '', r.photoType || ''].join(' ').toLowerCase();
  return q.split(/\s+/).every((w) => hay.includes(w));
}
function renderRecords() {
  if ($('#recOv').hidden) return;
  if (!qaConnected() || !records) {
    setHtml($('#recTx'), ''); $('#recCount').textContent = '';
    setHtml($('#recTree'), `<p class="empty">${!qaConnected() ? '태블릿을 연결하면 태블릿에 저장된 환자 기록이 보입니다.' : '아직 저장된 기록이 없거나, 태블릿 앱 업데이트(2026.11.27-a 이상)가 필요합니다.'}</p>`);
    return;
  }
  setHtml($('#recTx'), TX_ALL.map((t) => `<button type="button" data-tx="${esc(t)}" class="${recTx === t ? 'on' : ''}" aria-pressed="${recTx === t}">${esc(t)}</button>`).join(''));
  const q = $('#recQ').value, day = $('#recDay').value;
  const all = (records.items || []);
  const items = all.filter((r) => recMatches(r, q) && (!day || r.day === day) && (!recTx || (r.treatments || []).includes(recTx)));
  $('#recCount').textContent = all.length ? `${items.length}건${items.length === all.length ? '' : ` (전체 ${records.n || all.length}건 중)`}` : '';
  if (!all.length) { setHtml($('#recTree'), '<p class="empty">아직 저장된 환자 기록이 없습니다. 태블릿에서 변환 후 [시뮬레이션 결과 저장 및 상담 완료]를 누르면 날짜 › 환자이름 폴더로 저장됩니다.</p>'); return; }
  if (!items.length) { setHtml($('#recTree'), '<p class="empty">검색 결과가 없습니다. 이름·날짜·치료종류를 바꿔 보세요.</p>'); return; }
  const byDay = new Map();
  [...items].sort((a, b) => String(b.savedAt).localeCompare(String(a.savedAt))).forEach((r) => {
    if (!byDay.has(r.day)) byDay.set(r.day, { text: r.dayText, names: new Map() });
    const d = byDay.get(r.day);
    if (!d.names.has(r.name)) d.names.set(r.name, []);
    d.names.get(r.name).push(r);
  });
  setHtml($('#recTree'), [...byDay.entries()].map(([day, d]) => {
    const n = [...d.names.values()].reduce((a, l) => a + l.length, 0);
    return `<details class="day" open><summary>${esc(d.text || day)}<small>환자 ${d.names.size}명 · ${n}건</small></summary>${
      [...d.names.entries()].map(([name, list]) => `<div class="pname"><h4>👤 ${esc(name)} 님<small>${list.length}건</small></h4>${
        list.map((r) => {
          const th = r.thumbs || {}, last = (r.shots || []).at(-1);
          const ck = last && last.check ? (last.check.startsWith('✓') ? ' · 🦷 무삭제 검사 통과' : ' · 🦷 ⚠ 검사 주의') : '';
          return `<button type="button" class="rec" data-rec="${esc(r.id)}">${th.before ? `<img src="${imgUrl(th.before)}" alt="원본">` : '<span class="ph"></span>'}${th.after ? `<img src="${imgUrl(th.after)}" alt="결과">` : ''}
            <span class="tx"><b>${esc(r.time)} · ${esc((r.treatments || []).join(', ') || '치료 미선택')}</b><span>${(r.teeth || []).length ? (r.teeth || []).map((t) => '#' + t).join(' ') + ' · ' : ''}${r.shade ? '셰이드 ' + esc(r.shade) + ' · ' : ''}변환 ${(r.shots || []).length}장${ck}</span></span></button>`;
        }).join('')}</div>`).join('')}</details>`;
  }).join(''));
}
function openRecord(id) {
  const r = ((records && records.items) || []).find((x) => x.id === id);
  if (!r) return;
  recOpen = r;
  $('#recDetTitle').textContent = `${r.name} 님 · ${r.dayText} ${r.time}`;
  $('#recSmile').hidden = !r.hasSmile;
  const th = r.thumbs || {};
  const info = [['상담 날짜', `${r.dayText} ${r.time}`], ['환자', `${r.name} 님`], ['사진', r.photoType || '-'],
    ['치료 항목', (r.treatments || []).join(', ') || '선택 안 함'], ['치료 부위', (r.teeth || []).map((t) => '#' + t).join(' ') || '-'],
    ['희망 셰이드', r.shade || '선택 안 함'], ['메모', r.memo || '(메모 없음)'], ['저장 폴더', String(r.folder || '').split('/').join(' › ')]];
  const shots = r.shots || [];
  $('#recDetBody').innerHTML = `<div class="det-imgs"><figure><figcaption>원본 (치료 전)</figcaption>${th.before ? `<img id="detBefore" src="${imgUrl(th.before)}" alt="원본">` : '<span class="ph"></span>'}<button type="button" class="btn sm det-one" data-one="before.jpg">＋ 이 사진만 불러오기</button></figure>
    <figure><figcaption id="detAfterCap">${esc(shots.length ? shots.at(-1).label : '변환 결과 없음')}</figcaption>${th.after ? `<img id="detAfter" src="${imgUrl(th.after)}" alt="결과">` : '<span class="ph"></span>'}
    ${shots.length ? `<button type="button" class="btn sm det-one" id="detAfterOne" data-one="${esc(shots.at(-1).file || '')}">＋ 이 사진만 불러오기</button>` : ''}
    <small class="p-note" id="detCheck">${shots.length && shots.at(-1).check ? '🦷 ' + esc(shots.at(-1).check) : ''}</small></figure></div>
    <div class="folders" id="detShots">${shots.length > 1 ? shots.map((s, i) => `<button type="button" data-shot="${i}" class="${i === shots.length - 1 ? 'on' : ''}">${esc(s.label)}</button>`).join('') : ''}</div>
    ${r.hasSmile ? '<h4>😊 미소 미리보기</h4><div class="det-imgs"><figure><figcaption>미소 (치료 전)</figcaption><img id="detSmile" alt="미소 전"><button type="button" class="btn sm det-one" data-one="smile_before.jpg">＋ 이 사진만 불러오기</button></figure><figure><figcaption>미소 미리보기</figcaption><img id="detSmileAfter" alt="미소 후"><button type="button" class="btn sm det-one" data-one="smile_after.jpg">＋ 이 사진만 불러오기</button></figure></div>' : ''}
    <small class="p-note" id="detLoading">큰 사진을 태블릿에서 받는 중…</small>
    <dl class="det-info">${info.map(([k, v]) => `<dt>${k}</dt><dd>${esc(v)}</dd>`).join('')}</dl>`;
  openOv('recDetOv');
  recWait = id; recFull = null;
  cmd('recFull', id);
}
function gotRecordFull(v) {
  if (v.id !== recWait) return;
  recWait = null; recFull = v;
  if ($('#detBefore') && v.before) $('#detBefore').src = imgUrl(v.before);
  const shots = v.shots || [];
  if ($('#detAfter') && shots.length && shots.at(-1).img) $('#detAfter').src = imgUrl(shots.at(-1).img);
  if ($('#detSmile') && v.smile) $('#detSmile').src = imgUrl(v.smile);
  if ($('#detSmileAfter') && v.smileAfter) $('#detSmileAfter').src = imgUrl(v.smileAfter);
  if ($('#detLoading')) $('#detLoading').textContent = '';
  remove(ref(db, 'rooms/' + room + '/recordFull')).catch(() => {});
}
$('#recBtn').addEventListener('click', () => { openOv('recOv'); renderRecords(); });
// 😊 미소 창에서 [🗂 환자 기록에서 불러오기] → 기록 목록 열기 (기록을 열어 [😊 이 미소 사진 불러오기])
$('#smFromRec').addEventListener('click', () => { openOv('recOv'); renderRecords(); $('#smMsg').textContent = '기록을 열고 [😊 이 미소 사진 불러오기]를 눌러 주세요'; });
$('#recQ').addEventListener('input', renderRecords);
$('#recDay').addEventListener('change', renderRecords);
$('#recReset').addEventListener('click', () => { $('#recQ').value = ''; $('#recDay').value = ''; recTx = null; renderRecords(); });
$('#recTx').addEventListener('click', (e) => { const b = e.target.closest('[data-tx]'); if (!b) return; recTx = recTx === b.dataset.tx ? null : b.dataset.tx; renderRecords(); });
$('#recTree').addEventListener('click', (e) => { const b = e.target.closest('[data-rec]'); if (b) openRecord(b.dataset.rec); });
$('#recDetBody').addEventListener('click', (e) => {
  // ＋ 이 사진만 불러오기 → 태블릿 시뮬레이터에 한 장씩 (창은 그대로, 이어서 다른 사진도)
  const one = e.target.closest('[data-one]');
  if (one && recOpen) {
    if (!one.dataset.one) return;
    cmd('recPhoto', { id: recOpen.id, f: one.dataset.one });
    one.textContent = '✔ 불러옴 (다시 누르면 다시 보냄)';
    return;
  }
  const b = e.target.closest('[data-shot]');
  if (!b || !recOpen) return;
  const i = Number(b.dataset.shot), s = (recOpen.shots || [])[i];
  document.querySelectorAll('#detShots button').forEach((x) => x.classList.toggle('on', x === b));
  $('#detAfterCap').textContent = s.label;
  if ($('#detAfterOne')) { $('#detAfterOne').dataset.one = s.file || ''; $('#detAfterOne').textContent = '＋ 이 사진만 불러오기'; }
  $('#detCheck').textContent = s.check ? '🦷 ' + s.check : '';
  const full = recFull && recFull.id === recOpen.id ? (recFull.shots || [])[i] : null;
  if ($('#detAfter')) $('#detAfter').src = full && full.img ? imgUrl(full.img) : '';
});
// 비교 목록 [🗂 기록 사진] · 첫 화면 [🗂 기록 사진 불러오기] → 기록을 열고 사진 아래 [＋ 이 사진만 불러오기]
// 📂 불러오기: PC 파일(여러 장) 또는 환자 기록 → 비교 목록
$('#pickLoad').addEventListener('click', (e) => { e.stopPropagation(); $('#loadMenu').hidden = !$('#loadMenu').hidden; });
$('#loadMenu').addEventListener('click', (e) => {
  const b = e.target.closest('[data-load]'); if (!b) return;
  $('#loadMenu').hidden = true;
  if (b.dataset.load === 'file') $('#pickFile').click();
  else { openOv('recOv'); renderRecords(); }
});
document.addEventListener('click', (e) => { if (!e.target.closest('.pick-add')) $('#loadMenu').hidden = true; });

// 🧪 전문가 모드: 자동 QA · 환자 기록 · 보관함 버튼 (PC 마다 기억)
let expert = false;
try { expert = localStorage.getItem('bna.expert') === '1'; } catch (e) { /* 저장 못 해도 이번엔 사용 */ }
function applyExpert() {
  $('#expertMode').checked = expert;
  for (const id of ['qaBtn', 'recBtn', 'archBtn']) $('#' + id).hidden = !expert;
}
$('#eyeMask').addEventListener('change', (e) => cmd('eyeMask', e.target.checked));
$('#expertMode').addEventListener('change', (e) => {
  expert = e.target.checked;
  try { localStorage.setItem('bna.expert', expert ? '1' : '0'); } catch (err) { /* 무시 */ }
  applyExpert();
});
applyExpert();

// 📷 사진 촬영 (PC 카메라) → 원본 1·2 로
let camStream = null, camShotData = null;
function camStop() { if (camStream) { camStream.getTracks().forEach((t) => t.stop()); camStream = null; } }
async function camStart(deviceId) {
  camStop();
  $('#camMsg').textContent = '카메라를 켜는 중…';
  try {
    camStream = await navigator.mediaDevices.getUserMedia({ video: deviceId ? { deviceId: { exact: deviceId }, width: { ideal: 1920 } } : { width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false });
    $('#camVideo').srcObject = camStream;
    const cams = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === 'videoinput');
    const sel = $('#camSel');
    sel.hidden = cams.length < 2;
    if (cams.length > 1 && !sel.options.length) {
      sel.innerHTML = cams.map((c, i) => `<option value="${esc(c.deviceId)}">${esc(c.label || '카메라 ' + (i + 1))}</option>`).join('');
    }
    $('#camMsg').textContent = '얼굴을 화면 가운데에 맞추고 [📸 찍기]';
  } catch (err) {
    console.error(err);
    $('#camMsg').textContent = '카메라를 켤 수 없어요 · 카메라가 연결돼 있는지, 브라우저 카메라 권한을 허용했는지 확인해 주세요';
  }
}
function camMode(shot) {
  $('#camVideo').hidden = shot; $('#camShot').hidden = !shot;
  $('#camSnap').hidden = shot; $('#camRetake').hidden = !shot;
  $('#camTo1').hidden = !shot || camTarget === 2; $('#camTo2').hidden = !shot || camTarget === 1;
}
let camTarget = 0; // 0: 찍고 원본 1·2 고르기, 1·2: 그 카드로 바로
function camOpen(target) {
  camTarget = target || 0;
  camShotData = null; camMode(false);
  $('#camTitle').textContent = camTarget ? `📷 원본 ${camTarget} (${camTarget === 1 ? '자연스러운 미소' : '개구기'}) 촬영` : '📷 사진 촬영';
  openOv('camOv'); camStart();
}
$('#camBtn').addEventListener('click', () => camOpen(0));
$('#camSel').addEventListener('change', (e) => camStart(e.target.value));
$('#camSnap').addEventListener('click', () => {
  const v = $('#camVideo');
  if (!v.videoWidth) { $('#camMsg').textContent = '카메라 화면이 아직 없어요'; return; }
  const k = Math.min(1, 2400 / Math.max(v.videoWidth, v.videoHeight));
  const c = document.createElement('canvas');
  c.width = Math.round(v.videoWidth * k); c.height = Math.round(v.videoHeight * k);
  c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
  const url = c.toDataURL('image/jpeg', 0.92);
  camShotData = url.split(',')[1];
  $('#camShot').src = url;
  camMode(true);
  $('#camMsg').textContent = '어느 원본으로 보낼까요?';
});
$('#camRetake').addEventListener('click', () => { camShotData = null; camMode(false); });
for (const k of [1, 2]) {
  $('#camTo' + k).addEventListener('click', () => {
    if (!camShotData) return;
    cmd('slotPhoto', { s: k, b: camShotData });
    camShotData = null;
    camStop(); closeOv('camOv');
  });
}

// 태블릿 알림을 PC 에도 (불러왔어요·뺐어요 …)
let noticeAt = null, toastTimer = 0;
function showNotice(n) {
  if (!n || !n.at) return;
  if (noticeAt === null) { noticeAt = n.at; return; } // 처음 연결 때 지난 알림은 안 띄움
  if (n.at === noticeAt) return;
  noticeAt = n.at;
  const t = $('#toast');
  t.textContent = String(n.m || '');
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 5000);
}
// 😊 이 기록의 미소 사진만 지금 환자의 비교 목록 + 미소 미리보기로 (여러 번 누르면 차례대로 쌓임)
$('#recSmile').addEventListener('click', () => {
  if (!recOpen) return;
  cmd('smileFromRec', recOpen.id);
  smOpen = true; smTab = 'area';
  closeOv('recDetOv'); closeOv('recOv');
  render();
});
$('#recDel').addEventListener('click', () => {
  if (!recOpen) return;
  if (!confirm(`${recOpen.dayText} ${recOpen.time} · ${recOpen.name} 님 기록을 삭제할까요? (태블릿에서도 지워집니다)`)) return;
  cmd('recDel', recOpen.id); closeOv('recDetOv');
});
setInterval(renderRecords, 3000);


// =============================================================================
// 🦷 변환된 사진 치아 크기 조절 (v3.18) — 태블릿이 계산, PC 는 클릭·± 조작
// =============================================================================
let rzPreview = null;
let rzZ = { s: 1, fx: 0.5, fy: 0.5 }; // 🔍 확대 배율 · 화면 가운데에 올 사진 위치
function rzRect() {
  const im = $('#rzImg'), box = $('#rzView').getBoundingClientRect();
  const iw = im.naturalWidth || 4, ih = im.naturalHeight || 3;
  const k = Math.min(box.width / iw, box.height / ih);
  const w = iw * k * rzZ.s, h = ih * k * rzZ.s;
  const place = (bw, len, f) => (len <= bw ? (bw - len) / 2 : Math.min(0, Math.max(bw - len, bw / 2 - f * len)));
  return { x: place(box.width, w, rzZ.fx), y: place(box.height, h, rzZ.fy), w, h, box };
}
function rzZoomAt(fx, fy, ns) {
  rzZ.s = Math.min(6, Math.max(1, ns));
  if (rzZ.s === 1) { rzZ.fx = 0.5; rzZ.fy = 0.5; } else { rzZ.fx = fx; rzZ.fy = fy; }
  $('#rzZlabel').textContent = rzZ.s > 1.01 ? rzZ.s.toFixed(1) + '배' : '';
  drawRz();
}
function renderRz(view) {
  const rz = state && state.rz;
  // 크기 조절: 왼쪽 목록에서 고른 사진 (원본 1·2 제외 · After·미소 결과 모두) — 태블릿 2026.11.27-a 이상은 rzOk
  const rzOk = state && state.rzOk !== undefined ? !!state.rzOk : !!(state && state.hasAfter) && view !== 'edit';
  const canOpen = !!state && state.useAi && rzOk && !locked() && !rz && Number(state.v) >= 6 && state.samOn !== undefined;
  if (state && state.rzOf) $('#rzOpen').title = `🦷 [${state.rzOf}] 사진의 치아를 클릭해 키우거나 줄여요 (왼쪽 목록에서 다른 사진을 누르면 그 사진으로)`;
  $('#rzOpen').hidden = !canOpen;
  $('#rzPanel').hidden = !rz;
  if (!rz) return;
  if (!rzPreview && images && images.after && !$('#rzImg').src) $('#rzImg').src = 'data:image/jpeg;base64,' + images.after;
  const teeth = rz.teeth || [];
  $('#rzHint').textContent = rz.busy ? '🪄 치아 윤곽 찾는 중…' : teeth.length ? '클릭: 다른 치아 추가 · 오른쪽 클릭: 같이 잡힌 옆 치아 빼기 · 휠: 확대 · 끌기: 이동' : '사진에서 크기를 바꿀 치아를 클릭하세요 (휠로 확대하면 더 정확해요)';
  setHtml($('#rzChips'), teeth.map((t, i) => `<button type="button" data-i="${i}" class="${i === rz.sel ? 'on' : ''}">${esc(t.l)}${Object.values(t.p || {}).some((v) => v) ? ' ●' : ''}</button>`).join(''));
  const t = teeth[rz.sel];
  $('#rzArrows').hidden = !t; $('#rzRemove').disabled = !t;
  if (t) {
    for (const s of ['up', 'down', 'left', 'right']) {
      const margin = t.u ? s === 'up' : s === 'down';
      const lockedSide = rz.noPrep && margin;
      const v = (t.p || {})[s] || 0;
      document.querySelector(`#rzArrows em[data-p="${s}"]`).textContent = lockedSide ? '고정' : `${v > 0 ? '+' : ''}${v}%`;
      document.querySelector(`#rzArrows button[data-s="${s}"][data-d="1"]`).disabled = lockedSide;
      document.querySelector(`#rzArrows button[data-s="${s}"][data-d="-1"]`).disabled = lockedSide || v <= (rz.noPrep ? 0 : -30); // 줄이기 -30% 까지 (무삭제는 줄이기 없음)
    }
  }
  drawRz();
}
function drawRz() {
  const rz = state && state.rz, cv = $('#rzCanvas');
  if (!rz || $('#rzPanel').hidden) return;
  const r = rzRect(), dpr = window.devicePixelRatio || 1;
  cv.width = Math.round(r.box.width * dpr); cv.height = Math.round(r.box.height * dpr);
  const g = cv.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0);
  const im = $('#rzImg');
  if (im.complete && im.naturalWidth) g.drawImage(im, r.x, r.y, r.w, r.h); // 확대해서 직접 그림
  (rz.teeth || []).forEach((t, i) => {
    const [l, tp, rr, b] = t.b, on = i === rz.sel;
    const x = r.x + l * r.w, y = r.y + tp * r.h, w = (rr - l) * r.w, h = (b - tp) * r.h;
    g.strokeStyle = on ? '#00E0B8' : 'rgba(255,255,255,.6)'; g.lineWidth = on ? 2 : 1; g.strokeRect(x, y, w, h);
    g.font = '800 12px sans-serif'; g.fillStyle = on ? '#00E0B8' : '#fff'; g.shadowColor = 'rgba(0,0,0,.8)'; g.shadowBlur = 3;
    g.fillText(t.l || '', x, y - 4); g.shadowBlur = 0;
  });
}
$('#rzOpen').addEventListener('click', () => { rzPreview = null; rzZ = { s: 1, fx: 0.5, fy: 0.5 }; $('#rzZlabel').textContent = ''; $('#rzImg').removeAttribute('src'); cmd('rzStart'); });
$('#rzCancel').addEventListener('click', () => cmd('rzCancel'));
$('#rzApply').addEventListener('click', () => cmd('rzApply'));
$('#rzRemove').addEventListener('click', () => cmd('rzRemove'));
$('#rzChips').addEventListener('click', (e) => { const b = e.target.closest('[data-i]'); if (b) cmd('rzSel', Number(b.dataset.i)); });
$('#rzArrows').addEventListener('click', (e) => { const b = e.target.closest('button[data-s]'); if (b && !b.disabled) cmd('rzStep', { s: b.dataset.s, d: Number(b.dataset.d) }); });
const rzPt = (e) => {
  const r = rzRect(), b = $('#rzCanvas').getBoundingClientRect();
  return [(e.clientX - b.left - r.x) / r.w, (e.clientY - b.top - r.y) / r.h];
};
let rzPan = null;
$('#rzCanvas').addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return;
  rzPan = { id: e.pointerId, x: e.clientX, y: e.clientY, fx: rzZ.fx, fy: rzZ.fy, moved: false };
  $('#rzCanvas').setPointerCapture(e.pointerId);
});
$('#rzCanvas').addEventListener('pointermove', (e) => {
  if (!rzPan || rzPan.id !== e.pointerId) return;
  const dx = e.clientX - rzPan.x, dy = e.clientY - rzPan.y;
  if (Math.abs(dx) + Math.abs(dy) > 6) rzPan.moved = true;
  if (rzPan.moved && rzZ.s > 1) {
    const r = rzRect();
    rzZ.fx = Math.min(1, Math.max(0, rzPan.fx - dx / r.w)); rzZ.fy = Math.min(1, Math.max(0, rzPan.fy - dy / r.h));
    $('#rzCanvas').classList.add('panning'); drawRz();
  }
});
$('#rzCanvas').addEventListener('pointerup', (e) => {
  const p = rzPan; rzPan = null; $('#rzCanvas').classList.remove('panning');
  if (!p || p.moved) return; // 끌기 = 이동, 클릭 = 치아 고르기
  const [x, y] = rzPt(e);
  if (x < 0 || y < 0 || x > 1 || y > 1) return;
  cmd('rzTap', { x: Math.round(x * 1000) / 1000, y: Math.round(y * 1000) / 1000 });
});
// 오른쪽 클릭: 같이 잡힌 옆 치아 빼기
$('#rzCanvas').addEventListener('contextmenu', (e) => {
  e.preventDefault(); e.stopPropagation();
  const [x, y] = rzPt(e);
  if (x < 0 || y < 0 || x > 1 || y > 1) return;
  cmd('rzNeg', { x: Math.round(x * 1000) / 1000, y: Math.round(y * 1000) / 1000 });
  $('#rzHint').textContent = '➖ 그 부분을 빼고 다시 찾는 중…';
});
$('#rzCanvas').addEventListener('wheel', (e) => {
  e.preventDefault();
  const [x, y] = rzPt(e);
  rzZoomAt(Math.min(1, Math.max(0, x)), Math.min(1, Math.max(0, y)), rzZ.s * Math.exp(-e.deltaY / 400));
}, { passive: false });
$('#rzZin').addEventListener('click', () => {
  const t = state && state.rz && state.rz.teeth && state.rz.teeth[state.rz.sel];
  const c = t ? [(t.b[0] + t.b[2]) / 2, (t.b[1] + t.b[3]) / 2] : [rzZ.fx, rzZ.fy];
  rzZoomAt(c[0], c[1], rzZ.s * 1.5);
});
$('#rzZout').addEventListener('click', () => rzZoomAt(rzZ.fx, rzZ.fy, rzZ.s / 1.5));
$('#rzZfit').addEventListener('click', () => rzZoomAt(0.5, 0.5, 1));
$('#rzImg').addEventListener('load', drawRz);
new ResizeObserver(drawRz).observe($('#rzView'));


// =============================================================================
// 😊 미소 미리보기 (v3.21) — 미소 사진에 시뮬레이션 치아 입히기 (태블릿이 계산)
// =============================================================================
let smAftKey = '';
let smOpen = false, smTab = 'area', smileData = null, smWaiting = false, smSawBusy = false, smMWaiting = false, smMSawBusy = false;
function showSmileImg() {
  const v = smileData;
  if (smTab[0] === 'm' && !(v && v[smTab])) smTab = 'area';
  const mt = smTab[0] === 'm' ? v[smTab] : null;
  const result = smTab === 'result' && v && v.after;
  $('#smImg').src = mt ? 'data:image/jpeg;base64,' + mt : result ? 'data:image/jpeg;base64,' + v.after : v && v.photo ? 'data:image/jpeg;base64,' + v.photo : '';
  $('#smOv').src = v && v.ov ? 'data:image/png;base64,' + v.ov : '';
  $('#smOv').hidden = !(v && v.ov) || smTab !== 'area';
  $('#smEmpty').hidden = !!(v && v.photo);
  $('#smTabs').hidden = !(v && (v.after || v.m3));
  $('#smTabArea').setAttribute('aria-pressed', String(smTab === 'area'));
  $('#smTabResult').setAttribute('aria-pressed', String(!!result));
  $('#smTabResult').hidden = !(v && v.after);
  $('#smMTabs').hidden = !(v && v.m3);
  document.querySelectorAll('#smMTabs button').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.m === smTab)));
  $('#smPick').hidden = !mt;
  $('#smP2').hidden = !(v && v.p2);
  if (v && v.p2) $('#smP2').src = 'data:image/jpeg;base64,' + v.p2;
}
function renderSmile(view) {
  const sm = (state && state.smile) || null;
  // 미소에 입히기가 끝나면 창을 닫고 큰 화면의 미소 비교를 바로 보여 줌
  if (sm && smWaiting && sm.busy) smSawBusy = true;
  if (sm && smWaiting && smSawBusy && !sm.busy) {
    smWaiting = false; smSawBusy = false;
    if (sm.made) { smOpen = false; smTab = 'result'; showSmileImg(); }
  }
  // 🦷 정밀 매칭이 끝나면 창을 닫고 큰 화면에 미소 비교 (다시 열면 ①②③ 단계 탭)
  const mm = (sm && sm.match) || null;
  if (mm && smMWaiting && mm.busy) smMSawBusy = true;
  if (mm && smMWaiting && smMSawBusy && !mm.busy) {
    smMWaiting = false; smMSawBusy = false;
    if (mm.made) { smOpen = false; smTab = 'm3'; showSmileImg(); }
  }
  const can = !!sm && state.useAi && !locked() && !(state && state.rz); // 변환 전 첫 화면에서도
  $('#smOpenBar').hidden = smOpen || locked() || !!(state && state.rz);
  $('#smOpen').hidden = !can;
  $('#smOpen').textContent = sm && sm.made ? '😊 미소 미리보기 다시' : '😊 미소 미리보기';
  if (!sm) smOpen = false;
  $('#smPanel').hidden = !smOpen;
  if (!smOpen) return;
  $('#smAuto').hidden = !sm.auto || !sm.has;
  $('#smUndo').disabled = !sm.undo; $('#smClear').disabled = !(sm.n > 0);
  $('#smMake').disabled = !sm.has || !(sm.n > 0) || sm.busy || !state.hasAfter;
  $('#smMake').textContent = sm.busy ? '⏳ 처리 중…' : sm.made ? '😊 다시 입히기' : '😊 미소에 입히기';
  $('#smHint').textContent = !sm.has ? '사진을 올리면 입술 사이 치아를 자동으로 찾아요' : sm.n > 0 ? `치아 영역 ${sm.n}개 선택됨` : '🪄 미소 사진 속 치아를 클릭해 고르세요';
  $('#smMsg').textContent = sm.msg || '';
  // 🦷 보철 사진 정밀 매칭 (태블릿 앱 2026.11.27-a 이상)
  $('#smMatch').hidden = !mm;
  if (mm) {
    const busy = !!mm.busy;
    $('#smP2After').disabled = busy || !state.hasAfter;
    $('#smP2After').title = state.hasAfter ? '지금 큰 화면의 변환 결과를 2번 사진으로 써요' : '변환 결과가 아직 없어요';
    $('#smMatchRun').disabled = busy || !mm.ok || !sm.has || !mm.has2;
    // 오늘 만든 After 들 (태블릿 2026.11.27-a 이상)
    const afs = Array.isArray(mm.afters) ? mm.afters : [];
    const th = (smileData && smileData.aft) || {};
    $('#smAftersWrap').hidden = !afs.length;
    const key = afs.map((a) => a.k + a.l).join('|') + '#' + Object.keys(th).join(',') + '#' + (mm.label || '') + busy;
    if (key !== smAftKey) {
      smAftKey = key;
      setHtml($('#smAfters'), afs.map((a) => `<button type="button" data-ak="${esc(a.k)}" class="${mm.has2 && mm.label === a.l ? 'on' : ''}" ${busy ? 'disabled' : ''}>`
        + (th[a.k] ? `<img src="data:image/jpeg;base64,${th[a.k]}" alt="">` : '<i></i>') + `<span>${esc(a.l)}</span></button>`).join(''));
    }
    $('#smMatchRun').textContent = busy ? '⏳ 정밀 매칭 중…' : mm.made ? '🎯 다시 매칭' : '🎯 정밀 매칭 시작';
    $('#smP2Label').textContent = mm.has2 ? '2번: ' + (mm.label || '보철 사진') : '2번 보철 사진을 올리거나 지금 결과를 쓰세요';
    $('#smMatchMsg').textContent = !mm.ok ? '⚠ 이 태블릿에서는 정밀 매칭을 쓸 수 없어요 (안드로이드 태블릿 필요)' : !sm.has ? '먼저 위에서 미소 사진(1번)을 올려 주세요' : mm.step || '';
  }
}
function smRect() {
  const im = $('#smImg'), box = $('#smViewBox').getBoundingClientRect();
  const iw = im.naturalWidth || 4, ih = im.naturalHeight || 3;
  const k = Math.min(box.width / iw, box.height / ih);
  return { x: (box.width - iw * k) / 2, y: (box.height - ih * k) / 2, w: iw * k, h: ih * k };
}
$('#smOpen').addEventListener('click', () => { smOpen = true; smTab = smileData && smileData.m3 && state.smile && state.smile.match && state.smile.match.pick ? 'm' + state.smile.match.pick : 'area'; showSmileImg(); render(); });
document.querySelectorAll('#smMTabs button').forEach((b) => b.addEventListener('click', () => { smTab = b.dataset.m; showSmileImg(); }));
$('#smPick').addEventListener('click', () => { if (smTab[0] !== 'm') return; cmd('matchPick', Number(smTab.slice(1))); smOpen = false; render(); });
$('#smP2After').addEventListener('click', () => cmd('matchUseAfter'));
$('#smAfters').addEventListener('click', (e) => { const b = e.target.closest('[data-ak]'); if (b && !b.disabled) cmd('matchUseResult', b.dataset.ak); });
$('#smMatchRun').addEventListener('click', () => { smMWaiting = true; smMSawBusy = false; cmd('matchRun'); $('#smMatchMsg').textContent = '🎯 정밀 매칭을 시작합니다…'; });
$('#smTabArea').addEventListener('click', () => { smTab = 'area'; showSmileImg(); });
$('#smTabResult').addEventListener('click', () => { smTab = 'result'; showSmileImg(); });
$('#smClose').addEventListener('click', () => { smOpen = false; render(); });
$('#smAuto').addEventListener('click', () => cmd('smileAuto'));
$('#smUndo').addEventListener('click', () => cmd('smileUndo'));
$('#smClear').addEventListener('click', () => cmd('smileClear'));
$('#smMake').addEventListener('click', () => { smWaiting = true; smSawBusy = false; cmd('smileMake'); $('#smMsg').textContent = '😊 미소에 입히는 중…'; });
$('#smCanvas').addEventListener('click', (e) => {
  if (!(state && state.smile && state.smile.has) || smTab === 'result') return;
  const r = smRect(), b = $('#smCanvas').getBoundingClientRect();
  const x = (e.clientX - b.left - r.x) / r.w, y = (e.clientY - b.top - r.y) / r.h;
  if (x < 0 || y < 0 || x > 1 || y > 1) return;
  cmd('smileTap', { x: Math.round(x * 1000) / 1000, y: Math.round(y * 1000) / 1000 });
});
// 사진 파일 → 긴 변 2400 JPEG base64 → 태블릿으로
async function sendPhoto(e, cmdName, msgEl, what) {
  const fs = [...(e.target.files || [])];
  e.target.value = '';
  // 여러 장: 고른 차례대로 하나씩 (태블릿 비교 목록에 차례대로 쌓임)
  for (const f of (cmdName === 'matchPhoto' ? fs.slice(0, 1) : fs)) await sendOne(f, cmdName, msgEl, what);
}
async function sendOne(f, cmdName, msgEl, what) {
  try {
    $(msgEl).textContent = what + '을 태블릿으로 보내는 중…';
    const bmp = await createImageBitmap(f, { imageOrientation: 'from-image' });
    const k = Math.min(1, 2400 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    cmd(cmdName, c.toDataURL('image/jpeg', 0.92).split(',')[1]);
  } catch (err) {
    console.error(err);
    $(msgEl).textContent = '사진을 보내지 못했습니다 · 다른 사진으로 시도해 주세요';
  }
}
$('#smFile').addEventListener('change', (e) => sendPhoto(e, 'smilePhoto', '#smMsg', '미소 사진'));
$('#pickFile').addEventListener('change', (e) => sendPhoto(e, 'extraPhoto', '#pickMsg', '사진'));
$('#smP2File').addEventListener('change', (e) => sendPhoto(e, 'matchPhoto', '#smMatchMsg', '보철 사진'));

// =============================================================================
// 🖼 원본 2슬롯 (v3.35): 원본 1 미소 · 원본 2 개구기 · 변환할 사진 고르기 · 2단계 최종 미소
// =============================================================================
let slotImg = {}, slotUploadTo = 0, slotReqAt = 0;
const STEPS = ['사진', '치아 고르기', '치료 정하기', 'After 만들기', '다듬기', 'Final Smile', '저장'];
function renderStepBar() {
  const ui = state && state.ui, el = $('#stepBar');
  el.hidden = true; // v3.43: 단계 표시줄 숨김 (사용자 요청)
  if (el.hidden) return;
  const key = ui.step + '|' + locked();
  if (el.dataset.key === key) return;
  el.dataset.key = key;
  el.innerHTML = STEPS.map((s, i) => `<button type="button" data-step="${i + 1}" class="${ui.step === i + 1 ? 'on' : ''}">${i + 1} ${s}</button>`).join('<i>›</i>');
}
$('#stepBar').addEventListener('click', (e) => { const b = e.target.closest('[data-step]'); if (b) cmd('step', Number(b.dataset.step)); });
$('#baseSel').addEventListener('change', (e) => {
  const [k, n] = e.target.value.split(':').map(Number);
  cmd('basePick', { k, n });
  e.target.blur();
});
$('#newCaseBtn').addEventListener('click', () => {
  if (state && state.hasAfter && !locked() && !confirm('지금 작업을 아직 저장하지 않았어요 (저장하지 않으면 환자 기록에 남지 않아요).\n새 작업을 시작할까요?')) return;
  cmd('newCase');
});
function renderSlots() {
  renderStepBar();
  const bar = $('#slotBar'); if (!bar) return;
  const sl = state && state.slots;
  bar.hidden = !sl || !!state.briefing || locked();
  if (bar.hidden) return;
  const fin = sl.final || {};
  // 카드 사진이 안 왔으면 태블릿에 다시 요청 (5초에 한 번)
  if (((sl.s1 && !slotImg.s1) || (sl.s2 && !slotImg.s2)) && Date.now() - slotReqAt > 5000) { slotReqAt = Date.now(); cmd('slotImgReq'); }
  for (const k of [1, 2]) {
    const b = bar.querySelector(`.slot[data-slot="${k}"]`);
    const has = !!sl['s' + k], sel = sl.cur === k;
    const th = slotImg['s' + k];
    const im = b.querySelector('img');
    im.hidden = !th; if (th) im.src = 'data:image/jpeg;base64,' + th;
    b.querySelector('.ph').hidden = !!th;
    b.classList.toggle('on', sel);
    b.disabled = !!state.converting || !!fin.busy;
    b.querySelector('small').textContent = !has ? '눌러서 사진 올리기' : sel ? '변환할 사진 (선택됨) · 우클릭: 사진 바꾸기' : '눌러서 이 사진 변환 · 우클릭: 사진 바꾸기';
  }
  $('#finalBtn').disabled = !fin.can || !!fin.busy;
  $('#finalBtn').textContent = fin.busy ? '⏳ 2단계 만드는 중…' : '✨ 2단계 · 최종 미소 만들기';
  $('#finalNote').textContent = fin.msg || (!sl.s1 ? '원본 1(미소)을 넣고 1단계 After를 만들면 2단계를 할 수 있어요'
    : !fin.can ? '1단계: 변환할 사진을 고르고 [After 변환하기]' : '원본 1 + After 치열 → 입술·얼굴 그대로, 치아만 바꿔요');
}
$('#slotBar').addEventListener('click', (e) => {
  const b = e.target.closest('.slot'); if (!b || b.disabled || !state || !state.slots) return;
  const k = Number(b.dataset.slot);
  if (e.target.closest('[data-cam]')) { camOpen(k); return; } // 📷 이 카드로 촬영
  if (e.target.closest('[data-file]')) { slotUploadTo = k; $('#slotFile').click(); return; } // 📁 PC 파일
  const rot = e.target.closest('[data-rot]');
  if (rot) { if (state.slots['s' + k]) cmd('slotRotate', { s: k, d: Number(rot.dataset.rot) }); return; } // ⟲ ⟳ 사진 돌리기
  if (!state.slots['s' + k]) { camOpen(k); return; } // 빈 카드 → 바로 촬영 (파일은 📁)
  cmd('slotSelect', k);
});
$('#slotBar').addEventListener('contextmenu', (e) => {
  const b = e.target.closest('.slot'); if (!b || b.disabled) return;
  e.preventDefault(); slotUploadTo = Number(b.dataset.slot); $('#slotFile').click();
});
$('#slotFile').addEventListener('change', async (e) => {
  const f = e.target.files && e.target.files[0]; e.target.value = '';
  if (!f || !slotUploadTo) return;
  try {
    const bmp = await createImageBitmap(f, { imageOrientation: 'from-image' });
    const k = Math.min(1, 2400 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    cmd('slotPhoto', { s: slotUploadTo, b: c.toDataURL('image/jpeg', 0.92).split(',')[1] });
    $('#finalNote').textContent = `원본 ${slotUploadTo} 사진을 태블릿으로 보내는 중…`;
  } catch (err) { console.error(err); $('#finalNote').textContent = '사진을 보내지 못했습니다'; }
});
$('#finalBtn').addEventListener('click', () => { cmd('finalSmile'); $('#finalNote').textContent = '✨ 2단계를 시작합니다…'; });

// =============================================================================
// 💾 PC 폴더에 환자 기록 자동 저장 (v3.34) — 크롬·엣지 File System Access
//   환자이름 / 2026-11-24 14시30분 상담 (치료) / 원본·결과·미소·상담내용.txt
//   환자이름 / 치료완성 /  ← 실제 보철·교정 완성 사진 넣는 곳
// =============================================================================
const PC_MANIFEST = '_B&A 기록목록.json';
let pcDir = null, pcDirState = 'none', pcManifest = { since: 0, recs: {} };
let pcQueue = [], pcBusy = null, pcBusyTimer = 0;
function pcIdb() {
  return new Promise((res, rej) => {
    const r = indexedDB.open('bna-pc', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('kv');
    r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
  });
}
async function kvGet(k) {
  try { const d = await pcIdb(); return await new Promise((res) => { const q = d.transaction('kv').objectStore('kv').get(k); q.onsuccess = () => res(q.result); q.onerror = () => res(null); }); } catch (e) { return null; }
}
async function kvSet(k, v) {
  try { const d = await pcIdb(); await new Promise((res) => { const t = d.transaction('kv', 'readwrite'); t.objectStore('kv').put(v, k); t.oncomplete = res; t.onerror = res; }); } catch (e) { /* 저장 못 해도 이번 실행에는 사용 */ }
}
async function pcPerm(h, ask) {
  if (!h.queryPermission) return true;
  const o = { mode: 'readwrite' };
  let p = await h.queryPermission(o);
  if (p === 'granted') return true;
  if (ask && h.requestPermission) p = await h.requestPermission(o);
  return p === 'granted';
}
async function pcSaveManifest() {
  const w = await (await pcDir.getFileHandle(PC_MANIFEST, { create: true })).createWritable();
  await w.write(JSON.stringify(pcManifest, null, 1)); await w.close();
}
async function pcLoadManifest() {
  try {
    const f = await (await pcDir.getFileHandle(PC_MANIFEST)).getFile();
    pcManifest = JSON.parse(await f.text()); pcManifest.recs = pcManifest.recs || {};
  } catch (e) {
    pcManifest = { since: Date.now(), recs: {} }; // 이 시각 이후 저장되는 기록부터 자동
    await pcSaveManifest();
  }
}
async function pcUse(h, ask) {
  pcDir = h;
  if (!(await pcPerm(h, ask))) { pcDirState = 'perm'; renderPcSave(); return; }
  pcDirState = 'on';
  await pcLoadManifest();
  renderPcSave(); pcCheck(false);
}
function pcMissing(all) {
  const items = (records && records.items) || [];
  return items.filter((r) => {
    const m = pcManifest.recs[r.id];
    if (m) return r.sig && m.sig !== r.sig; // 결과·미소 사진이 늘어난 기록은 다시
    return all || Date.parse(r.savedAt) >= (pcManifest.since || 0) - 60000;
  }).map((r) => r.id);
}
function pcCheck(all) {
  if (pcDirState !== 'on') { renderPcSave(); return; }
  for (const id of pcMissing(all)) if (!pcQueue.includes(id) && pcBusy !== id) pcQueue.push(id);
  renderPcSave(); pcPump();
}
function pcPump() {
  if (pcBusy || !pcQueue.length || !db || pcDirState !== 'on') return;
  pcBusy = pcQueue.shift();
  cmd('recSyncReq', pcBusy);
  clearTimeout(pcBusyTimer);
  pcBusyTimer = setTimeout(() => { pcBusy = null; renderPcSave(); pcPump(); }, 90000); // 응답이 없으면 다음 것
  renderPcSave();
}
function pcB64(b) { const s = atob(b); const u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return u; }
async function pcWriteFile(dir, name, data) {
  const w = await (await dir.getFileHandle(name, { create: true })).createWritable();
  await w.write(data); await w.close();
}
async function pcGot(v) {
  if (!v || !v.id || v.id !== pcBusy || !pcDir) return;
  clearTimeout(pcBusyTimer);
  try {
    if (!v.missing) {
      const [pname, cname] = v.folder || ['이름 없음', v.id];
      const pd = await pcDir.getDirectoryHandle(pname, { create: true });
      await pd.getDirectoryHandle('치료완성', { create: true });
      const cd = await pd.getDirectoryHandle(cname, { create: true });
      for (const f of v.files || []) await pcWriteFile(cd, f.n, pcB64(f.b));
      await pcWriteFile(cd, '상담내용.txt', new Blob(['﻿' + (v.memo || '')], { type: 'text/plain' }));
      pcManifest.recs[v.id] = { sig: v.sig, folder: pname + '/' + cname, at: Date.now() };
      await pcSaveManifest();
      pcToast(`💾 ${pname} 님 기록을 PC 폴더(${pcDir.name} › ${pname})에 저장했습니다`);
    }
  } catch (e) {
    console.error(e);
    pcToast('💾 PC 폴더에 저장하지 못했습니다 · 저장 폴더를 다시 연결해 주세요');
    pcDirState = 'perm';
  }
  remove(ref(db, 'rooms/' + room + '/recSync')).catch(() => {});
  pcBusy = null; renderPcSave(); pcPump();
}
function pcToast(m) {
  const t = $('#toast'); if (!t) return;
  t.textContent = m; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { t.hidden = true; }, 5000);
}
function renderPcSave() {
  const ok = 'showDirectoryPicker' in window || !!window.__pcDirOverride;
  const st = $('#pcSaveState'); if (!st) return;
  const n = Object.keys(pcManifest.recs || {}).length;
  const left = pcDirState === 'on' ? pcMissing(true).length : 0;
  st.textContent = !ok ? '이 브라우저는 폴더 저장을 못 해요 (크롬·엣지에서 열어 주세요)'
    : pcDirState === 'on' ? `켜짐 · 📁 ${pcDir.name} · 저장된 기록 ${n}건${pcBusy ? ' · 저장 중…' : ''}${left ? ` · 아직 PC에 없는 기록 ${left}건` : ''}`
      : pcDirState === 'perm' ? `📁 ${pcDir ? pcDir.name : ''} · 다시 연결이 필요해요 ([저장 폴더 다시 연결])`
        : '아직 저장 폴더를 고르지 않았어요';
  $('#pcPick').disabled = !ok;
  $('#pcPick').textContent = pcDirState === 'none' ? '📁 저장 폴더 고르기' : '📁 저장 폴더 바꾸기';
  $('#pcReauth').hidden = pcDirState !== 'perm';
  $('#pcCatch').hidden = !(pcDirState === 'on' && left > 0);
  $('#pcCatch').textContent = `⬇ 빠진 기록 PC로 가져오기 (${left}건)`;
}
$('#pcPick').addEventListener('click', async () => {
  try {
    const h = window.__pcDirOverride || (await window.showDirectoryPicker({ id: 'bna-records', mode: 'readwrite' }));
    await kvSet('pcDir', h);
    await pcUse(h, true);
    pcToast(`💾 이제 환자 기록을 PC 폴더 [${h.name}]에도 자동 저장합니다`);
  } catch (e) { if (e && e.name !== 'AbortError') pcToast('폴더를 고르지 못했습니다'); }
});
$('#pcReauth').addEventListener('click', async () => { if (pcDir) await pcUse(pcDir, true); });
$('#pcCatch').addEventListener('click', () => pcCheck(true));
(async () => { const h = window.__pcDirOverride || (await kvGet('pcDir')); if (h) await pcUse(h, false); else renderPcSave(); })();

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
start();

document.addEventListener('click', (e) => { if (e.target && e.target.id === 'savePick') { e.preventDefault(); openOv('recOv'); renderRecords(); } });
