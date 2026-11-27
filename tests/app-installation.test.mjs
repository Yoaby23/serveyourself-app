import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
const releases = JSON.parse(readFileSync(new URL('../native-releases.json', import.meta.url), 'utf8'));
const method = source.slice(source.indexOf('    nativeReleaseDownload('), source.indexOf('    async signOut()'));

async function install({ navigator = {}, native = false, standalone = false, dialogSupported = true } = {}) {
    const alerts = [];
    const events = [];
    const dialog = {
        setAttribute() {},
        addEventListener() {},
        querySelector: () => ({ click: () => events.push('download') })
    };
    if (dialogSupported) dialog.showModal = () => events.push('instructions');
    const document = { getElementById: () => null, createElement: () => dialog, body: { appendChild() {} } };
    const window = {
        navigator, APP_CONFIG: { nativeReleases: releases }, serveYourselfNative: native, matchMedia: () => ({ matches: standalone }),
        location: { assign: href => events.push(href) }
    };
    const app = vm.runInNewContext(`({${method}})`, { window, document, alert: message => alerts.push(message) });
    app._installPrompt = { prompt: () => events.push('browser'), userChoice: Promise.resolve() };
    await app.installApp();
    return { alerts, events, html: dialog.innerHTML };
}

for (const navigator of [{ userAgent: 'iPhone' }, { platform: 'MacIntel', maxTouchPoints: 5 }]) {
    test('Safari en iPhone y iPad conserva las instrucciones de la pantalla de inicio', async () => {
        const result = await install({ navigator });
        assert.match(result.alerts[0], /Compartir → Agregar a pantalla de inicio/);
        assert.deepEqual(result.events, []);
    });
}

test('Android descarga el APK y muestra los pasos aun con agente de escritorio', async () => {
    const result = await install({ navigator: { userAgent: 'X11; Linux x86_64', userAgentData: { platform: 'Android' } } });
    assert.deepEqual(result.events, ['instructions', 'download']);
    assert.ok(result.html.includes(`android-v${releases.android.version}/ServeYourself-Android-${releases.android.version}.apk`));
    assert.match(result.html, /Descargas.*Actualizar/);
});

test('Windows descarga el ejecutable y muestra cómo iniciar el programa', async () => {
    const result = await install({ navigator: { platform: 'Win32' } });
    assert.deepEqual(result.events, ['instructions', 'download']);
    assert.ok(result.html.includes(`windows-v${releases.windows.version}/ServeYourself-${releases.windows.version}-Windows-x64.exe`));
    assert.match(result.html, /menú Inicio/);
});

test('Mac y Linux conservan el instalador que ofrece el navegador', async () => {
    for (const platform of ['MacIntel', 'Linux x86_64']) {
        assert.deepEqual((await install({ navigator: { platform } })).events, ['browser']);
    }
});

test('las apps nativas y la PWA de iOS ya instaladas evitan descargar otra copia', async () => {
    for (const options of [{ native: true, navigator: { userAgent: 'Android' } }, { standalone: true, navigator: { userAgent: 'iPhone' } }]) {
        const result = await install(options);
        assert.match(result.alerts[0], /ya está instalada/);
        assert.deepEqual(result.events, []);
    }
});

test('un Android sin diálogo nativo conserva las instrucciones y la descarga', async () => {
    const result = await install({ navigator: { userAgent: 'Android' }, dialogSupported: false });
    assert.match(result.alerts[0], /Abre el APK/);
    assert.match(result.events[0], /\.apk$/);
});

async function checkNative({ installed, release, manual = false, error = false, recentlyChecked = false }) {
    const alerts = [];
    const shown = [];
    const requests = [];
    const session = new Map(recentlyChecked ? [['sy-native-update-check', String(Date.now())]] : []);
    const banner = { setAttribute() {}, querySelector: () => ({ addEventListener() {} }) };
    const document = { getElementById: () => null, createElement: () => banner, body: { appendChild: value => shown.push(value) } };
    const window = { serveYourselfNative: { getAppInfo: async () => installed }, sessionStorage: { getItem: key => session.get(key), setItem: (key, value) => session.set(key, value) } };
    const fetch = async (url, options) => {
        requests.push({ url, options });
        return { ok: !error, json: async () => ({ [installed.platform]: release }) };
    };
    const app = vm.runInNewContext(`({${method}})`, { window, document, fetch, AbortController, setTimeout, clearTimeout, alert: message => alerts.push(message) });
    await app.checkNativeUpdate(manual);
    return { alerts, shown, requests };
}

test('Android offers a newer signed release by build number without interrupting the screen', async () => {
    const result = await checkNative({ installed: { platform: 'android', version: '0.2.0', build: '2' }, release: { version: '0.2.1', build: 3 } });
    assert.equal(result.shown.length, 1);
    assert.match(result.shown[0].innerHTML, /android-v0\.2\.1\/ServeYourself-Android-0\.2\.1\.apk/);
    assert.deepEqual(result.alerts, []);
    assert.equal(result.requests[0].options.credentials, 'omit');
    assert.equal(result.requests[0].options.redirect, 'error');
});

test('Windows compares version components numerically', async () => {
    const installed = { platform: 'windows', version: '0.2.9' };
    assert.equal((await checkNative({ installed, release: { version: '0.2.10' } })).shown.length, 1);
    assert.deepEqual((await checkNative({ installed, release: { version: '0.2.8' } })).shown, []);
});

test('the app ignores downgrades and never uses a remote download URL', async () => {
    const installed = { platform: 'android', version: '0.2.0', build: '2' };
    assert.deepEqual((await checkNative({ installed, release: { version: '0.3.0', build: 1 } })).shown, []);
    assert.deepEqual((await checkNative({ installed, release: { version: 'https://example.org/a', build: 3 } })).shown, []);
    const valid = await checkNative({ installed, release: { version: '0.3.0', build: 3, url: 'https://example.org/a' } });
    assert.doesNotMatch(valid.shown[0].innerHTML, /example\.org/);
});

test('automatic checks are spaced out and manual checks report status', async () => {
    const installed = { platform: 'windows', version: '0.2.0' };
    const release = { version: '0.2.0' };
    assert.equal((await checkNative({ installed, release, recentlyChecked: true })).requests.length, 0);
    const current = await checkNative({ installed, release, recentlyChecked: true, manual: true });
    assert.match(current.alerts[0], /versión más reciente/);
    assert.match((await checkNative({ installed, release, manual: true, error: true })).alerts[0], /No se pudo buscar/);
    assert.deepEqual((await checkNative({ installed, release, error: true })).alerts, []);
});
