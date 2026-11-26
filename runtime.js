/* Shared, dependency-free behavior used by the browser and regression tests. */
(function (root) {
    const api = {
        isBusinessOpen(business, date = new Date()) {
            if (business.accepting_orders === false) return false;
            const parts = new Intl.DateTimeFormat('en-US', {timeZone:business.timezone || 'America/Mexico_City',weekday:'short',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(date);
            const get = key => parts.find(p=>p.type===key).value;
            const time = `${get('hour')}:${get('minute')}`, day = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'].indexOf(get('weekday'));
            if (!business.business_hours) {
                const open=business.open_time?.slice(0,5),close=business.close_time?.slice(0,5);
                return !open || !close || (open<=close ? time>=open&&time<close : time>=open||time<close);
            }
            const today=business.business_hours[day],previous=business.business_hours[(day+6)%7];
            return Boolean((!today.closed && (today.allDay || (today.open<today.close ? time>=today.open&&time<today.close : time>=today.open))) || (!previous.closed&&!previous.allDay&&previous.open>previous.close&&time<previous.close));
        },
        transferReceiptUrl(phone, order) {
            let digits=String(phone||'').replace(/\D/g,'');
            if(digits.length===10)digits='52'+digits;
            if(!/^[1-9][0-9]{9,14}$/.test(digits))return null;
            return `https://wa.me/${digits}?text=${encodeURIComponent(`Hola, envío el comprobante de transferencia del pedido #${order.id}, a nombre de ${order.pickup_name||'cliente'}, por $${Number(order.total).toFixed(2)}. Adjunto el comprobante para que caja valide el pago.`)}`;
        },
        csvCell(value) {
            let text = String(value ?? '');
            if (/^[\s\u0000-\u001f]*[=+@-]/.test(text) || /^[\t\r\n]/.test(text)) text = "'" + text;
            return '"' + text.replaceAll('"', '""') + '"';
        },
        dateInZone(date, timezone) {
            const parts = new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(date);
            const get = type => parts.find(part => part.type === type).value;
            return `${get('year')}-${get('month')}-${get('day')}`;
        },
        serialRefresh(work) {
            let running = null;
            let dirty = false;
            return () => {
                dirty = true;
                if (running) return running;
                running = (async () => {
                    try {
                        do {
                            dirty = false;
                            await work();
                        } while (dirty);
                    } finally { running = null; }
                })();
                return running;
            };
        },
        orderSync(status, refresh, browser = root) {
            let lastSuccess, live = false;
            const show = state => {
                status.dataset.stale = String(['offline', 'retry'].includes(state));
                const last = lastSuccess ? ` · Última actualización ${lastSuccess.toLocaleTimeString('es-MX', {hour:'2-digit',minute:'2-digit'})}` : '';
                status.textContent = ({
                    offline: 'Sin conexión. Se conservan los pedidos visibles',
                    retry: 'No se pudo actualizar. Reintentando…',
                    live: 'Pedidos sincronizados',
                    polling: 'Pedidos actualizados · sincronización por consulta'
                }[state]) + last;
            };
            const resume = () => {
                if (browser.navigator.onLine !== false && !browser.document.hidden) refresh();
            };
            const current = () => show(browser.navigator.onLine === false ? 'offline' : live ? 'live' : 'polling');
            browser.addEventListener('offline', () => show('offline'));
            browser.addEventListener('online', resume);
            browser.addEventListener('pageshow', resume);
            browser.addEventListener('focus', resume);
            if (browser.navigator.onLine === false) show('offline');
            browser.document.addEventListener('visibilitychange', resume);
            return {
                refresh: resume,
                success() { lastSuccess = new Date(); current(); },
                failure() { show(browser.navigator.onLine === false ? 'offline' : 'retry'); },
                channel(state) {
                    if (state === 'SUBSCRIBED') {
                        live = true;
                        if (lastSuccess && status.dataset.stale !== 'true') current();
                        resume();
                    }
                    else if (['CHANNEL_ERROR', 'TIMED_OUT', 'CLOSED'].includes(state)) {
                        live = false;
                        if (lastSuccess && status.dataset.stale !== 'true') current();
                    }
                }
            };
        },
        pickupProgress(order, restaurant = {}, now = Date.now()) {
            const status = order.status;
            if (status === 'cancelado') return { label: 'Pedido cancelado' };
            if (status === 'entregado') return { label: 'Pedido entregado' };
            if (status === 'listo') return { label: 'Listo para recoger' };
            if (['pending', 'expired', 'rejected', 'refunded'].includes(order.payment_status)) {
                return { label: ({pending:'Por pagar', expired:'Pago vencido', rejected:'Pago rechazado', refunded:'Pago reembolsado'})[order.payment_status] };
            }
            const label = status === 'preparando' ? 'En preparación' : 'Pedido recibido';
            const start = Date.parse(order.payment_updated_at);
            const minutes = Number(restaurant.pickup_prep_minutes);
            const estimate = Date.parse(order.scheduled_for) || (minutes > 0 ? start + minutes * 60000 : NaN);
            if (!Number.isFinite(estimate)) return minutes > 0 ? { label, timing:`Preparación estimada · ${minutes} min tras confirmar el pago` } : { label };
            if (estimate < now) return { label, timing:'El pedido está tardando más de lo estimado. Consulta al negocio.' };
            return { label, timing:`${order.scheduled_for ? 'Recogida programada' : 'Recogida estimada'} · ${new Date(estimate).toLocaleTimeString('es-MX',{hour:'2-digit',minute:'2-digit',timeZone:restaurant.timezone || 'America/Mexico_City'})}` };
        },
        orderAttempt(storage, key) {
            try { return JSON.parse(storage.getItem(key) || 'null'); } catch { return null; }
        },
        async allRows(makeQuery, size = 500) {
            const rows = [];
            for (let offset = 0; ; offset += size) {
                const { data, error } = await makeQuery().range(offset, offset + size - 1);
                if (error) throw error;
                rows.push(...(data || []));
                if (!data || data.length < size) return rows;
            }
        },
        async createOrderOnce(db, storage, storageKey, payload, randomUUID = () => crypto.randomUUID(), lockPayload = false) {
            const fingerprint = JSON.stringify(payload);
            let attempt = api.orderAttempt(storage, storageKey);
            if (lockPayload && attempt?.payload) payload = attempt.payload;
            else if (!attempt || attempt.fingerprint !== fingerprint || lockPayload) {
                attempt = { fingerprint, requestId: randomUUID(), ...(lockPayload ? { payload } : {}) };
                // Persist BEFORE the request: a lost response must reuse the same server key.
                storage.setItem(storageKey, JSON.stringify(attempt));
            }
            const { data, error } = await db.rpc('create_customer_order_once', { p_request_id: attempt.requestId, p_payload: payload });
            if (error) {
                if (lockPayload && ['P0001','23514','22P02','42501'].includes(error.code)) storage.removeItem(storageKey);
                throw error;
            }
            return data;
        },
        async setFavorite(db, favorites, restaurantId, wanted) {
            const { data, error } = await db.rpc('set_restaurant_favorite', { p_restaurant_id: restaurantId, p_favorite: wanted });
            if (error) throw error;
            if (data === true) favorites.add(restaurantId);
            else if (data === false) favorites.delete(restaurantId);
            else throw new Error('No se confirmó el favorito');
        },
        async previewSound(audio) {
            await audio.play();
            audio.pause();
            audio.currentTime = 0;
        }
    };
    root.SYRuntime = api;
    if (typeof module !== 'undefined') module.exports = api;
})(typeof window === 'undefined' ? globalThis : window);
