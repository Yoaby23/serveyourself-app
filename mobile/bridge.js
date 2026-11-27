(() => {
    const plugins = window.Capacitor?.Plugins;
    if (!plugins?.App || !plugins?.ServeYourself) return;

    const pendingKey = 'sy-android-auth-return';
    const appProtocol = plugins.ServeYourself.getScheme().then(({ scheme }) => scheme + ':');
    const destinations = new Set(['/index.html', '/registro.html', '/recuperar.html']);
    const responseFields = ['code', 'error', 'error_code', 'error_description'];

    function destinationFor(value) {
        const url = new URL(value);
        if (url.origin !== location.origin || !destinations.has(url.pathname)) throw new Error('Destino de acceso no válido.');
        responseFields.forEach(field => url.searchParams.delete(field));
        return url;
    }

    async function receive(value) {
        if (!value) return;
        const result = new URL(value);
        if (result.protocol !== await appProtocol || result.host !== 'auth') return;
        const pending = JSON.parse(localStorage.getItem(pendingKey) ?? 'null');
        if (!pending || result.pathname !== pending.path || Date.now() > pending.expires ||
            (!result.searchParams.get('code') && !result.searchParams.get('error'))) return;
        const destination = destinationFor(pending.destination);
        responseFields.forEach(field => {
            if (result.searchParams.has(field)) destination.searchParams.set(field, result.searchParams.get(field));
        });
        localStorage.removeItem(pendingKey);
        location.replace(destination.href);
    }

    window.serveYourselfAndroid = {
        async getAppInfo() {
            const { id, version, build } = await plugins.App.getInfo();
            return id === 'mx.serveyourself.app' ? { platform: 'android', version, build } : null;
        },
        async authStart(value) {
            const destination = destinationFor(value);
            const path = '/' + crypto.randomUUID();
            localStorage.setItem(pendingKey, JSON.stringify({ destination: destination.href, path, expires: Date.now() + 30 * 60 * 1000 }));
            return await appProtocol + '//auth' + path;
        },
        openGoogle: url => plugins.ServeYourself.openGoogle({ url }),
        print: () => plugins.ServeYourself.print().catch(error => alert(error.message))
    };
    const reportReturnError = () => console.warn('No se pudo procesar la redirección de autenticación.');
    const onReturn = ({ url } = {}) => {
        return receive(url).catch(reportReturnError);
    };
    plugins.App.addListener('appUrlOpen', onReturn).catch(reportReturnError);
    plugins.App.getLaunchUrl().then(onReturn).catch(reportReturnError);
})();
