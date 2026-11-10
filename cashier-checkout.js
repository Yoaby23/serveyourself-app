async function requestCreditAuthorization(action, askLimit=false) {
    const dialog=document.createElement('dialog');
    dialog.className='sy-action-dialog rounded-3xl p-6 border max-w-md w-full';
    dialog.innerHTML='<form class="space-y-4"><h2 class="text-xl font-black">Autorizar crédito</h2><p>Confirma con una cuenta autorizada del restaurante.</p><label class="block">Correo de quien autoriza<input name="email" type="email" autocomplete="username" required class="block border rounded-xl p-3 w-full"></label><label class="block">Contraseña<input name="password" type="password" autocomplete="current-password" required class="block border rounded-xl p-3 w-full"></label>'+(askLimit?'<label class="block">Límite autorizado<input name="limit" type="number" min="0.01" step="0.01" required class="block border rounded-xl p-3 w-full"></label>':'')+'<p role="status" aria-live="polite"></p><button type="submit" class="bg-orange-500 text-white rounded-xl p-3">Autorizar</button><button type="button" data-cancel class="p-3">Cancelar</button></form>';
    document.body.appendChild(dialog);
    let busy=false;
    const result=await new Promise(resolve=>{
        dialog.querySelector('[data-cancel]').onclick=()=>dialog.close();
        dialog.addEventListener('cancel',event=>{if(busy)event.preventDefault();});
        dialog.addEventListener('close',()=>resolve(null),{once:true});
        dialog.querySelector('form').onsubmit=async event=>{
            event.preventDefault();
            if(busy)return;
            busy=true;
            const button=dialog.querySelector('button'),cancel=dialog.querySelector('[data-cancel]');
            button.disabled=true;cancel.disabled=true;
            const isolated=window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
            let authorized=null;
            try{
                const {error:loginError}=await isolated.auth.signInWithPassword({email:dialog.querySelector('[name=email]').value.trim(),password:dialog.querySelector('[name=password]').value});
                dialog.querySelector('[name=password]').value='';
                if(loginError)throw new Error('Revisa el correo y la contraseña.');
                const limit=askLimit?Number(dialog.querySelector('[name=limit]').value):null;
                const {data,error}=await action(isolated,limit);
                if(error)throw error;
                if(!data)throw new Error('No se pudo confirmar la autorización.');
                authorized=data;
            }catch(error){dialog.querySelector('[role=status]').textContent=error.message;}
            finally{
                dialog.querySelector('[name=password]').value='';
                try{await isolated.auth.signOut({scope:'local'});}catch(error){console.warn('No se pudo cerrar la autorización temporal',error);}
                busy=false;button.disabled=false;cancel.disabled=false;
            }
            if(authorized){resolve(authorized);dialog.close();}
        };
        dialog.showModal();
    });
    dialog.remove();
    return result;
}

async function authorizeCustomerCredit(restaurantId,customerId){
    return Boolean(await requestCreditAuthorization((client,limit)=>client.rpc('set_customer_credit_settings',{p_restaurant_id:restaurantId,p_customer_id:customerId,p_enabled:true,p_credit_limit:limit}),true));
}

