async function authorizeCustomerCredit(restaurantId, customerId) {
    const dialog = document.createElement('dialog');
    dialog.className = 'rounded-3xl p-6 border max-w-md w-full';
    dialog.innerHTML = '<form class="space-y-4"><h2 class="text-xl font-black">Autorizar crédito</h2><p>Un propietario del restaurante debe confirmar esta autorización.</p><label class="block">Correo de quien autoriza<input name="email" type="email" autocomplete="username" required class="block border rounded-xl p-3 w-full"></label><label class="block">Contraseña<input name="password" type="password" autocomplete="current-password" required class="block border rounded-xl p-3 w-full"></label><label class="block">Límite de crédito autorizado<input name="limit" type="number" min="0.01" step="0.01" required class="block border rounded-xl p-3 w-full"></label><p role="status"></p><button type="submit" class="bg-orange-500 text-white rounded-xl p-3">Autorizar</button><button type="button" data-cancel class="p-3">Cancelar</button></form>';
    document.body.appendChild(dialog);
    const authorized = await new Promise(resolve => {
        dialog.querySelector('[data-cancel]').onclick = () => dialog.close();
        dialog.addEventListener('close', () => resolve(false), {once:true});
        dialog.querySelector('form').onsubmit = async event => {
            event.preventDefault();
            const button = dialog.querySelector('button');
            button.disabled = true;
            const isolated = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {auth:{persistSession:false, autoRefreshToken:false, detectSessionInUrl:false}});
            try {
                const {error: loginError} = await isolated.auth.signInWithPassword({
                    email:dialog.querySelector('[name=email]').value.trim(),
                    password:dialog.querySelector('[name=password]').value
                });
                dialog.querySelector('[name=password]').value = '';
                if (loginError) throw new Error('Revisa el correo y la contraseña.');
                const {error} = await isolated.rpc('set_customer_credit_settings', {p_restaurant_id:restaurantId, p_customer_id:customerId, p_enabled:true, p_credit_limit:Number(dialog.querySelector('[name=limit]').value)});
                if (error) throw error;
                resolve(true);
                dialog.close();
            } catch (error) { dialog.querySelector('[role=status]').textContent = error.message; }
            finally { await isolated.auth.signOut({scope:'local'}); button.disabled = false; }
        };
    });
    dialog.remove();
    return authorized;
}
