// Push failure must not prevent the app's own offline support from installing.
try { importScripts('https://cdn.onesignal.com/sdks/web/v16/OneSignalSDK.sw.js'); }
catch (error) { console.warn('Push no disponible; soporte sin conexión activo.', error); }
const CACHE = 'serveyourself-shell-v24';
const SHELL = ['/index.html','/registro.html','/recuperar.html','/privacidad.html','/terminos.html','/eliminar-cuenta.html','/menu.html','/admin.html','/pos.html','/caja.html','/cocina.html','/delivery.html','/repartidor.html','/repartidor-registro.html','/delivery-tracking.html','/platform-admin.html','/funciones.html','/cuenta.html','/tailwind.generated.css','/styles.css','/runtime.js','/app.js','/app-config.js','/manifest.webmanifest','/app-icon.svg','/app-icon-192.png','/app-icon-512.png','/logo.png'];
self.addEventListener('install', event => event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting())));
self.addEventListener('activate', event => event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key.startsWith('serveyourself-shell-') && key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim())));
self.addEventListener('fetch', event => {
    const request = event.request, url = new URL(request.url);
    if (request.method !== 'GET' || url.origin !== self.location.origin) return;
    // Cache only public, static application files, never arbitrary same-origin APIs.
    if (!(request.mode === 'navigate' || /\.(html|js|css|png|svg|webmanifest)$/.test(url.pathname))) return;
    const network = fetch(request);
    event.waitUntil(network.then(async response => {
        if (response.ok && !response.redirected && response.type !== 'opaque') {
            const copy = response.clone();
            const cache = await caches.open(CACHE);
            await cache.put(request, copy);
        }
    }).catch(() => {}));
    event.respondWith(network.catch(async () => {
        const cached = await caches.match(request);
        if (cached) return cached;
        if (request.mode === 'navigate') {
            return new Response('<!doctype html><html lang="es"><meta name="viewport" content="width=device-width"><title>Sin conexión</title><h1>Sin conexión</h1><p>No se puede abrir esta pantalla. Recupera la conexión y vuelve a intentarlo.</p><button type="button" onclick="location.reload()">Reintentar</button></html>', { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
        }
        return new Response('Recurso no disponible sin conexión', { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
    }));
});