async function createCheckoutCreditCustomer(restaurantId,defaults={}){
    const dialog=document.createElement('dialog');
    dialog.className='sy-action-dialog rounded-3xl p-6 border max-w-md w-full';
    dialog.innerHTML='<form class="space-y-4"><h2 class="text-xl font-black">Nuevo cliente a crédito</h2><label class="block">Nombre<input name="customer-name" type="text" autocomplete="name" minlength="2" maxlength="120" required class="block border rounded-xl p-3 w-full"></label><label class="block">Teléfono<input name="phone" type="tel" autocomplete="tel" maxlength="30" pattern="[+0-9 ]{7,30}" required class="block border rounded-xl p-3 w-full"></label><label class="block">Límite de crédito<input name="credit-limit" type="number" min="0.01" step="0.01" required class="block border rounded-xl p-3 w-full"></label><p role="status" aria-live="polite"></p><button type="submit" class="bg-orange-500 text-white rounded-xl p-3">Confirmar datos</button><button type="button" data-cancel class="p-3">Cancelar</button></form>';
    dialog.querySelector('[name=customer-name]').value=defaults.name||'';
    dialog.querySelector('[name=credit-limit]').value=Number.isFinite(Number(defaults.limit))&&Number(defaults.limit)>0?Number(defaults.limit).toFixed(2):'';
    document.body.appendChild(dialog);
    const requestId=crypto.randomUUID();
    let busy=false;
    const customer=await new Promise(resolve=>{
        dialog.querySelector('[data-cancel]').onclick=()=>dialog.close();
        dialog.addEventListener('close',()=>resolve(null),{once:true});
        dialog.addEventListener('cancel',event=>{if(busy)event.preventDefault();});
        dialog.querySelector('form').onsubmit=async event=>{
            event.preventDefault();
            if(busy)return;
            busy=true;
            const button=dialog.querySelector('button'),cancel=dialog.querySelector('[data-cancel]');
            button.disabled=true;cancel.disabled=true;
            try{
                const args={p_customer_id:requestId,p_restaurant_id:restaurantId,p_name:dialog.querySelector('[name=customer-name]').value.trim(),p_phone:dialog.querySelector('[name=phone]').value.trim(),p_credit_limit:Number(dialog.querySelector('[name=credit-limit]').value)};
                const {data,error}=await window.serveYourself.supabase.rpc('create_credit_customer_from_checkout',args);
                let saved=data;
                if(error?.code==='42501')saved=await requestCreditAuthorization(client=>client.rpc('create_credit_customer_from_checkout',args));
                else if(error)throw error;
                if(saved){resolve(saved);dialog.close();}
            }catch(error){dialog.querySelector('[role=status]').textContent=error.message;}
            finally{busy=false;button.disabled=false;cancel.disabled=false;}
        };
        dialog.showModal();
    });
    dialog.remove();
    return customer;
}

function selectCheckoutCreditCustomer(select,customer){
    let option=[...select.options].find(item=>item.value===customer.id);
    if(!option){option=document.createElement('option');option.value=customer.id;select.appendChild(option);}
    option.textContent=customer.customer_name;
    select.value=customer.id;
}

async function showCashierPaymentQR(orderId, button) {
    button.disabled = true;
    try {
        const {data,error} = await window.serveYourself.supabase.functions.invoke('create-mercado-pago-preference', {body:{orderId}});
        if (error || !data?.checkoutUrl) throw new Error(data?.error || error?.message || 'No se pudo abrir el pago.');
        const dialog = document.createElement('dialog');
        dialog.className = 'rounded-3xl p-6 border max-w-sm w-full';
        dialog.innerHTML = '<h2 class="text-xl font-black">Pagar con Mercado Pago</h2><div data-qr class="my-4"></div><p>Escanea con tu celular para continuar el pago.</p><a target="_blank" rel="noopener" class="block my-4 font-bold">Abrir pago</a><button type="button" class="p-3 rounded-xl bg-slate-100">Cerrar</button>';
        dialog.querySelector('a').href = data.checkoutUrl;
        dialog.querySelector('button').onclick = () => dialog.close();
        dialog.addEventListener('close', () => dialog.remove(), {once:true});
        document.body.appendChild(dialog);
        new QRCode(dialog.querySelector('[data-qr]'), {text:data.checkoutUrl,width:220,height:220});
        dialog.showModal();
    } catch (error) { alert(error.message); }
    finally { button.disabled = false; }
}

async function createCashierOrderOnce(db, storage, key, payload) {
    const adapter = {rpc:(_name, request) => db.rpc('cashier_create_takeaway', {
        p_request_id:request.p_request_id, ...request.p_payload
    })};
    try {
        return await SYRuntime.createOrderOnce(adapter, storage, key, payload);
    } catch (error) {
        // Validation failures rolled back the transaction. Unknown outcomes retain the key.
        if (error.code === 'P0001' || error.code === '23514' || error.code === '22023') storage.removeItem(key);
        throw error;
    }
}

async function recordCashOperationOnce(db, storage, key, operation, payload) {
    const pending=JSON.parse(storage.getItem(key)||'null');
    const request=pending?JSON.parse(pending.fingerprint):{operation,payload};
    const adapter={rpc:(_name,args)=>db.rpc('record_cash_operation_once',{
        p_request_id:args.p_request_id,p_operation:args.p_payload.operation,p_payload:args.p_payload.payload
    })};
    try{
        const data=await SYRuntime.createOrderOnce(adapter,storage,key,request);
        storage.removeItem(key);
        return {data:{...data,confirmed_payment_method:request.payload.p_payment_method},recovered:Boolean(pending)};
    }catch(error){
        if(error.code==='P0001'||error.code==='23514'||error.code==='22023')storage.removeItem(key);
        throw error;
    }
}
