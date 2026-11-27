import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
const method = source.slice(source.indexOf('    async installApp()'), source.indexOf('    async signOut()'));

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
        navigator, serveYourselfNative: native, matchMedia: () => ({ matches: standalone }),
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
    assert.match(result.html, /android-v0\.1\.0\/ServeYourself-Android-0\.1\.0\.apk/);
    assert.match(result.html, /Descargas.*Actualizar/);
});

test('Windows descarga el ejecutable y muestra cómo iniciar el programa', async () => {
    const result = await install({ navigator: { platform: 'Win32' } });
    assert.deepEqual(result.events, ['instructions', 'download']);
    assert.match(result.html, /windows-v0\.1\.0\/ServeYourself-0\.1\.0-Windows-x64\.exe/);
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
