importScripts('https://cdn.onesignal.com/sdks/web/v16/OneSignalSDK.sw.js');
const CACHE = 'serveyourself-shell-v17';
const SHELL = ['/index.html','/registro.html','/recuperar.html','/privacidad.html','/terminos.html','/eliminar-cuenta.html','/menu.html','/admin.html','/pos.html','/caja.html','/cocina.html','/delivery.html','/repartidor.html','/repartidor-registro.html','/delivery-tracking.html','/platform-admin.html','/tailwind.generated.css','/styles.css','/app.js','/app-config.js','/manifest.webmanifest','/app-icon.svg','/app-icon-192.png','/app-icon-512.png','/logo.png'];
self.addEventListener('install', event => event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting())));
self.addEventListener('activate', event => event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim())));
self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET' || new URL(event.request.url).origin !== self.location.origin) return;
  event.respondWith(fetch(event.request).then(response => { const copy=response.clone(); caches.open(CACHE).then(cache=>cache.put(event.request,copy)); return response; }).catch(()=>caches.match(event.request).then(cached=>cached||caches.match('/index.html'))));
});
