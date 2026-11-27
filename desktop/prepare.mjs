import { cp, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const site = 'https://serveyourself-app.vercel.app';
const backend = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const root = fileURLToPath(new URL('../', import.meta.url));
const web = new URL('web/', import.meta.url);
const response = await fetch(`${site}/app.js`, { redirect: 'error', signal: AbortSignal.timeout(15000) });
if (!response.ok) throw new Error('No se pudo leer la configuración pública de ServeYourself.');
const source = await response.text();
const publishedUrl = JSON.parse(source.match(/const SUPABASE_URL = ("[^"]+");/)?.[1] ?? 'null');
const key = JSON.parse(source.match(/const SUPABASE_KEY = ("[^"]+");/)?.[1] ?? 'null');
if (publishedUrl !== backend || !/^sb_publishable_[A-Za-z0-9_-]+$/.test(key ?? '')) {
    throw new Error('La configuración publicada no coincide con el Supabase esperado.');
}
const result = spawnSync(process.execPath, ['scripts/build.mjs'], {
    cwd: root,
    stdio: 'inherit',
    env: { ...process.env, VERCEL_ENV: 'production', SUPABASE_URL: backend, SUPABASE_PUBLISHABLE_KEY: key }
});
if (result.status !== 0) throw result.error ?? new Error('Falló la compilación de ServeYourself.');
await rm(web, { recursive: true, force: true });
await cp(new URL('../dist/', import.meta.url), web, { recursive: true });
