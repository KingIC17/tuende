const SHELL_CACHE = 'tuende-shell-v7';
const IMAGE_CACHE = 'tuende-images-v1';
// The map library (unpkg) and the map tiles already seen, so the map still opens without internet.
// Only tiles the person viewed are kept (no bulk download, as OpenStreetMap asks), up to MAX_TILES.
const MAP_CACHE = 'tuende-map-v1';
const MAX_TILES = 1200;
const SHELL = [
    './',
    './manifest.json',
    './icon-192.png',
    './icon-512.png',
    './apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
    event.waitUntil(caches.open(SHELL_CACHE).then((cache) => cache.addAll(SHELL)));
    self.skipWaiting();
});

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys()
            .then((keys) => Promise.all(keys
                .filter((key) => key !== SHELL_CACHE && key !== IMAGE_CACHE && key !== MAP_CACHE)
                .map((key) => caches.delete(key))))
            .then(() => self.clients.claim())
    );
});

async function networkFirst(request) {
    const cache = await caches.open(SHELL_CACHE);
    try {
        const response = await fetch(request.url, { cache: 'no-cache', credentials: 'same-origin' });
        if (response.ok) cache.put(request, response.clone());
        return response;
    } catch {
        return (await cache.match(request, { ignoreSearch: true }))
            || (request.mode === 'navigate' ? cache.match('./') : Response.error());
    }
}

async function imageCacheFirst(request) {
    const cache = await caches.open(IMAGE_CACHE);
    const hit = await cache.match(request);
    if (hit) return hit;
    const response = await fetch(request);
    if (response.ok) cache.put(request, response.clone());
    return response;
}

async function mapCacheFirst(request) {
    const cache = await caches.open(MAP_CACHE);
    const hit = await cache.match(request);
    if (hit) return hit;
    const response = await fetch(request);
    if (response.ok) {
        await cache.put(request, response.clone());
        const keys = await cache.keys();
        const tiles = keys.filter((k) => k.url.includes('tile.openstreetmap.org'));
        if (tiles.length > MAX_TILES) await Promise.all(tiles.slice(0, tiles.length - MAX_TILES).map((k) => cache.delete(k)));
    }
    return response;
}

self.addEventListener('fetch', (event) => {
    const { request } = event;
    if (request.method !== 'GET') return;
    const url = new URL(request.url);

    if (url.origin === self.location.origin && (url.pathname.includes('/photos/') || url.pathname.includes('/fonts/') || url.pathname.includes('/avatars/'))) {
        event.respondWith(imageCacheFirst(request));
    } else if (url.origin === self.location.origin) {
        event.respondWith(networkFirst(request));
    } else if (url.hostname === 'images.unsplash.com' || url.hostname.endsWith('wikimedia.org')) {
        event.respondWith(imageCacheFirst(request));
    } else if (url.hostname === 'unpkg.com' || url.hostname === 'tile.openstreetmap.org') {
        event.respondWith(mapCacheFirst(request));
    }
});

// The page sends the list of venue photos so they are available offline before being viewed.
self.addEventListener('message', (event) => {
    if (event.data?.type !== 'warm-images') return;
    event.waitUntil(caches.open(IMAGE_CACHE).then((cache) =>
        Promise.all(event.data.urls.map(async (url) => {
            if (await cache.match(url)) return;
            try {
                const response = await fetch(url, { mode: 'cors' });
                if (response.ok) await cache.put(url, response);
            } catch {}
        }))
    ));
});
