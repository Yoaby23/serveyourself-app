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
        const { data: { session } } = await this.supabase.auth.getSession();
        if (!session?.access_token) throw new Error('Sesión requerida para verificar el pago.');
        return fetch(webhookUrl.toString(), {
            method: 'GET',
            headers: { Authorization: `Bearer ${session.access_token}`, apikey: SUPABASE_KEY }
        });
    },

    async requireUser() {
        const { data: { user }, error } = await this.supabase.auth.getUser();
        if (error || !user) {
            window.location.replace('index.html');
            return null;
        }
        const page = (window.location.pathname || '').split('/').pop();
        if (['restaurante.html','delivery-tracking.html','eliminar-cuenta.html','unirse.html','repartidor-registro.html'].includes(page)) this.renderPersonalNavigation();
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
        if (access.staff_role === 'owner') return 'funciones.html';
        if (access.can_deliver_orders) return 'repartidor.html';
        if (access.can_manage_delivery) return 'delivery.html';
        if (access.can_create_orders) return 'pos.html';
        if (access.can_close_accounts) return 'caja.html';
        if (access.can_view_kitchen) return 'cocina.html';
        return 'menu.html';
    },

    async requireRestaurantAccess(allowedRoles = ['owner', 'manager', 'waiter', 'kitchen', 'cashier', 'driver']) {
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
        let internalPrevious=false;
        try { internalPrevious=Boolean(document.referrer)&&new URL(document.referrer).origin===window.location.origin; } catch {}
        if (internalPrevious && window.history.length > 1) window.history.back();
        else window.location.href = fallback;
    },

    requestBack() {
        const request = new CustomEvent('sy:back-request', { cancelable: true });
        if (!window.dispatchEvent(request)) return;
        const access = this._currentRestaurantAccess;
        const fallback = access ? this.restaurantHome(access) : 'index.html';
        this.goBack(fallback);
    },

    enableSwipeBack() {
        if (this._swipeBackEnabled || !document.body) return;
        this._swipeBackEnabled = true;
        const indicator = document.createElement('div');
        indicator.className = 'sy-swipe-back-indicator no-print';
        indicator.textContent = '←';
        indicator.setAttribute('aria-hidden', 'true');
        document.body.appendChild(indicator);
        let startX = 0, startY = 0, startedAt = 0, tracking = false;
        document.addEventListener('touchstart', event => {
            const touch = event.touches[0];
            tracking = Boolean(touch && touch.clientX <= 32 && !document.querySelector('dialog[open]'));
            if (!tracking) return;
            startX = touch.clientX; startY = touch.clientY; startedAt = Date.now();
        }, { passive: true });
        document.addEventListener('touchmove', event => {
            if (!tracking) return;
            const touch = event.touches[0], dx = touch.clientX - startX, dy = Math.abs(touch.clientY - startY);
            if (dx > 18 && dy < 70) indicator.classList.add('is-visible');
            if (dy > 90 || dx < -10) { tracking = false; indicator.classList.remove('is-visible'); }
        }, { passive: true });
        document.addEventListener('touchend', event => {
            if (!tracking) return;
            const touch = event.changedTouches[0], dx = touch.clientX - startX, dy = Math.abs(touch.clientY - startY), elapsed = Date.now() - startedAt;
            tracking = false; indicator.classList.remove('is-visible');
            if (dx >= 80 && dy <= 70 && elapsed <= 900) this.requestBack();
        }, { passive: true });
        document.addEventListener('touchcancel', () => { tracking = false; indicator.classList.remove('is-visible'); }, { passive: true });
    },

    ensureGlobalBackButton() {
        if (!document.body || !document.querySelector) return;
        const page = (window.location.pathname || '/index.html').split('/').pop() || 'index.html';
        const mainPages = ['index.html', 'menu.html', 'admin.html', 'pos.html', 'caja.html', 'cocina.html', 'delivery.html', 'repartidor.html'];
        if (mainPages.includes(page) || page === 'funciones.html' || document.querySelector('[data-sy-back], .sy-global-back')) return;
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'sy-global-back no-print';
        button.dataset.syBack = 'true';
        button.setAttribute('aria-label', 'Volver a la vista anterior');
        button.setAttribute('title', 'Volver');
        button.innerHTML = '<span aria-hidden="true">←</span><span>Volver</span>';
        button.addEventListener('click', () => this.goBack(this._currentRestaurantAccess ? this.restaurantHome(this._currentRestaurantAccess) : 'menu.html'));
        document.body.appendChild(button);
    },

    workFeatures(access) {
        if (!access) return [];
        const owner = access.staff_role === 'owner';
        const features = [];
        if (owner) features.push({ href: 'admin.html?section=productos', label: 'Productos', icon: 'products', description: 'Administra tu menú y disponibilidad.' });
        if (owner || access.can_create_orders) features.push({ href: 'pos.html', label: 'Meseros', icon: 'orders', description: 'Mesas, cuentas abiertas y nuevas rondas.' });
        if (owner || access.can_close_accounts) features.push({ href: 'caja.html', label: 'Caja', icon: 'cash', description: 'Cobros, turnos y cuentas.' });
        if (owner || access.can_view_kitchen) features.push({ href: 'cocina.html', label: 'Cocina', icon: 'kitchen', description: 'Prepara y entrega comandas.' });
        if (owner || access.can_manage_delivery) features.push({ href: 'delivery.html', label: 'Delivery', icon: 'delivery', description: 'Despacho, repartidores y entregas.' });
        if (owner) features.push(
            { href: 'equipo.html', label: 'Personal y mesas', icon: 'people', description: 'Invitaciones, permisos y salón.' },
            { href: 'inventario.html', label: 'Estaciones', icon: 'kitchen', description: 'Organiza cocina, barra y asignación de productos.' },
            { href: 'reportes.html', label: 'Reportes', icon: 'chart', description: 'Ventas y resultados del restaurante.' },
            { href: 'clientes.html', label: 'Clientes', icon: 'people', description: 'Promociones, reservas y lealtad.' },
            { href: 'qr.html', label: 'Menú QR', icon: 'grid', description: 'Imprime el acceso al menú público.' },
            { href: 'admin.html?section=config', label: 'Configuración', icon: 'settings', description: 'Horarios, pagos y datos del negocio.' }
        );
        return features;
    },

    workBottomItems(access) {
        const home = this.restaurantHome(access);
        const features = this.workFeatures(access);
        const primary = features.filter(item => ['pos.html','caja.html','cocina.html','delivery.html'].includes(item.href) && item.href !== home).slice(0, 2);
        return [{ href: home, label: 'Inicio', icon: 'home' }, ...primary, ...(home === 'funciones.html' ? [] : [{ href: 'funciones.html', label: 'Funciones', icon: 'grid' }]), { href: 'cuenta.html', label: 'Cuenta', icon: 'account' }];
    },

    navigationIcon(name) {
        const paths = {
            home: '<path d="m3 10 9-7 9 7v10H15v-7H9v7H3Z"/>',
            account: '<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',
            grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
            orders: '<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6M9 16h4"/>',
            cash: '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="12" cy="12" r="3"/>',
            kitchen: '<path d="M5 12a4 4 0 0 1 1-8 6 6 0 0 1 12 0 4 4 0 0 1 1 8v8H5ZM5 16h14"/>',
            delivery: '<path d="M3 6h11v12H3ZM14 10h4l3 4v4h-7"/><circle cx="7" cy="19" r="2"/><circle cx="18" cy="19" r="2"/>',
            products: '<path d="m3 7 9-4 9 4v10l-9 4-9-4ZM3 7l9 4 9-4M12 11v10"/>',
            people: '<circle cx="9" cy="8" r="3"/><path d="M3 21v-3a6 6 0 0 1 12 0v3M16 5a3 3 0 0 1 0 6M18 15a5 5 0 0 1 3 5"/>',
            chart: '<path d="M4 3v18h17M8 16v-5M13 16V6M18 16v-8"/>',
            settings: '<circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2"/>',
            heart: '<path d="M20 4a5 5 0 0 0-8 2 5 5 0 0 0-8-2C-2 10 12 21 12 21S26 10 20 4Z"/>'
        };
        return `<svg class="sy-icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${paths[name] || paths.grid}</svg>`;
    },

    renderBottomNavigation(items, options = {}) {
        const id = options.id || 'sy-work-bottom-nav';
        let nav = document.getElementById(id);
        if (!nav) { nav = document.createElement('nav'); nav.id = id; document.body.appendChild(nav); }
        nav.className = `sy-role-bottom-nav no-print${options.dark ? ' sy-role-bottom-nav-dark' : ''}`;
        nav.setAttribute('aria-label', options.label || 'Navegación de trabajo');
        nav.style.setProperty('--nav-columns', items.length);
        const page = (window.location.pathname || '/index.html').split('/').pop();
        nav.innerHTML = items.map(item => `<a href="${this.escapeHtml(item.href)}" ${item.href.split('?')[0] === page ? 'aria-current="page"' : ''}>${this.navigationIcon(item.icon)}<span>${this.escapeHtml(item.label)}</span></a>`).join('');
        document.body.classList.add('sy-has-bottom-nav');
        this.ensureGlobalBackButton();
    },

    renderRestaurantNavigation(access, options = {}) {
        if (!access) return;
        this._currentRestaurantAccess = access;
        const container = document.getElementById(options.containerId || 'restaurant-nav');
        if (container) container.textContent = access.staff_role === 'owner' ? 'Propietario' : ({ waiter: 'Mesero', kitchen: 'Cocina', cashier: 'Caja', manager: 'Encargado', driver: 'Repartidor' }[access.staff_role] || 'Personal');
        this.renderBottomNavigation(this.workBottomItems(access), { dark: Boolean(options.dark) });
    },

    renderPersonalNavigation() {
        this.renderBottomNavigation([
            { href: 'menu.html', label: 'Inicio', icon: 'home' },
            { href: 'menu.html?section=favoritos', label: 'Favoritos', icon: 'heart' },
            { href: 'menu.html?section=perfil', label: 'Cuenta', icon: 'account' }
        ], { id: 'sy-personal-bottom-nav', label: 'Navegación principal' });
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
    document.addEventListener('DOMContentLoaded', () => {
        window.serveYourself.ensureGlobalBackButton();
        window.serveYourself.enableSwipeBack();
    });
} else {
    window.serveYourself.ensureGlobalBackButton();
    window.serveYourself.enableSwipeBack();
}

