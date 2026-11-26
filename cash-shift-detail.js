(function(root) {
    const methods = {cash:'Efectivo', transfer:'Transferencia', card_terminal:'Terminal', mercado_pago:'Mercado Pago'};
    function shiftRows(payments, credit, movements, online) {
        return [
            ...payments.map(p => ({group:methods[p.payment_method] || 'Otros pagos', title:`Pedido #${p.order_id}`, amount:Number(p.amount)+Number(p.tip_amount || 0), time:p.created_at})),
            ...credit.map(c => ({
                group:c.entry_type === 'charge' ? 'Ventas a crédito' : `Abonos a crédito · ${methods[c.payment_method] || 'Otro método'}`,
                title:c.order_id ? `Pedido #${c.order_id}` : `Abono #${c.id}`, amount:Number(c.amount), time:c.created_at
            })),
            ...movements.map(m => ({group:'Movimientos de caja',title:m.reason,amount:Number(m.amount)*(m.movement_type==='income'?1:-1),time:m.created_at})),
            ...online.map(o => ({
                group:o.event_type==='refunded' ? 'Reembolsos en Mercado Pago' : 'Pagos en Mercado Pago',
                title:`Pedido #${o.order_id}`,amount:Number(o.amount)*(o.event_type==='refunded'?-1:1),time:o.happened_at
            }))
        ].sort((a,b)=>Date.parse(b.time)-Date.parse(a.time));
    }
    root.SYShiftDetail = { shiftRows, methods };
    if (typeof module !== 'undefined') module.exports = root.SYShiftDetail;
})(typeof window === 'undefined' ? globalThis : window);
