import test from 'node:test';
import assert from 'node:assert/strict';
import { cp, mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { corsHeaders } from '../supabase/functions/_shared/cors.ts';

test('build emits only public configuration and refuses to point Preview at production', async t => {
    const workspace = await mkdtemp(join(tmpdir(), 'sy-build-'));
    t.after(() => rm(workspace, { recursive: true, force: true }));
    await mkdir(join(workspace, 'scripts'));
    for (const file of ['scripts/build.mjs', 'app.js', 'app-config.js', 'index.html', 'README.md']) {
        await cp(new URL('../' + file, import.meta.url), join(workspace, file));
    }

    const sdkPath = 'node_modules/@supabase/supabase-js/dist/umd/supabase.js';
    await mkdir(join(workspace, sdkPath, '..'), { recursive: true });
    await cp(new URL('../' + sdkPath, import.meta.url), join(workspace, sdkPath));

    const run = env => spawnSync(process.execPath, ['scripts/build.mjs'], {
        cwd: workspace,
        encoding: 'utf8',
        env: {
            VERCEL_ENV: 'preview',
            SUPABASE_URL: 'https://isolated-test.supabase.co',
            SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_fixture',
            SUPABASE_SERVICE_ROLE_KEY: 'qa-private-value',
            ...env
        }
    });

    assert.match(run({ SUPABASE_URL: 'https://spbgledcjwtqmlqdlpyx.supabase.co' }).stderr, /aislado/);
    assert.match(run({ SUPABASE_PUBLISHABLE_KEY: 'sb_secret_fixture' }).stderr, /publicable/);
    const built = run();
    assert.equal(built.status, 0, built.stderr);
    const emitted = await readFile(join(workspace, 'dist/app.js'), 'utf8');
    assert.match(emitted, /https:\/\/isolated-test\.supabase\.co/);
    assert.match(emitted, /sb_publishable_fixture/);
    assert.doesNotMatch(emitted, /qa-private-value|__SY_SUPABASE/);
    assert.deepEqual(await readFile(join(workspace, 'dist/vendor/supabase.js')), await readFile(join(workspace, sdkPath)));
    assert.match(await readFile(join(workspace, 'dist/index.html'), 'utf8'), /src="\/vendor\/supabase\.js"/);
    await assert.rejects(readFile(join(workspace, 'dist/README.md')), { code: 'ENOENT' });
});

test('Edge Functions allow only the configured application and its explicit aliases', () => {
    const env = {
        SUPABASE_URL: 'https://isolated-test.supabase.co',
        APP_URL: 'https://qa.example.test',
        APP_ALLOWED_ORIGINS: 'https://qa-alias.example.test, invalid origin'
    };
    globalThis.Deno = { env: { get: name => env[name] } };
    const header = origin => corsHeaders(new Request('https://edge.example.test', {
        method: 'OPTIONS', headers: { origin }
    }))['Access-Control-Allow-Origin'];
    assert.equal(header(env.APP_URL), env.APP_URL);
    assert.equal(header('https://qa-alias.example.test'), 'https://qa-alias.example.test');
    assert.equal(header('http://localhost:8080'), undefined);
    assert.equal(header('https://serveyourself-app.vercel.app'), undefined);
    delete env.APP_URL;
    assert.equal(header('https://qa.example.test'), undefined);
});
