do $$
declare
    owner_id uuid := gen_random_uuid();
    customer_id uuid := gen_random_uuid();
    other_id uuid := gen_random_uuid();
    item_id uuid;
    order_id bigint;
    details jsonb;
begin
    insert into auth.users(id, email, raw_user_meta_data) values
        (owner_id, owner_id || '@example.invalid', '{"role":"negocio","business_name":"QA transferencia"}'),
        (customer_id, customer_id || '@example.invalid', '{"full_name":"Cliente QA"}'),
        (other_id, other_id || '@example.invalid', '{"full_name":"Otro cliente QA"}');
    update public.profiles
    set payment_transfer = true, bank_name = 'Banco de prueba',
        bank_account_holder = 'Titular de prueba', bank_clabe = '001234567890123456',
        open_time = null, close_time = null
    where id = owner_id;
    insert into public.products(restaurant_id, name, price)
    values (owner_id, 'Producto de prueba', 40) returning id into item_id;

    assert not has_function_privilege('anon', 'public.get_order_transfer_details(bigint)', 'EXECUTE');
    assert not has_table_privilege('authenticated', 'sy_private.integration_settings', 'UPDATE');
    execute 'set local role anon';
    assert exists(select 1 from public.public_restaurants p where p.id = owner_id);
    assert exists(select 1 from public.public_qr_restaurants p where p.id = owner_id);
    assert exists(select 1 from public.public_qr_products p where p.id = item_id);
    execute 'reset role';

    perform set_config('request.jwt.claim.sub', customer_id::text, true);
    execute 'set local role authenticated';
    order_id := (public.create_customer_order_once(gen_random_uuid(), jsonb_build_object(
        'restaurant_id', owner_id, 'service_type', 'pickup', 'payment_method', 'transfer',
        'pickup_name', 'Cliente QA', 'items', jsonb_build_array(jsonb_build_object('id', item_id, 'qty', 1))
    ))->>'id')::bigint;
    details := public.get_order_transfer_details(order_id);
    assert details->>'bank_clabe' = '001234567890123456', 'Owner of pending order must see instructions';
    perform set_config('request.jwt.claim.sub', other_id::text, true);
    assert public.get_order_transfer_details(order_id) is null, 'Another customer can see bank details';
    execute 'reset role';
    update public.orders o set payment_expires_at = now() - interval '1 second' where o.id = order_id;
    perform set_config('request.jwt.claim.sub', customer_id::text, true);
    execute 'set local role authenticated';
    assert public.get_order_transfer_details(order_id) is null, 'Expired order exposed bank details';
    execute 'reset role';
end;
$$;
