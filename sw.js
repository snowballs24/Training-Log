const CACHE = 'workout-cache-v10';
const ASSETS = [
  './',
  './index.html',
  './backup.js',
  './workout-utils.js',
  './manifest.webmanifest',
  './icons/icon-512.png',
  './icons/front.png',
  './icons/back.png',
  './sounds/ding.mp3',
  './sounds/beep.mp3',
  './sounds/chime.mp3'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === location.origin) {
    e.respondWith(caches.match(req).then(cached => cached || fetch(req)));
  }
});

self.addEventListener('message', e => {
  if (e.data && e.data.action === 'skipWaiting') self.skipWaiting();
});
