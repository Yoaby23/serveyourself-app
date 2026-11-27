const { app, BrowserWindow, dialog, ipcMain, session, shell } = require('electron');
const { readFile, readdir, writeFile } = require('node:fs/promises');
const path = require('node:path');
const { SITE, BACKEND, createAuthReceiver } = require('./auth.cjs');

const smokeResult = process.argv.find(flag => flag.startsWith('--desktop-smoke='))?.slice('--desktop-smoke='.length);
const webRoot = path.join(__dirname, 'web');
const types = {
    '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
    '.png': 'image/png', '.svg': 'image/svg+xml', '.webp': 'image/webp', '.webmanifest': 'application/manifest+json'
};
const headers = {
    'Content-Security-Policy': "base-uri 'self'; object-src 'none'; frame-ancestors 'none'",
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(self), payment=(self)',
    'Referrer-Policy': 'strict-origin-when-cross-origin', 'X-Content-Type-Options': 'nosniff'
};
let window;
const auth = createAuthReceiver(url => {
    if (!window || window.isDestroyed()) return;
    window.loadURL(url).catch(() => {});
    if (window.isMinimized()) window.restore();
    window.focus();
});

function trusted(event) {
    if (!window || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame ||
        new URL(event.senderFrame.url).origin !== SITE) throw new Error('Operación de escritorio no autorizada.');
}

function openExternal(value) {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password) return;
    return shell.openExternal(url.href);
}

async function configureSession(desktopSession) {
    const assets = new Set((await readdir(webRoot)).filter(name => Object.hasOwn(types, path.extname(name))));
    assets.add('vendor/supabase.js');
    desktopSession.protocol.handle('https', async request => {
        const url = new URL(request.url);
        if (url.origin !== SITE) return desktopSession.fetch(request, { bypassCustomProtocolHandlers: true });
        if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405 });
        const asset = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
        if (!assets.has(asset)) return new Response(null, { status: 404 });
        const body = request.method === 'HEAD' ? null : await readFile(path.join(webRoot, asset));
        return new Response(body, { headers: { ...headers, 'Content-Type': types[path.extname(asset)] } });
    });
    desktopSession.setPermissionRequestHandler((_contents, permission, respond, details) => {
        respond(permission === 'geolocation' && details.isMainFrame && new URL(details.requestingUrl).origin === SITE);
    });
}

async function start() {
    const desktopSession = session.fromPartition('persist:serveyourself');
    await configureSession(desktopSession);
    window = new BrowserWindow({
        show: !smokeResult, title: 'ServeYourself', width: 1360, height: 900, minWidth: 680, minHeight: 540,
        icon: path.join(webRoot, 'app-icon-512.png'), autoHideMenuBar: true,
        webPreferences: { session: desktopSession, sandbox: true, contextIsolation: true, nodeIntegration: false, preload: path.join(__dirname, 'preload.cjs') }
    });
    window.webContents.setWindowOpenHandler(({ url }) => {
        openExternal(url)?.catch(() => {});
        return { action: 'deny' };
    });
    function checkNavigation(event, value) {
        const url = new URL(value);
        if (url.origin === SITE) return;
        event.preventDefault();
        openExternal(url.href)?.catch(() => {});
    }
    window.webContents.on('will-navigate', checkNavigation);
    window.webContents.on('will-redirect', checkNavigation);
    window.webContents.on('will-attach-webview', event => event.preventDefault());
    window.on('closed', () => { window = undefined; });
    await window.loadURL(`${SITE}/index.html`);
    if (smokeResult) {
        const result = await window.webContents.executeJavaScript(`(async () => {
            const routes = ['/pos.html', '/caja.html', '/cocina.html', '/restaurante.html', '/delivery.html',
                '/menu-publico.html', '/admin.html', '/reportes.html', '/repartidor.html', '/vendor/supabase.js'];
            const responses = await Promise.all(routes.map(route => fetch(route)));
            const ready = window.serveYourselfDesktop && window.serveYourself?.supabase && responses.every(response => response.ok);
            if (!ready) return false;
            const catalog = await window.serveYourself.supabase.from('public_restaurants').select('id').limit(1);
            return !catalog.error && location.origin === ${JSON.stringify(SITE)} &&
                window.serveYourself.supabase.supabaseUrl === ${JSON.stringify(BACKEND)};
        })()`);
        if (!result) throw new Error('Falló la verificación de pantallas, configuración o backend.');
        await writeFile(smokeResult, 'OK', { flag: 'wx' });
        app.quit();
    }
}

ipcMain.handle('desktop:auth-start', (event, destination) => { trusted(event); return auth.begin(destination); });
ipcMain.handle('desktop:auth-open', (event, url) => {
    trusted(event);
    if (!auth.authorize(url)) throw new Error('Enlace de acceso no válido.');
    return openExternal(url);
});
ipcMain.handle('desktop:print', event => {
    trusted(event);
    return new Promise(resolve => event.sender.print({ printBackground: true }, success => resolve(success)));
});

if (!app.requestSingleInstanceLock()) app.quit();
else {
    app.on('second-instance', () => { if (window?.isMinimized()) window.restore(); window?.focus(); });
    app.on('window-all-closed', () => app.quit());
    app.on('before-quit', () => auth.close());
    app.whenReady().then(start).catch(error => {
        if (!smokeResult) dialog.showErrorBox('No se pudo abrir ServeYourself', error.message);
        app.exit(1);
    });
}
