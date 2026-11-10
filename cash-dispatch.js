window.startCashDispatch=function startCashDispatch(access){
    const db=window.serveYourself.supabase,esc=window.serveYourself.escapeHtml;
    const list=document.getElementById('dispatch-orders'),status=document.getElementById('dispatch-status');
    const labels={pending_acceptance:'Por confirmar',accepted:'Confirmado',preparing:'En cocina',ready_for_dispatch:'Listo para reparto',picked_up:'Recogido',on_the_way:'En ruta',arrived:'En el destino'};
    const busy=new Set();
    let orders=[],drivers=[];
    const refresh=SYRuntime.serialRefresh(async()=>{
        try{
            const [o,d]=await Promise.all([
                SYRuntime.allRows(()=>db.from('orders').select('id,delivery_contact_name,delivery_address,delivery_status,payment_method,payment_status,assigned_driver_id,assigned_driver_name').eq('restaurant_id',access.restaurant_id).eq('service_type','delivery').neq('status','cancelado').in('delivery_status',Object.keys(labels)).order('created_at').order('id')),
                db.rpc('list_delivery_drivers',{p_restaurant_id:access.restaurant_id})
            ]);
            if(d.error)throw d.error;
            orders=o;drivers=d.data||[];render();status.textContent='';
        }catch(error){status.textContent='No se pudo actualizar el reparto. Se conservan los últimos datos.';}
    });
    function render(){
        list.innerHTML=orders.length?orders.map(order=>{
            const unpaid=order.payment_method==='mercado_pago'&&order.payment_status!=='approved';
            const pending=order.delivery_status==='pending_acceptance';
            const assigned=Boolean(order.assigned_driver_id);
            const waiting=['accepted','preparing','ready_for_dispatch'].includes(order.delivery_status);
            const options=drivers.map(driver=>`<option value="${esc(driver.user_id)}" ${!driver.is_available||Number(driver.active_orders)>0?'disabled':''}>${esc(driver.full_name||'Repartidor')}${Number(driver.active_orders)>0?' · ocupado':!driver.is_available?' · fuera de línea':''}</option>`).join('');
            let action='';
            if(unpaid)action='<p class="cash-muted">Esperando confirmación del pago.</p>';
            else if(pending)action=`<button type="button" data-action="confirm" data-order="${order.id}" class="cash-action cash-action-primary" ${busy.has(order.id)?'disabled':''}>CONFIRMAR PEDIDO</button>`;
            else if(assigned)action=`<p class="font-bold mt-3">Repartidor · ${esc(order.assigned_driver_name||'Asignado')}</p>${waiting?`<button type="button" data-action="release" data-order="${order.id}" class="cash-action" ${busy.has(order.id)?'disabled':''}>CAMBIAR REPARTIDOR</button>`:''}`;
            else if(waiting)action=`<label class="block mt-3">Repartidor<select data-driver-for="${order.id}" class="block p-3 border rounded-xl w-full" ${busy.has(order.id)?'disabled':''}><option value="">Selecciona un repartidor disponible</option>${options}</select></label><button type="button" data-action="assign" data-order="${order.id}" class="cash-action cash-action-primary mt-3" ${busy.has(order.id)?'disabled':''}>ASIGNAR ENTREGA</button>`;
            return `<article class="cash-account-card"><div class="flex justify-between gap-3"><b>Pedido #${order.id}</b><span>${esc(labels[order.delivery_status])}</span></div><p class="font-bold mt-2">${esc(order.delivery_contact_name||'Cliente')}</p><p class="cash-muted">${esc(order.delivery_address||'')}</p>${action}</article>`;
        }).join(''):'<p class="cash-empty">No hay pedidos a domicilio pendientes.</p>';
    }
    list.addEventListener('click',async event=>{
        const button=event.target.closest('[data-action]');
        if(!button)return;
        const id=Number(button.dataset.order),order=orders.find(row=>row.id===id);
        if(!order||busy.has(id))return;
        const action=button.dataset.action;
        let driverId,reason;
        if(action==='assign'){
            driverId=list.querySelector(`select[data-driver-for="${id}"]`).value;
            if(!driverId){status.textContent='Selecciona un repartidor disponible.';return;}
        }
        if(action==='release'){
            reason=window.prompt('Motivo del cambio de repartidor');
            if(!reason)return;
        }
        busy.add(id);button.disabled=true;
        try{
            const rpc=action==='assign'?'assign_delivery_driver':action==='confirm'?'accept_delivery_order':'release_delivery_order';
            const args=action==='assign'?{p_order_id:id,p_driver_id:driverId}:action==='confirm'?{p_order_id:id,p_accept:true}:{p_order_id:id,p_reason:reason,p_expected_driver:order.assigned_driver_id};
            const {error}=await db.rpc(rpc,args);
            if(error)throw error;
            await refresh();
        }catch(error){status.textContent=error.message||'No se pudo actualizar la asignación.';}
        finally{busy.delete(id);render();}
    });
    db.channel(`cash-dispatch-${access.restaurant_id}`).on('postgres_changes',{event:'*',schema:'public',table:'orders',filter:`restaurant_id=eq.${access.restaurant_id}`},refresh).subscribe();
    setInterval(()=>{if(!document.hidden)refresh();},15000);
    window.addEventListener('online',refresh);
    document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
    refresh();
};
