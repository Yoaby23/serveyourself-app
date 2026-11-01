/* Cashier handoff uses the same tickets and delivery RPC as POS. */
window.startCashReady = function startCashReady(access) {
    const { supabase: db, escapeHtml: esc } = window.serveYourself;
    const list = document.getElementById('ready-pickup-list');
    const count = document.getElementById('ready-pickup-count');
    const notice = document.getElementById('ready-pickup-notice');
    const delivering = new Set();
    let tickets = [], running = false, dirty = false, known = new Set();
    function render() {
        count.textContent = String(tickets.length);
        list.innerHTML = tickets.map(ticket => `<article class="cash-account-card">
            <b class="text-lg">Pedido #${Number(ticket.order_id)}</b>
            <p class="font-black">${esc(ticket.orders?.pickup_name || 'Sin nombre registrado')}</p>
            <p class="text-sm text-slate-500">Comanda #${Number(ticket.id)}</p>
            <div class="mt-3 text-sm">${(ticket.items || []).map(item => `<p>${Number(item.qty)}× ${esc(item.nombre)}</p>`).join('')}</div>
            <button type="button" data-deliver="${Number(ticket.id)}" ${delivering.has(ticket.id) ? 'disabled' : ''} class="w-full mt-3 py-3 rounded-xl bg-emerald-600 text-white font-black">${delivering.has(ticket.id) ? 'GUARDANDO…' : 'CONFIRMAR ENTREGA'}</button>
        </article>`).join('');
    }
    async function refresh() {
        dirty = true;
        if (running) return;
        running = true;
        try {
            while (dirty) {
                dirty = false;
                const { data, error } = await db.from('kitchen_tickets')
                    .select('id,order_id,items,orders!inner(pickup_name,status)')
                    .eq('restaurant_id', access.restaurant_id).eq('service_type', 'pickup')
                    .eq('status', 'listo').neq('orders.status', 'cancelado').order('ready_at');
                if (error) throw error;
                tickets = data || [];
                const arrivals = tickets.filter(ticket => !known.has(ticket.id));
                known = new Set(tickets.map(ticket => ticket.id));
                notice.textContent = arrivals.length
                    ? arrivals.map(ticket => `Pedido #${ticket.order_id} listo: ${ticket.orders?.pickup_name || 'sin nombre registrado'}.`).join(' ')
                    : tickets.length ? 'Verifica el número y el nombre antes de confirmar la entrega.' : 'No hay pedidos para llevar pendientes de entrega.';
                render();
            }
        } catch {
            notice.textContent = 'No se pudo actualizar la lista. Se reintentará automáticamente.';
        } finally { running = false; }
    }
    list.addEventListener('click', async event => {
        const button = event.target.closest('[data-deliver]');
        if (!button) return;
        const id = Number(button.dataset.deliver), ticket = tickets.find(row => row.id === id);
        if (!ticket || delivering.has(id)) return;
        if (!window.confirm(`¿Entregar el pedido #${ticket.order_id} a ${ticket.orders?.pickup_name || 'la persona que recoge'}?`)) return;
        delivering.add(id); render();
        try {
            const { error } = await db.rpc('mark_kitchen_ticket_delivered', { p_ticket_id: id });
            if (error) throw error;
            tickets = tickets.filter(row => row.id !== id);
        } catch (error) {
            window.alert(error.message || 'No se pudo confirmar la entrega. Reintenta.');
        } finally { delivering.delete(id); render(); await refresh(); }
    });
    const filter = `restaurant_id=eq.${access.restaurant_id}`;
    db.channel(`cash-ready-${access.restaurant_id}`)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'kitchen_tickets', filter }, refresh)
        .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'orders', filter }, refresh)
        .subscribe(status => { if (status === 'SUBSCRIBED') refresh(); });
    setInterval(() => { if (!document.hidden) refresh(); }, 15000);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
    window.addEventListener('pageshow', refresh);
    window.addEventListener('online', refresh);
    refresh();
};
