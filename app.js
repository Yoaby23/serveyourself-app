const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const SUPABASE_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY';

window.serveYourself = {
    supabase: window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY),

    escapeHtml(value) {
        return String(value ?? '').replace(/[&<>'"]/g, character => ({
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            "'": '&#39;',
            '"': '&quot;'
        })[character]);
    },

    safeImageUrl(value) {
        if (!value) return '';
        try {
            const url = new URL(value, window.location.origin);
            return ['http:', 'https:'].includes(url.protocol) ? url.href : '';
        } catch {
            return '';
        }
    },

    async requireUser() {
        const { data: { user }, error } = await this.supabase.auth.getUser();
        if (error || !user) {
            window.location.replace('index.html');
            return null;
        }
        return user;
    },

    async initPushNotifications(user) {
        const appId = window.APP_CONFIG?.oneSignalAppId;
        if (!appId || !user) return false;
        window.OneSignalDeferred = window.OneSignalDeferred || [];
        if (!document.querySelector('script[data-onesignal]')) {
            const script = document.createElement('script');
            script.src = 'https://cdn.onesignal.com/sdks/web/v16/OneSignalSDK.page.js';
            script.defer = true;
            script.dataset.onesignal = 'true';
            document.head.appendChild(script);
        }
        window.OneSignalDeferred.push(async OneSignal => {
            await OneSignal.init({ appId, serviceWorkerPath: 'OneSignalSDKWorker.js' });
            await OneSignal.login(user.id);
        });
        return true;
    },

    async logoutPushNotifications() {
        if (!window.APP_CONFIG?.oneSignalAppId) return;
        window.OneSignalDeferred = window.OneSignalDeferred || [];
        window.OneSignalDeferred.push(async OneSignal => OneSignal.logout());
    }
};
