/* Manual observations use the same server-side estimator as the kitchen queue. */
(() => {
    const labels = {pickup:'Para llevar / pickup',dine_in:'En mesa',delivery:'Delivery'};
    function create({db, access, products, onTrained, root = document}) {
        const esc = window.serveYourself.escapeHtml;
        const dialog = root.getElementById('kitchen-training-dialog');
        const form = root.getElementById('kitchen-training-form');
        const rows = root.getElementById('training-items');
        const status = root.getElementById('training-message');
        const preview = root.getElementById('training-preview');
        let busy=false, request=null, signature=null, models=[], recent=[];
        const service=()=>root.getElementById('training-service').value;
        const message=(text,error=false)=>{status.textContent=text;status.dataset.error=String(error);};
        function itemRow() {
            const row=document.createElement('div');row.className='sy-training-item';
            row.innerHTML=`<label>Producto<select data-product required><option value="">Selecciona un producto</option>${products.map(p=>`<option value="${esc(p.id)}">${esc(p.name)}</option>`).join('')}</select></label><label>Cantidad<input data-quantity type="number" min="1" max="100" step="1" value="1" required></label><button type="button" class="sy-training-secondary" data-remove>Quitar</button>`;
            row.querySelector('[data-remove]').onclick=()=>{if(rows.children.length>1){row.remove();preview.textContent='';}};
            rows.appendChild(row);
        }
        function payload() {
            const items=[...rows.querySelectorAll('.sy-training-item')].map(row=>({id:row.querySelector('[data-product]').value,qty:Number(row.querySelector('[data-quantity]').value)}));
            if(!items.length||items.some(x=>!x.id||!Number.isInteger(x.qty)||x.qty<1||x.qty>100))throw Error('Selecciona productos y cantidades de 1 a 100.');
            if(new Set(items.map(x=>x.id)).size!==items.length)throw Error('Usa una sola fila por producto y ajusta su cantidad.');
            return {p_restaurant_id:access.restaurant_id,p_service_type:service(),p_items:items,p_is_peak:root.getElementById('training-peak').checked};
        }
        function renderStatus() {
            root.getElementById('training-models').innerHTML=Object.entries(labels).map(([key,label])=>{
                const m=models.find(x=>x.service_type===key);
                const n=Number(m?.sample_count||0);
                const note=m?.model_ready?'Validado; se usa con productos, cantidades y horario cubiertos':n<10?`Calibrando · faltan ${10-n} mediciones`:'Requiere más datos: precisión insuficiente';
                return `<article><b>${label}</b><strong>${n} mediciones</strong><p>${note}</p>${m?.mean_absolute_error!=null?`<p>Error de validación: ${Number(m.mean_absolute_error).toFixed(1)} min · ${Number(m.validation_sample_count)} ejemplos reservados</p>`:''}<p>Horario normal: ${Number(m?.off_peak_sample_count||0)} · Hora pico: ${Number(m?.peak_sample_count||0)}</p>${m?.trained_at?`<small>Entrenado: ${esc(new Date(m.trained_at).toLocaleString('es-MX'))}</small>`:''}</article>`;
            }).join('');
            root.getElementById('training-history').innerHTML=recent.length?recent.map(s=>`<li><div><b>${esc(labels[s.service_type]||s.service_type)} · ${Number(s.prep_minutes)} min</b><p>${(s.items||[]).map(i=>`${Number(i.qty)} × ${esc(i.nombre||products.find(p=>p.id===i.id)?.name||'Producto')}`).join(', ')}</p><small>${s.is_peak?'Hora pico':'Horario normal'} · ${s.manual?'Medición manual':'Comanda real'}</small></div>${s.manual?`<button type="button" class="sy-action-danger" data-delete-sample="${Number(s.id)}">Eliminar</button>`:''}</li>`).join(''):'<li>Sin mediciones. Registra preparaciones reales para comenzar.</li>';
        }
        async function loadStatus() {
            const {data,error}=await db.rpc('get_kitchen_training_status',{p_restaurant_id:access.restaurant_id});
            if(error){message('No se pudo actualizar el entrenamiento: '+error.message,true);return;}
            models=data?.models||[];recent=data?.recent_samples||[];renderStatus();
        }
        async function run(action) {
            if(busy)return;busy=true;
            const buttons=[...dialog.querySelectorAll('button')];buttons.forEach(b=>b.disabled=true);
            message('Procesando…');
            try{await action();}catch(error){message(error.message||'No se pudo completar. Reintenta.',true);}
            finally{busy=false;buttons.forEach(b=>b.disabled=false);}
        }
        async function save(event) {
            event?.preventDefault();
            return run(async()=>{
                const data=payload(),minutes=Number(root.getElementById('training-minutes').value);
                if(!Number.isFinite(minutes)||minutes<1||minutes>240)throw Error('Indica el tiempo real de preparación: de 1 a 240 minutos.');
                const next=JSON.stringify({...data,p_prep_minutes:minutes});
                if(signature!==next){signature=next;request=crypto.randomUUID();}
                const {error}=await db.rpc('save_kitchen_training_sample',{...data,p_prep_minutes:minutes,p_request_id:request});
                if(error)throw error;
                request=null;signature=null;root.getElementById('training-minutes').value='';preview.textContent='';
                message('Medición guardada. El modelo se reentrenó con los datos disponibles.');
                await loadStatus();await onTrained?.();
            });
        }
        async function estimate() {return run(async()=>{
            const {data,error}=await db.rpc('preview_kitchen_training',payload());if(error)throw error;
            preview.textContent=`${Number(data.minutes).toFixed(1)} min · ${data.model_ready?'Modelo entrenado':'Tiempo configurado'}. ${data.reason}`;
            message('Estimación comprobada sin crear pedidos ni guardar mediciones.');
        });}
        async function train() {return run(async()=>{
            const {data,error}=await db.rpc('train_kitchen_model',{p_restaurant_id:access.restaurant_id,p_service_type:service()});if(error)throw error;
            preview.textContent='';message(data.model_ready?'Modelo entrenado y validado. Se aplicará a las comandas compatibles.':`Entrenamiento terminado: ${Number(data.sample_count||0)} mediciones. Se conserva el tiempo configurado hasta pasar la validación.`);
            await loadStatus();await onTrained?.();
        });}
        async function remove(id) {
            if(!window.confirm('¿Eliminar esta medición manual y recalcular el modelo?'))return;
            return run(async()=>{const {error}=await db.rpc('delete_kitchen_training_sample',{p_sample_id:id});if(error)throw error;preview.textContent='';message('Medición eliminada y modelo recalculado.');await loadStatus();await onTrained?.();});
        }
        root.getElementById('kitchen-training-open').onclick=async()=>{if(!dialog.open)dialog.showModal();await loadStatus();};
        root.getElementById('kitchen-training-close').onclick=()=>dialog.close();
        root.getElementById('training-add-item').onclick=()=>{if(rows.children.length<50)itemRow();};
        root.getElementById('training-estimate').onclick=estimate;
        root.getElementById('training-retrain').onclick=train;
        root.getElementById('training-history').onclick=event=>{const b=event.target.closest('[data-delete-sample]');if(b)remove(Number(b.dataset.deleteSample));};
        form.onsubmit=save;form.oninput=()=>{preview.textContent='';};
        itemRow();
        return {save,estimate,train,loadStatus,remove,payload};
    }
    window.SYKitchenTraining={create};
})();
