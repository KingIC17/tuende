const SHELL_CACHE = 'tuende-shell-v8';
const IMAGE_CACHE = 'tuende-images-v1';
// The map libraries (unpkg), map fonts and the map tiles already seen (OpenFreeMap vector tiles, or OpenStreetMap
// images on phones without WebGL), so the map still opens without internet.
// Only tiles the person viewed are kept (no bulk download), up to MAX_TILES.
const MAP_CACHE = 'tuende-map-v1';
const MAX_TILES = 1200;
// Provinces saved for use without internet (the person chose them): map tiles kept under their z/x/y, never trimmed.
const OFFLINE_CACHE = 'tuende-offline-v1';
// Small settings the page saves for the worker (the language of the message notifications).
const PREFS_CACHE = 'tuende-prefs-v1';
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
                .filter((key) => key !== SHELL_CACHE && key !== IMAGE_CACHE && key !== MAP_CACHE && key !== OFFLINE_CACHE && key !== PREFS_CACHE)
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

// Notifications for new chat messages. The push carries no content (nothing the person wrote passes through the
// push services): the worker only says there are new messages, in the language the page saved.
const PUSH_TEXT = {
    pt: 'Tem mensagens novas nas Conversas.',
    en: 'You have new messages in Chats.',
    fr: 'Vous avez de nouveaux messages dans Discussions.',
    es: 'Tiene mensajes nuevos en Conversaciones.'
};

// Calls: the notification is encrypted for this phone only (the push service cannot read it) and says who is calling.
const CALL_TEXT = {
    voice: { pt: 'Chamada de voz no Tuende. Toque para atender.', en: 'Voice call on Tuende. Tap to answer.', fr: 'Appel vocal sur Tuende. Touchez pour répondre.', es: 'Llamada de voz en Tuende. Toque para contestar.' },
    video: { pt: 'Videochamada no Tuende. Toque para atender.', en: 'Video call on Tuende. Tap to answer.', fr: 'Appel vidéo sur Tuende. Touchez pour répondre.', es: 'Videollamada en Tuende. Toque para contestar.' },
    group: { pt: '{name} está a ligar ao grupo. Toque para entrar.', en: '{name} is calling the group. Tap to join.', fr: '{name} appelle le groupe. Touchez pour rejoindre.', es: '{name} está llamando al grupo. Toque para unirse.' },
    missed: { pt: 'Chamada não atendida', en: 'Missed call', fr: 'Appel manqué', es: 'Llamada perdida' },
    missedGroup: { pt: 'Chamada de grupo de {name}, não atendida', en: 'Missed group call from {name}', fr: 'Appel de groupe manqué de {name}', es: 'Llamada de grupo perdida de {name}' }
};
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

self.addEventListener('push', (event) => {
    event.waitUntil((async () => {
        let data = null;
        try { data = event.data ? event.data.json() : null; } catch { data = null; }
        const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
        const visible = windows.find((c) => c.visibilityState === 'visible');
        let lang = 'pt';
        try {
            const saved = await (await caches.open(PREFS_CACHE)).match('/__prefs');
            if (saved) lang = (await saved.json()).lang || 'pt';
        } catch {}
        const pick = (texts) => texts[lang] || texts.pt;
        const name = (v) => String(v || '').slice(0, 60);
        if (data && (data.t === 'call' || data.t === 'call-end') && UUID.test(data.id || '') && UUID.test(data.c || '')) {
            const tag = `call-${data.id}`;
            const url = `./?page=conversas&c=${data.c}${data.t === 'call' ? `&call=${data.id}` : ''}`;
            // The app is open on screen: it rings by itself.
            if (visible && data.t === 'call') return;
            if (data.t === 'call') {
                await self.registration.showNotification(name(data.g || data.from) || 'Tuende', {
                    body: data.g ? pick(CALL_TEXT.group).replace('{name}', name(data.from)) : pick(CALL_TEXT[data.v ? 'video' : 'voice']),
                    icon: 'icon-192.png', tag, renotify: true, requireInteraction: true, vibrate: [500, 250, 500, 250, 500, 250, 500],
                    data: { url }
                });
                return;
            }
            // Nobody answered: the ringing notification becomes "missed call".
            const ringing = await self.registration.getNotifications({ tag });
            ringing.forEach((n) => n.close());
            await self.registration.showNotification(name(data.g || data.from) || 'Tuende', {
                body: data.g ? pick(CALL_TEXT.missedGroup).replace('{name}', name(data.from)) : pick(CALL_TEXT.missed),
                icon: 'icon-192.png', tag, renotify: false, silent: true, data: { url }
            });
            return;
        }
        // The app is open on screen: it updates the chat itself, no notification needed.
        if (visible) { visible.postMessage({ type: 'chat-push' }); return; }
        await self.registration.showNotification('Tuende', {
            body: pick(PUSH_TEXT),
            icon: 'icon-192.png',
            tag: 'tuende-chat',
            renotify: true,
            data: { url: './?page=conversas' }
        });
    })());
});

self.addEventListener('notificationclick', (event) => {
    event.notification.close();
    const url = new URL(event.notification.data?.url || './?page=conversas', self.registration.scope).href;
    event.waitUntil((async () => {
        const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
        const open = windows.find((c) => c.url.startsWith(self.registration.scope));
        if (open) {
            await open.focus();
            open.postMessage({ type: 'open-chats', url });
            return;
        }
        await self.clients.openWindow(url);
    })());
});
