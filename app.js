const SUPABASE_URL = 'https://spbgledcjwtqmlqdlpyx.supabase.co';
const SUPABASE_KEY = 'sb_publishable_Uf9mS1Ev7fDYIld8PVCL5g_BwenGNXY';

window.serveYourself = {
    supabase: window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
        auth: {
            persistSession: true,
            autoRefreshToken: true,
            detectSessionInUrl: true,
            storage: window.localStorage
        }
    }),

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

    async getOrCreateProfile(user) {
        if (!user?.id) throw new Error('No se recibió un usuario válido.');

        const existing = await this.supabase
            .from('profiles')
            .select('role')
            .eq('id', user.id)
            .maybeSingle();
        if (existing.error) throw existing.error;
        if (existing.data) return existing.data;

        const metadata = user.user_metadata || {};
        const role = metadata.role === 'negocio' ? 'negocio' : 'cliente';
        const emailName = String(user.email || '').split('@')[0];
        const profile = {
            id: user.id,
            full_name: String(metadata.full_name || metadata.name || metadata.preferred_username || emailName || 'Usuario').slice(0, 120),
            email: user.email || null,
            phone: String(metadata.phone || '').slice(0, 30),
            role,
            business_name: role === 'negocio' ? String(metadata.business_name || 'Mi restaurante').slice(0, 120) : null,
            address: role === 'negocio' ? String(metadata.address || '').slice(0, 250) : null,
            open_time: role === 'negocio' ? (metadata.open_time || null) : null,
            close_time: role === 'negocio' ? (metadata.close_time || null) : null,
            avatar_url: metadata.avatar_url || metadata.picture || null,
            rating: 5
        };

        const created = await this.supabase
            .from('profiles')
            .insert(profile)
            .select('role')
            .single();

        if (!created.error) return created.data;

        // El trigger de Auth puede terminar entre la consulta y el insert.
        // En ese caso recuperamos el perfil que acaba de crear.
        if (created.error.code === '23505') {
            const retry = await this.supabase
                .from('profiles')
                .select('role')
                .eq('id', user.id)
                .single();
            if (retry.error) throw retry.error;
            return retry.data;
        }

        throw created.error;
    },

    restaurantHome(access) {
        if (!access) return 'menu.html';
        if (access.staff_role === 'owner') return 'admin.html';
        if (access.can_create_orders) return 'pos.html';
        if (access.can_close_accounts) return 'caja.html';
        if (access.can_view_kitchen) return 'cocina.html';
        return 'menu.html';
    },

    async requireRestaurantAccess(allowedRoles = ['owner', 'manager', 'waiter', 'kitchen', 'cashier']) {
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

    async requireRestaurantPermission(permission) {
        const user = await this.requireUser();
        if (!user) return null;
        try {
            const access = await this.getRestaurantAccess();
            const allowed = access?.staff_role === 'owner' || Boolean(access?.[permission]);
            if (!allowed) {
                alert('Tu cuenta no tiene permiso para entrar a esta sección.');
                window.location.replace('menu.html');
                return null;
            }
            return { user, ...access };
        } catch (error) {
            alert('No fue posible comprobar tus permisos: ' + error.message);
            window.location.replace('index.html');
            return null;
        }
    },

    goBack(fallback = 'index.html') {
        if (window.history.length > 1) window.history.back();
        else window.location.href = fallback;
    },

    ensureGlobalBackButton() {
        if (!document.body || !document.querySelector) return;
        const page = window.location.pathname.split('/').pop() || 'index.html';
        if (page === 'index.html' || document.querySelector('[data-sy-back], .sy-restaurant-nav')) return;
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'sy-global-back no-print';
        button.dataset.syBack = 'true';
        button.setAttribute('aria-label', 'Volver a la vista anterior');
        button.setAttribute('title', 'Volver');
        button.textContent = '←';
        button.addEventListener('click', () => this.goBack('index.html'));
        document.body.appendChild(button);
    },

    renderRestaurantNavigation(access, options = {}) {
        const container = document.getElementById(options.containerId || 'restaurant-nav');
        if (!container || !access) return;
        document.querySelector('.sy-global-back')?.remove();
        const dark = Boolean(options.dark);
        const triggerClass = dark ? 'sy-nav-trigger sy-nav-trigger-dark' : 'sy-nav-trigger';
        const links = [];
        links.push(`<a href="${this.restaurantHome(access)}">🏠 Inicio de trabajo</a>`);
        if (access.can_create_orders) links.push('<a href="pos.html">🧾 Comandas</a>');
        if (access.can_close_accounts) links.push('<a href="caja.html">💵 Caja y cuentas</a>');
        if (access.can_view_kitchen) links.push('<a href="cocina.html">👨‍🍳 Cocina</a>');
        if (access.staff_role === 'owner') {
            links.push('<a href="equipo.html">👥 Personal y permisos</a>');
            links.push('<a href="inventario.html">📦 Inventario y recetas</a>');
            links.push('<a href="reportes.html">📊 Reportes operativos</a>');
            links.push('<a href="clientes.html">🎟️ Clientes y promociones</a>');
            links.push('<a href="qr.html">▦ QR del menú</a>');
        }
        links.push('<a href="menu.html">🛍️ Mis pedidos personales</a>');
        container.innerHTML = `
            <div class="sy-nav-actions">
                <button type="button" data-sy-back class="${triggerClass}" onclick="window.serveYourself.goBack('${this.restaurantHome(access)}')" aria-label="Volver">←</button>
                <button type="button" class="${triggerClass}" onclick="window.serveYourself.toggleRestaurantMenu()" aria-label="Abrir menú" aria-expanded="false">☰</button>
            </div>
            <div id="restaurant-menu-dropdown" class="sy-nav-dropdown hidden">
                <div class="sy-nav-identity"><small>${this.escapeHtml(access.staff_role === 'owner' ? 'Propietario' : 'Personal')}</small><b>${this.escapeHtml(access.business_name)}</b></div>
                <nav>${links.join('')}</nav>
                <button type="button" onclick="window.serveYourself.enableWorkNotifications()">🔔 Activar notificaciones</button>
                <button type="button" onclick="window.serveYourself.installApp()">📲 Instalar aplicación</button>
                <button type="button" class="sy-nav-logout" onclick="window.serveYourself.signOut()">Cerrar sesión</button>
            </div>`;
        if (!this._restaurantMenuListener) {
            document.addEventListener('click', event => {
                const dropdown = document.getElementById('restaurant-menu-dropdown');
                const nav = document.getElementById(options.containerId || 'restaurant-nav');
                if (dropdown && nav && !nav.contains(event.target)) dropdown.classList.add('hidden');
            });
            this._restaurantMenuListener = true;
        }
    },

    toggleRestaurantMenu() {
        const dropdown = document.getElementById('restaurant-menu-dropdown');
        if (!dropdown) return;
        const hidden = dropdown.classList.toggle('hidden');
        const trigger = dropdown.parentElement?.querySelector('[aria-expanded]');
        if (trigger) trigger.setAttribute('aria-expanded', String(!hidden));
    },

    async enableWorkNotifications() {
        try {
            const allowed = await this.requestPushPermission();
            alert(allowed ? 'Notificaciones activadas.' : 'No se concedió permiso para notificaciones.');
        } catch (error) {
            alert(error.message);
        }
    },

    async installApp() {
        const standalone = window.matchMedia?.('(display-mode: standalone)').matches || window.navigator.standalone === true;
        if (standalone) {
            alert('ServeYourself ya está instalada en este dispositivo.');
            return;
        }
        if (!this._installPrompt) {
            const isiOS = /iphone|ipad|ipod/i.test(window.navigator.userAgent || '');
            alert(isiOS
                ? 'En Safari toca Compartir → Agregar a pantalla de inicio.'
                : 'En Chrome o Edge abre el menú del navegador y elige Instalar aplicación.');
            return;
        }
        this._installPrompt.prompt();
        await this._installPrompt.userChoice;
        this._installPrompt = null;
    },

    async signOut() {
        await this.logoutPushNotifications();
        await this.supabase.auth.signOut();
        window.location.href = 'index.html';
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
            await OneSignal.init({ appId, serviceWorkerPath: 'sw.js' });
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

if (!document.querySelector('link[rel="manifest"]')) {
    const manifest = document.createElement('link');
    manifest.rel = 'manifest';
    manifest.href = 'manifest.webmanifest';
    document.head.appendChild(manifest);
}
[
    ['theme-color', '#f97316'],
    ['mobile-web-app-capable', 'yes'],
    ['apple-mobile-web-app-capable', 'yes'],
    ['apple-mobile-web-app-status-bar-style', 'default'],
    ['apple-mobile-web-app-title', 'ServeYourself']
].forEach(([name, content]) => {
    if (document.querySelector(`meta[name="${name}"]`)) return;
    const meta = document.createElement('meta');
    meta.name = name;
    meta.content = content;
    document.head.appendChild(meta);
});
if (!document.querySelector('link[rel="apple-touch-icon"]')) {
    const appleIcon = document.createElement('link');
    appleIcon.rel = 'apple-touch-icon';
    appleIcon.href = 'logo.png';
    document.head.appendChild(appleIcon);
}
if ('serviceWorker' in navigator && location.protocol === 'https:') {
    window.addEventListener('load', () => navigator.serviceWorker.register('sw.js').catch(() => {}));
}
window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault();
    window.serveYourself._installPrompt = event;
});
window.addEventListener('appinstalled', () => { window.serveYourself._installPrompt = null; });
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => window.serveYourself.ensureGlobalBackButton());
} else {
    window.serveYourself.ensureGlobalBackButton();
}
