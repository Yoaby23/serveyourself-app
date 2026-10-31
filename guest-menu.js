(() => {
    const db = window.serveYourself.supabase, esc = window.serveYourself.escapeHtml, safe = window.serveYourself.safeImageUrl;
    const $ = id => document.getElementById(id), money = n => Number(n).toLocaleString('es-MX', { style: 'currency', currency: 'MXN' });
    const restaurantId = new URLSearchParams(location.search).get('id');
    const storageKey = `sy-guest-checkout:${restaurantId}`;
    const cart = new Map();
    let restaurant, products = [], saved = null, busy = false, poll;
    const message = text => { $('guest-message').textContent = text; };
    function save(value) {
        localStorage.setItem(storageKey, JSON.stringify(value));
        if (value.orderId) localStorage.setItem(`sy-guest-receipt:${restaurantId}:${value.orderId}`, JSON.stringify(value));
        saved = value;
    }
    async function invoke(name, body) {
        const { data, error } = await db.functions.invoke(name, { body });
        if (error) {
            let detail;
            try { detail = await error.context?.json(); } catch {}
            throw new Error(detail?.error || 'No se pudo conectar. Reintenta sin crear otro pedido.');
        }
        if (data?.error) throw new Error(data.error);
        return data;
    }
    function render() {
        const canOrder = restaurant.guest_pickup_enabled && restaurant.accepting_orders && !saved;
        const categories = [...new Set(products.map(p => p.category))];
        $('menu-content').innerHTML = categories.map(category => `<section><h2 class="text-xl font-black mb-3">${esc(category || 'Menú')}</h2><div class="grid sm:grid-cols-2 gap-3">${products.filter(p => p.category === category).map(p => `<article class="sy-guest-product"><img src="${esc(safe(p.image_url) || 'logo.png')}" alt="${esc(p.name)}"><div><h3>${esc(p.name)}</h3><p>${money(p.price)}</p>${canOrder ? `<button type="button" data-add="${p.id}" aria-label="Agregar ${esc(p.name)}">Agregar</button>` : ''}</div></article>`).join('')}</div></section>`).join('') || '<p>No hay productos disponibles por ahora.</p>';
        $('guest-cart').hidden = !canOrder;
        renderCart();
    }
    function renderCart() {
        let total = 0;
        $('cart-items').innerHTML = [...cart].map(([id, qty]) => {
            const p = products.find(p => p.id === id); total += Number(p.price) * qty;
            return `<div class="sy-guest-cart-row"><span>${esc(p.name)}</span><div><button type="button" data-change="${id}" data-delta="-1" aria-label="Quitar uno de ${esc(p.name)}">−</button><b>${qty}</b><button type="button" data-change="${id}" data-delta="1" aria-label="Agregar uno de ${esc(p.name)}">+</button></div><strong>${money(Number(p.price) * qty)}</strong></div>`;
        }).join('') || '<p class="sy-guest-help">Agrega productos del menú.</p>';
        $('cart-total').textContent = `Total estimado: ${money(total)}`;
        $('guest-pay').disabled = !cart.size || busy;
    }
    function receipt(data) {
        const o = data.order;
        if (o.restaurant_id !== restaurantId) throw new Error('Este acceso corresponde a otro restaurante. Abre el enlace privado original.');
        const pending = o.payment_status === 'pending' && !data.expired;
        const names = { pendiente: 'Pago confirmado. Pedido recibido', preparando: 'En preparación', listo: 'Listo para recoger', entregado: 'Entregado', cancelado: 'Cancelado' };
        const label = o.payment_status === 'approved' ? names[o.status] || o.status : ({ pending: data.expired ? 'Tiempo de pago agotado' : 'Esperando confirmación de pago', rejected: 'Pago rechazado', refunded: 'Pago reembolsado', expired: 'Tiempo de pago agotado' }[o.payment_status] || 'Pago pendiente');
        $('guest-receipt').hidden = false;
        $('guest-cart').hidden = true;
        $('receipt-details').innerHTML = `<p class="sy-guest-state">${esc(label)}</p><p>Pedido <b>#${o.id}</b> · ${esc(o.pickup_name)}</p><ul>${o.items.map(i => `<li>${i.qty} × ${esc(i.nombre)} <strong>${money(i.price * i.qty)}</strong></li>`).join('')}</ul><p><b>Total: ${money(o.total)}</b></p>${pending ? '<p class="sy-guest-help">Si ya pagaste, espera la confirmación. No vuelvas a pagar.</p>' : ''}`;
        $('resume-payment').hidden = !pending;
        clearTimeout(poll);
        if (pending || (o.payment_status === 'approved' && !['entregado', 'cancelado'].includes(o.status))) poll = setTimeout(() => refresh(false), 15000);
    }
    async function refresh(showError = true) {
        if (!saved || busy || document.hidden) return;
        try { const data = await invoke('guest-pickup', { action: 'status', token: saved.token }); receipt(data); if (showError) message('Estado actualizado.'); }
        catch (error) { if (showError) message(error.message); clearTimeout(poll); poll = setTimeout(() => refresh(false), 30000); }
    }
    async function pay() {
        if (busy) return;
        busy = true; $('guest-pay').disabled = true; $('resume-payment').disabled = true;
        try {
            if (!saved) {
                const name = $('pickup-name').value.trim();
                if (!name || name.length > 80 || !cart.size) throw new Error('Agrega productos e indica el nombre para recoger.');
                const token = [...crypto.getRandomValues(new Uint8Array(32))].map(b => b.toString(16).padStart(2, '0')).join('');
                // Persist before the first request so an ambiguous response can be retried safely.
                save({ token, payload: { restaurantId, name, items: [...cart].map(([id, qty]) => ({ id, qty })) } });
            }
            let data;
            if (saved.payload) data = await invoke('guest-pickup', { action: 'create', token: saved.token, ...saved.payload });
            else data = await invoke('guest-pickup', { action: 'status', token: saved.token });
            save({ ...saved, orderId: data.order.id });
            render(); receipt(data);
            if (data.order.payment_status !== 'pending' || data.expired) { message('Consulta el estado de este pedido antes de crear otro.'); return; }
            const result = await invoke('create-mercado-pago-preference', { orderId: data.order.id, guestToken: saved.token });
            const checkout = new URL(result.checkoutUrl);
            if (checkout.protocol !== 'https:' || !/(^|\.)mercadopago\.(com|com\.mx)$/.test(checkout.hostname)) throw new Error('No se recibió un enlace de pago válido.');
            location.assign(checkout.href);
        } catch (error) {
            message(error.message);
            if (saved) { $('guest-receipt').hidden = false; $('resume-payment').hidden = false; render(); }
        } finally { busy = false; $('resume-payment').disabled = false; renderCart(); }
    }
    $('menu-content').addEventListener('click', e => {
        const button = e.target.closest('[data-add]'); if (!button || saved || busy) return;
        const id = button.dataset.add; cart.set(id, Math.min(50, (cart.get(id) || 0) + 1)); renderCart();
    });
    $('cart-items').addEventListener('click', e => {
        const button = e.target.closest('[data-change]'); if (!button || saved || busy) return;
        const id = button.dataset.change, qty = (cart.get(id) || 0) + Number(button.dataset.delta);
        if (qty <= 0) cart.delete(id); else cart.set(id, Math.min(qty, 50)); renderCart();
    });
    $('guest-checkout').addEventListener('submit', e => { e.preventDefault(); pay(); });
    $('resume-payment').addEventListener('click', pay);
    $('refresh-order').addEventListener('click', () => refresh());
    $('new-order').addEventListener('click', () => {
        if (busy || !confirm('¿Empezar otro pedido? Conserva el acceso privado del anterior. Si ya pagaste, espera su confirmación antes de repetirlo.')) return;
        try { localStorage.removeItem(storageKey); } catch { message('No se pudo reiniciar el carrito.'); return; }
        const url = new URL(location.href); url.searchParams.delete('order_id'); url.searchParams.delete('payment'); url.hash = ''; history.replaceState(null, '', url.href);
        saved = null; cart.clear(); clearTimeout(poll); $('guest-receipt').hidden = true; message(''); render();
    });
    $('copy-receipt').addEventListener('click', async () => {
        if (!saved) return;
        const url = new URL('menu-publico.html', location.href); url.searchParams.set('id', restaurantId); url.hash = saved.token;
        try { await navigator.clipboard.writeText(url.href); message('Acceso privado copiado. Guárdalo y no lo compartas.'); }
        catch { message('No se pudo copiar. Conserva este navegador para consultar el pedido.'); }
    });
    document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(false); });
    async function init() {
        if (!restaurantId) { message('Este enlace no contiene un restaurante.'); $('restaurant-name').textContent = 'Menú no disponible'; return; }
        try {
            const token = location.hash.slice(1);
            if (/^[a-f0-9]{64}$/.test(token)) { save({ token }); history.replaceState(null, '', location.pathname + location.search); }
            else {
                const returnOrder = new URLSearchParams(location.search).get('order_id');
                const key = returnOrder ? `sy-guest-receipt:${restaurantId}:${returnOrder}` : storageKey;
                const candidate = JSON.parse(localStorage.getItem(key) || 'null');
                if (/^[a-f0-9]{64}$/.test(candidate?.token || '')) saved = candidate;
                else if (returnOrder) message('Abre tu acceso privado o vuelve al navegador donde iniciaste el pago para consultar este pedido.');
            }
        } catch { message('Necesitamos almacenamiento local para conservar tu pedido antes de pagar.'); }
        try {
            const [r, p] = await Promise.all([db.from('public_qr_restaurants').select('*').eq('id', restaurantId).single(), db.from('public_qr_products').select('*').eq('restaurant_id', restaurantId).order('category').order('name')]);
            if (r.error || p.error || !r.data) throw new Error('No se pudo cargar el menú. Recarga para intentarlo de nuevo.');
            restaurant = r.data; products = p.data || [];
            document.title = `Menú de ${restaurant.business_name}`;
            $('restaurant-name').textContent = restaurant.business_name;
            $('restaurant-logo').src = safe(restaurant.avatar_url) || 'logo.png';
            $('restaurant-info').textContent = [restaurant.address, restaurant.open_time && restaurant.close_time ? `Horario ${restaurant.open_time.slice(0, 5)}–${restaurant.close_time.slice(0, 5)}` : ''].filter(Boolean).join(' · ');
            render();
            if (saved) { $('guest-receipt').hidden = false; $('resume-payment').hidden = !saved.payload; await refresh(); }
            else if (restaurant.guest_pickup_enabled && !new URLSearchParams(location.search).has('order_id')) message(restaurant.accepting_orders ? 'Pide para llevar sin crear una cuenta.' : 'El restaurante no está aceptando pedidos ahora.');
        } catch (error) { message(error.message); $('restaurant-name').textContent = 'Menú no disponible'; }
    }
    init();
})();
