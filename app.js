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

    async reconcileMercadoPagoOrder(orderId, paymentId = null) {
        const webhookUrl = new URL(`${SUPABASE_URL}/functions/v1/mercado-pago-webhook`);
        webhookUrl.searchParams.set('order_id', String(orderId));
        if (paymentId) webhookUrl.searchParams.set('payment_id', String(paymentId));
        return fetch(webhookUrl.toString(), { method: 'GET' });
    },

    async requireUser() {
        const { data: { user }, error } = await this.supabase.auth.getUser();
        if (error || !user) {
            window.location.replace('index.html');
            return null;
        }
        return user;
    },

    async getRestaurantAccess() {
        const { data, error } = await this.supabase.rpc('get_my_restaurant_access');
        if (error) throw error;
        return Array.isArray(data) ? (data[0] || null) : data;
    },

    async requireRestaurantAccess(allowedRoles = ['owner', 'manager', 'waiter', 'kitchen']) {
        const user = await this.requireUser();
        if (!user) return null;
        try {
            const access = await this.getRestaurantAccess();
            if (!access || !allowedRoles.includes(access.staff_role)) {
                alert('Tu cuenta no tiene permiso para entrar a esta sección.');
                window.location.replace('menu.html');
                return null;
            }
            return { user, ...access };
        } catch (error) {
            alert('No fue posible comprobar el acceso del personal: ' + error.message);
            window.location.replace('index.html');
            return null;
        }
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

    async requestPushPermission() {
        if (!window.APP_CONFIG?.oneSignalAppId) throw new Error('Las notificaciones no están configuradas');
        return new Promise((resolve, reject) => {
            window.OneSignalDeferred = window.OneSignalDeferred || [];
            window.OneSignalDeferred.push(async OneSignal => {
                try {
                    await OneSignal.Notifications.requestPermission();
                    resolve(Boolean(OneSignal.Notifications.permission));
                } catch (error) {
                    reject(error);
                }
            });
        });
    },

    async logoutPushNotifications() {
        if (!window.APP_CONFIG?.oneSignalAppId) return;
        window.OneSignalDeferred = window.OneSignalDeferred || [];
        window.OneSignalDeferred.push(async OneSignal => OneSignal.logout());
    }
};
