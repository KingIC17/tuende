const SHELL_CACHE = 'tuende-shell-v8';
const IMAGE_CACHE = 'tuende-images-v1';
// The map libraries (unpkg), map fonts and the map tiles already seen (OpenFreeMap vector tiles, or OpenStreetMap
// images on phones without WebGL), so the map still opens without internet.
// Only tiles the person viewed are kept (no bulk download), up to MAX_TILES.
const MAP_CACHE = 'tuende-map-v1';
const MAX_TILES = 1200;
// Provinces saved for use without internet (the person chose them): map tiles kept under their z/x/y, never trimmed.
const OFFLINE_CACHE = 'tuende-offline-v1';
const tileKey = (url) => {
    const m = String(url).match(/tiles\.openfreemap\.org\/planet\/[^/]+\/(\d+)\/(\d+)\/(\d+)\.pbf/);
    return m ? `https://tuende.offline/tile/${m[1]}/${m[2]}/${m[3]}.pbf` : null;
};
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
                .filter((key) => key !== SHELL_CACHE && key !== IMAGE_CACHE && key !== MAP_CACHE && key !== OFFLINE_CACHE)
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
    // A saved province has this tile (perhaps from an older weekly tile set, which looks the same).
    const key = tileKey(request.url);
    if (key) {
        const saved = await (await caches.open(OFFLINE_CACHE)).match(key);
        if (saved) return saved;
    }
    const response = await fetch(request);
    if (response.ok) {
        await cache.put(request, response.clone());
        const keys = await cache.keys();
        const tiles = keys.filter((k) => k.url.includes('tile.openstreetmap.org') || k.url.includes('tiles.openfreemap.org/planet/'));
        if (tiles.length > MAX_TILES) await Promise.all(tiles.slice(0, tiles.length - MAX_TILES).map((k) => cache.delete(k)));
    }
    return response;
}

// The tile list (TileJSON) names this week's tile set, so it is read fresh when online and from the cache offline.
async function mapNetworkFirst(request) {
    const cache = await caches.open(MAP_CACHE);
    try {
        const response = await fetch(request);
        if (response.ok) cache.put(request, response.clone());
        return response;
    } catch {
        return (await cache.match(request)) || Response.error();
    }
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
    } else if (url.hostname === 'tiles.openfreemap.org' && url.pathname === '/planet') {
        event.respondWith(mapNetworkFirst(request));
    } else if (url.hostname === 'unpkg.com' || url.hostname === 'tile.openstreetmap.org' || url.hostname === 'tiles.openfreemap.org') {
        event.respondWith(mapCacheFirst(request));
    }
});

// Saves a province: its map tiles (OFFLINE_CACHE) and the map library, tile list and fonts (MAP_CACHE),
// six downloads at a time, telling the page how far it got.
async function saveArea({ slug, tiles, extra }, client) {
    const offline = await caches.open(OFFLINE_CACHE);
    const map = await caches.open(MAP_CACHE);
    const jobs = [...tiles.map((url) => ({ url, key: tileKey(url), cache: offline })), ...extra.map((url) => ({ url, key: url, cache: map }))]
        .filter((job) => job.key);
    const total = jobs.length;
    let done = 0;
    let failed = 0;
    let bytes = 0;
    const report = (final) => client?.postMessage({ type: 'area-progress', slug, done, total, failed, bytes, final });
    const worker = async () => {
        while (jobs.length) {
            const job = jobs.shift();
            try {
                if (!(await job.cache.match(job.key))) {
                    const response = await fetch(job.url, { mode: 'cors' });
                    if (!response.ok) throw new Error(String(response.status));
                    bytes += (await response.clone().blob()).size;
                    await job.cache.put(job.key, response);
                }
            } catch {
                failed++;
            }
            done++;
            if (done % 8 === 0) report(false);
        }
    };
    await Promise.all(Array.from({ length: 6 }, worker));
    await offline.put(`https://tuende.offline/area/${slug}`, new Response(JSON.stringify({ tiles: tiles.map(tileKey), saved: Date.now() })));
    report(true);
}

// Removes a saved province, keeping the tiles another saved province also uses.
async function deleteArea(slug) {
    const offline = await caches.open(OFFLINE_CACHE);
    const areas = (await offline.keys()).filter((k) => k.url.startsWith('https://tuende.offline/area/'));
    const keep = new Set();
    let mine = [];
    for (const req of areas) {
        const data = await (await offline.match(req)).json().catch(() => ({ tiles: [] }));
        if (req.url.endsWith(`/area/${slug}`)) mine = data.tiles || [];
        else (data.tiles || []).forEach((k) => keep.add(k));
    }
    await Promise.all(mine.filter((k) => k && !keep.has(k)).map((k) => offline.delete(k)));
    await offline.delete(`https://tuende.offline/area/${slug}`);
}

self.addEventListener('message', (event) => {
    if (event.data?.type === 'save-area') event.waitUntil(saveArea(event.data, event.source));
    else if (event.data?.type === 'delete-area') event.waitUntil(deleteArea(String(event.data.slug)));
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
