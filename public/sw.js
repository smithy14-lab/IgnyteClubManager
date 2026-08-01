/*
 * Ignyte Club Manager — service worker
 *
 * Strategy:
 *  - App pages (navigations): network-first, falling back to the cached copy,
 *    then to /offline when the page was never cached.
 *  - Hashed build assets (/_astro/*): cache-first (immutable file names).
 *  - Icons/manifest: cache-first.
 *  - Supabase REST GETs: network-first with cache fallback, so dashboards can
 *    show the last-known bookings/progress while offline. Auth and writes are
 *    never cached.
 */
const VERSION = 'v6';
const SHELL_CACHE = `ignyte-shell-${VERSION}`;
const ASSET_CACHE = `ignyte-assets-${VERSION}`;
const DATA_CACHE = `ignyte-data-${VERSION}`;

const SHELL_URLS = [
  '/',
  '/offline',
  '/about',
  '/pricing',
  '/contact',
  '/clubs',
  '/start',
  '/club',
  '/login',
  '/dashboard',
  '/book',
  '/bookings',
  '/classes',
  '/money',
  '/athletes',
  '/progress',
  '/coach',
  '/coach/classes',
  '/admin',
  '/admin/classes',
  '/admin/money',
  '/site.webmanifest',
  '/icon-192.png',
  '/icon-512.png',
  '/favicon.svg',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      .then((cache) => cache.addAll(SHELL_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((k) => ![SHELL_CACHE, ASSET_CACHE, DATA_CACHE].includes(k))
            .map((k) => caches.delete(k))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Supabase data reads — network first, cached fallback for offline viewing.
  if (url.hostname.endsWith('.supabase.co') && url.pathname.startsWith('/rest/')) {
    event.respondWith(
      fetch(request)
        .then((res) => {
          if (res.ok) {
            const copy = res.clone();
            caches.open(DATA_CACHE).then((cache) => cache.put(request, copy));
          }
          return res;
        })
        .catch(() => caches.match(request))
    );
    return;
  }

  // Never touch other cross-origin requests (auth, realtime, email...).
  if (url.origin !== self.location.origin) return;

  // Immutable hashed assets — cache first.
  if (url.pathname.startsWith('/_astro/') || /\.(png|svg|woff2?)$/.test(url.pathname)) {
    event.respondWith(
      caches.match(request).then(
        (cached) =>
          cached ||
          fetch(request).then((res) => {
            const copy = res.clone();
            caches.open(ASSET_CACHE).then((cache) => cache.put(request, copy));
            return res;
          })
      )
    );
    return;
  }

  // Page navigations — network first, cache fallback, then offline page.
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((res) => {
          const copy = res.clone();
          caches.open(SHELL_CACHE).then((cache) => cache.put(request, copy));
          return res;
        })
        .catch(async () => (await caches.match(request)) || caches.match('/offline'))
    );
  }
});
