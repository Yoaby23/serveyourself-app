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
        async allRows(makeQuery, size = 500) {
            const rows = [];
            for (let offset = 0; ; offset += size) {
                const { data, error } = await makeQuery().range(offset, offset + size - 1);
                if (error) throw error;
                rows.push(...(data || []));
                if (!data || data.length < size) return rows;
            }
        },
        async createOrderOnce(db, storage, storageKey, payload, randomUUID = () => crypto.randomUUID()) {
            const fingerprint = JSON.stringify(payload);
            let attempt;
            try { attempt = JSON.parse(storage.getItem(storageKey) || 'null'); } catch { /* Replace invalid state. */ }
            if (!attempt || attempt.fingerprint !== fingerprint) {
                attempt = { fingerprint, requestId: randomUUID() };
                // Persist BEFORE the request: a lost response must reuse the same server key.
                storage.setItem(storageKey, JSON.stringify(attempt));
            }
            const { data, error } = await db.rpc('create_customer_order_once', { p_request_id: attempt.requestId, p_payload: payload });
            if (error) throw error;
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