// Keep the app viewport stable while retaining scrolling and in-map controls.
// Browser menus and OS accessibility magnification remain outside app control.
(() => {
    const preventPageZoom = event => {
        if (event.cancelable) event.preventDefault();
    };
    ['gesturestart', 'gesturechange'].forEach(type => {
        document.addEventListener(type, preventPageZoom, { passive: false });
    });
    document.addEventListener('touchmove', event => {
        // Leaflet handles its own map gestures; these do not scale the page.
        if (event.touches.length > 1 && !event.target?.closest?.('.leaflet-container')) {
            preventPageZoom(event);
        }
    }, { passive: false });
    document.addEventListener('wheel', event => {
        if (event.ctrlKey || event.metaKey) preventPageZoom(event);
    }, { passive: false });
    document.addEventListener('keydown', event => {
        if ((event.ctrlKey || event.metaKey) && ['+', '-', '=', '0'].includes(event.key)) {
            preventPageZoom(event);
        }
    });
})();

// Existing back links use the actual in-app history; href is only a direct-entry fallback.
document.addEventListener('click', event => {
    const link=event.target?.closest?.('a[data-sy-back]');
    if(!link || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || event.button>0)return;
    event.preventDefault();
    window.serveYourself.goBack(link.getAttribute('href')||'menu.html');
});
