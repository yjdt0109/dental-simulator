// 바탕화면 앱 설치용 최소 서비스 워커 (캐시하지 않고 항상 최신 화면을 받음)
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
