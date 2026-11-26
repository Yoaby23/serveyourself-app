import { copyFile, mkdir, readdir, rm, readFile, writeFile } from 'node:fs/promises';
import { extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = resolve(root, 'dist');
const productionOrigin = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const productionAppId = 'c77aa3bf-9fbf-4928-9441-18093c934dcd';
const environment = process.env.VERCEL_ENV || 'development';
if (process.env.VERCEL === '1' && !['production', 'preview', 'development'].includes(process.env.VERCEL_ENV)) {
    throw new Error('Expón VERCEL_ENV para identificar el entorno de este despliegue.');
}

const url = new URL(process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || 'http://127.0.0.1:54321');
const key = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
const localHost = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
const hosted = url.protocol === 'https:' && !localHost;
if (url.username || url.password || url.pathname !== '/' || url.search || url.hash ||
    (!hosted && !(environment === 'development' && localHost && url.protocol === 'http:'))) {
    throw new Error('Configura una URL de Supabase válida para este entorno.');
}
const isPublicKey = /^sb_publishable_[A-Za-z0-9_-]+$/.test(key || '');
let isAnonJwt = false;
if (!isPublicKey && key?.split('.').length === 3) {
    try { isAnonJwt = JSON.parse(Buffer.from(key.split('.')[1], 'base64url')).role === 'anon'; } catch {}
}
if (!isPublicKey && !isAnonJwt) throw new Error('Configura una clave publicable o anon de Supabase.');
if (environment !== 'production' && url.origin === productionOrigin) {
    throw new Error('Usa un proyecto Supabase aislado en desarrollo y Preview.');
}
const oneSignalAppId = process.env.VERCEL_ENV === 'production'
    ? process.env.ONESIGNAL_APP_ID || productionAppId
    : process.env.ONESIGNAL_APP_ID || '';
if (environment !== 'production' && oneSignalAppId === productionAppId) {
    throw new Error('Usa una aplicación OneSignal aislada fuera de producción.');
}
if (oneSignalAppId && !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(oneSignalAppId)) {
    throw new Error('Configura un identificador de OneSignal válido.');
}

await rm(output, { recursive: true, force: true });
await mkdir(resolve(output, 'vendor'), { recursive: true });
await copyFile(
    resolve(root, 'node_modules/@supabase/supabase-js/dist/umd/supabase.js'),
    resolve(output, 'vendor/supabase.js')
);
const assets = new Set(['.html', '.js', '.css', '.png', '.webp', '.svg', '.webmanifest']);
for (const entry of await readdir(root, { withFileTypes: true })) {
    if (entry.isFile() && assets.has(extname(entry.name))) {
        await copyFile(resolve(root, entry.name), resolve(output, entry.name));
    }
}
const appPath = resolve(output, 'app.js');
const appSource = await readFile(appPath, 'utf8');
await writeFile(appPath, appSource
    .replace("'__SY_SUPABASE_URL__'", () => JSON.stringify(url.origin))
    .replace("'__SY_SUPABASE_PUBLISHABLE_KEY__'", () => JSON.stringify(key)));
const configPath = resolve(output, 'app-config.js');
const configSource = await readFile(configPath, 'utf8');
await writeFile(configPath, configSource.replace("'__SY_ONESIGNAL_APP_ID__'", () => JSON.stringify(oneSignalAppId)));
