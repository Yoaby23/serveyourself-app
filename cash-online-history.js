(function (root) {
    const pageSize = 25;
    const money = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN' });
    const date = new Intl.DateTimeFormat('es-MX', { dateStyle: 'short', timeStyle: 'short' });
    const showAmount = value => value == null ? 'Sin dato' : money.format(value);
    const showDate = value => value ? date.format(new Date(value)) : 'Sin dato';
    const fields = 'id,order_id,event_type,amount,happened_at,provider_fee,provider_vat,provider_net,available_at';

    function dateBoundary(value, days) {
        const local = new Date(value + 'T00:00:00');
        local.setDate(local.getDate() + days);
        return local.toISOString();
    }

    root.startCashOnlineHistory = function (access) {
        const app = root.serveYourself;
        const esc = app.escapeHtml;
        const section = document.getElementById('online-history');
        const form = section.querySelector('form');
        const list = section.querySelector('[data-history-results]');
        const status = section.querySelector('[role=status]');
        const previous = section.querySelector('[data-history-prev]');
        const next = section.querySelector('[data-history-next]');
        const onlineTab = document.querySelector('[data-cash-tab=online]');
        let queryVersion = 0;
        let page = 0;
        let filters = {};

        function card(row) {
            const refund = row.event_type === 'refunded';
            const amount = showAmount(refund ? -Number(row.amount) : row.amount);
            return `<article class="border border-slate-200 rounded-2xl p-4">
                <div class="flex justify-between gap-3"><h3>Pedido #${esc(row.order_id)} · ${refund ? 'Reembolso' : 'Cobro'}</h3><strong>${esc(amount)}</strong></div>
                <p class="text-sm text-slate-600">${esc(showDate(row.happened_at))}</p>
                ${refund ? '' : `<dl class="grid sm:grid-cols-2 gap-2 mt-3 text-sm">
                    <div><dt>Comisión de Mercado Pago</dt><dd>${esc(showAmount(row.provider_fee))}</dd></div>
                    <div><dt>IVA desglosado por Mercado Pago</dt><dd>${esc(showAmount(row.provider_vat))}</dd></div>
                    <div><dt>Neto informado</dt><dd>${esc(showAmount(row.provider_net))}</dd></div>
                    <div><dt>Disponibilidad informada</dt><dd>${esc(showDate(row.available_at))}</dd></div>
                </dl>${row.provider_net == null || row.available_at == null
                    ? `<button type="button" data-settlement="${esc(row.order_id)}" class="sy-config-secondary mt-3">Consultar detalle en Mercado Pago</button>`
                    : ''}`}
            </article>`;
        }

        async function load() {
            const version = ++queryVersion;
            previous.disabled = next.disabled = true;
            status.textContent = 'Consultando historial…';
            let request = app.supabase.from('online_payment_events').select(fields)
                .eq('restaurant_id', access.restaurant_id)
                .order('happened_at', { ascending: false }).order('id', { ascending: false })
                .range(page * pageSize, (page + 1) * pageSize);
            if (filters.folio) request = request.eq('order_id', filters.folio);
            if (filters.from) request = request.gte('happened_at', dateBoundary(filters.from, 0));
            if (filters.through) request = request.lt('happened_at', dateBoundary(filters.through, 1));
            try {
                const { data, error } = await request;
                if (version !== queryVersion) return;
                if (error) throw error;
                list.innerHTML = data.slice(0, pageSize).map(card).join('');
                status.textContent = data.length ? `Página ${page + 1}` : 'No hay cobros ni reembolsos para esta búsqueda.';
                previous.disabled = page === 0;
                next.disabled = data.length <= pageSize;
            } catch {
                if (version !== queryVersion) return;
                list.innerHTML = '';
                status.textContent = 'No se pudo cargar el historial. Vuelve a pulsar Buscar.';
            }
        }

        form.addEventListener('submit', event => {
            event.preventDefault();
            const entries = Object.fromEntries(new FormData(form));
            if (entries.from && entries.through && entries.from > entries.through) {
                status.textContent = 'La fecha inicial debe ser anterior o igual a la final.';
                return;
            }
            filters = entries;
            page = 0;
            load();
        });
        previous.addEventListener('click', () => { page--; load(); });
        next.addEventListener('click', () => { page++; load(); });
        list.addEventListener('click', async event => {
            const button = event.target.closest('button[data-settlement]');
            if (!button || button.disabled) return;
            button.disabled = true;
            const version = queryVersion;
            status.textContent = 'Consultando el detalle en Mercado Pago…';
            try {
                const response = await app.reconcileMercadoPagoOrder(button.dataset.settlement, null, true);
                if (version !== queryVersion) return;
                if (response.status === 409) {
                    status.textContent = 'Mercado Pago no devolvió un desglose de este cobro. El reembolso, si existe, sigue visible en el historial.';
                } else if (response.ok) {
                    await load();
                } else {
                    throw Error('No se pudo consultar');
                }
            } catch {
                if (version === queryVersion) status.textContent = 'No se pudo consultar el detalle. Inténtalo de nuevo.';
            } finally {
                button.disabled = false;
            }
        });
        onlineTab.addEventListener('click', load);
        if (root.location.hash === '#online') load();
        return load;
    };
})(window);
