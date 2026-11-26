import { strict as assert } from 'node:assert';

const app = 'https://serveyourself-app.vercel.app';
const backend = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const request = (url, options = {}) => fetch(url, { ...options, signal: AbortSignal.timeout(15000) });
async function get(path) {
    const response = await request(app + path);
    assert.equal(response.status, 200, `ServeYourself ${path} devolvió HTTP ${response.status}`);
    return response.text();
}

const [, , config] = await Promise.all([get('/'), get('/vendor/supabase.js'), get('/app.js')]);
assert.equal(JSON.parse(config.match(/const SUPABASE_URL = ("[^"]+");/)?.[1] || 'null'), backend, 'El dominio público apunta a otro backend');
const key = JSON.parse(config.match(/const SUPABASE_KEY = ("[^"]+");/)?.[1] || 'null');
assert.ok(key?.startsWith('sb_publishable_'), 'Falta la clave pública en el build');

const [catalog, qr] = await Promise.all([
    request(backend + '/rest/v1/public_restaurants?select=id&or=(bank_name.not.is.null,bank_account_holder.not.is.null,bank_clabe.not.is.null)&limit=1', { headers:{apikey:key} }),
    request(backend + '/functions/v1/guest-pickup', { method:'OPTIONS', headers:{Origin:app} })
]);
assert.equal(catalog.status, 200, 'El catálogo público no está disponible');
assert.deepEqual(await catalog.json(), [], 'El catálogo contiene campos bancarios públicos');
assert.equal(qr.headers.get('access-control-allow-origin'), app, 'El menú QR no tiene autorización de origen');
assert.ok(qr.ok, 'La función del menú QR no responde');
console.log('Portada, SDK, catálogo público y origen del menú QR verificados.');
