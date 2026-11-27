const { randomBytes } = require('node:crypto');
const { createServer } = require('node:http');

const SITE = 'https://serveyourself-app.vercel.app';
const BACKEND = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const PORT = 47853;
const ROOT = `http://127.0.0.1:${PORT}`;
const AUTH_PATHS = new Set(['/index.html', '/registro.html', '/recuperar.html']);

function createAuthReceiver(complete) {
    let pending;
    const listener = createServer((req, res) => {
        let url;
        try { url = new URL(req.url, ROOT); }
        catch { res.writeHead(400).end(); return; }
        const isMatch = pending && req.method === 'GET' && req.headers.host === `127.0.0.1:${PORT}` &&
            url.pathname === pending.callback.pathname && url.origin === ROOT;
        const callbackFields = ['code', 'error', 'error_code', 'error_description'];
        if (!isMatch || (!url.searchParams.get('code') && !url.searchParams.get('error'))) {
            res.writeHead(404, { 'Cache-Control': 'no-store' }).end('Enlace inválido o vencido.');
            return;
        }
        const { destination } = pending;
        for (const name of callbackFields) {
            if (url.searchParams.has(name)) destination.searchParams.set(name, url.searchParams.get(name));
        }
        cancel();
        res.writeHead(200, {
            'Cache-Control': 'no-store', 'Content-Type': 'text/html; charset=utf-8',
            'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'"
        }).end('<!doctype html><html lang="es"><meta charset="utf-8"><title>ServeYourself</title><h1>Continúa en ServeYourself</h1><p>Ya puedes regresar al programa de escritorio.</p></html>');
        complete(destination.href);
    });
    // Keep future listener errors from terminating the desktop application.
    listener.on('error', () => {});

    function cancel() {
        clearTimeout(pending?.timer);
        pending = undefined;
    }

    async function begin(value) {
        const destination = new URL(value);
        if (destination.origin !== SITE || !AUTH_PATHS.has(destination.pathname)) throw new Error('Destino de acceso no válido.');
        for (const name of ['code', 'error', 'error_code', 'error_description']) destination.searchParams.delete(name);
        cancel();
        if (!listener.listening) {
            await new Promise((resolve, reject) => {
                function onError(error) { listener.removeListener('listening', onListening); reject(error); }
                function onListening() { listener.removeListener('error', onError); resolve(); }
                listener.once('error', onError);
                listener.once('listening', onListening);
                listener.listen(PORT, '127.0.0.1');
            });
        }
        const callback = new URL(`/serveyourself/${randomBytes(24).toString('hex')}`, ROOT);
        const timer = setTimeout(cancel, 30 * 60 * 1000).unref();
        pending = { callback, destination, timer };
        return callback.href;
    }

    function authorize(value) {
        const url = new URL(value);
        return pending && url.origin === BACKEND && url.pathname === '/auth/v1/authorize' &&
            url.searchParams.get('provider') === 'google' && url.searchParams.get('redirect_to') === pending.callback.href &&
            url.searchParams.get('code_challenge_method')?.toLowerCase() === 's256' &&
            /^[A-Za-z0-9_-]{43}$/.test(url.searchParams.get('code_challenge') ?? '');
    }

    function close() {
        cancel();
        listener.close();
    }

    return { begin, authorize, close };
}

module.exports = { SITE, BACKEND, createAuthReceiver };
