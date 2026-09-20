import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const htmlFiles = fs.readdirSync(new URL('..', import.meta.url)).filter(file => file.endsWith('.html'));
const app = read('app.js');
const pos = read('pos.html');
const manifest = JSON.parse(read('manifest.webmanifest'));
const sw = read('sw.js');

for (const file of htmlFiles) {
    const html = read(file);
    assert.match(html, /<script src="app\.js"><\/script>/, `${file} debe cargar la navegación y soporte PWA compartidos`);
    assert.match(html, /<meta name="viewport"/i, `${file} debe adaptarse a dispositivos móviles`);
}

assert.match(app, /ensureGlobalBackButton/, 'Debe existir un regreso común para pantallas sin navegación propia');
assert.match(app, /\[data-sy-back\], \.sy-restaurant-nav/, 'El regreso común debe evitar botones duplicados');
assert.match(app, /display-mode: standalone/, 'La instalación debe detectar cuando la PWA ya está abierta como aplicación');
assert.match(app, /apple-mobile-web-app-capable/, 'iPhone debe recibir metadatos de aplicación web');
assert.match(app, /beforeinstallprompt/, 'Android y escritorio deben ofrecer el instalador del navegador');

assert.equal(manifest.id, '/');
assert.equal(manifest.scope, '/');
assert.equal(manifest.display, 'standalone');
assert.equal(manifest.icons[0].src, '/app-icon.svg');
assert.equal(manifest.icons[0].sizes, 'any');
assert.ok(fs.existsSync(new URL('../app-icon.svg', import.meta.url)), 'El icono declarado debe existir');
assert.match(sw, /manifest\.webmanifest/);
assert.match(sw, /app-icon\.svg/);

assert.match(pos, /create_or_append_pos_order/, 'Las mesas deben reutilizar su cuenta abierta');
assert.doesNotMatch(pos, /pending-panel|register_pos_payment|order_payments/, 'Meseros no debe contener funciones de caja');
assert.match(read('caja.html'), /register_pos_payment/, 'Los pagos manuales deben permanecer en Caja');

for (const provider of ['google', 'facebook', 'apple']) {
    assert.match(read('index.html'), new RegExp(`signInWithProvider\\('${provider}'`));
    assert.match(read('registro.html'), new RegExp(`registerWithProvider\\('${provider}'`));
}

console.log(`Calidad PWA, navegación y POS: OK (${htmlFiles.length} pantallas revisadas)`);
