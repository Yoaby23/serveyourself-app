do $$
declare
    owner_id uuid := gen_random_uuid();
    customer_id uuid := gen_random_uuid();
    other_id uuid := gen_random_uuid();
    v_order bigint;
    v_product uuid;
begin
    insert into auth.users(id,email,raw_user_meta_data) values
        (owner_id,owner_id||'@example.invalid','{"role":"negocio","business_name":"QA caja"}'),
        (customer_id,customer_id||'@example.invalid','{"full_name":"Cliente QA"}'),
        (other_id,other_id||'@example.invalid','{"full_name":"Otra cuenta QA"}');
    update public.profiles set payment_online=true,mercado_pago_connected=true where id=owner_id;
    insert into public.products(restaurant_id,name,price) values(owner_id,'Comida QA',85) returning id into v_product;
    insert into public.orders(restaurant_id,customer_id,items,total,payment_method,payment_status)
    values(owner_id,customer_id,jsonb_build_array(jsonb_build_object('id',v_product,'qty',1,'name','Comida QA','price',85)),85,'mercado_pago','pending') returning id into v_order;
    update public.orders set payment_status='approved',mercado_pago_payment_id='qa-payment',payment_updated_at=now() where id=v_order;
    update public.orders set payment_status='approved' where id=v_order;
    update public.orders set payment_status='refunded',payment_updated_at=now() where id=v_order;
    assert (select count(*)=2 from public.online_payment_events where order_id=v_order);
    assert (select sum(amount)=170 from public.online_payment_events where order_id=v_order);

    assert not has_table_privilege('anon','public.online_payment_events','SELECT');
    assert not has_table_privilege('authenticated','public.online_payment_events','INSERT');
    assert not has_column_privilege('authenticated','public.online_payment_events','provider_net','UPDATE');
    execute 'set local role service_role';
    update public.online_payment_events set provider_fee=4.20,provider_net=80.80
    where order_id=v_order and event_type='approved';
    execute 'reset role';
    assert (select provider_net=80.80 from public.online_payment_events where order_id=v_order and event_type='approved');
    assert (select provider_net is null from public.online_payment_events where order_id=v_order and event_type='refunded');
    perform set_config('request.jwt.claim.sub',other_id::text,true);
    execute 'set local role authenticated';
    assert not exists(select from public.online_payment_events where order_id=v_order);
    perform set_config('request.jwt.claim.sub',owner_id::text,true);
    assert (select count(*)=2 from public.online_payment_events where order_id=v_order);
    execute 'reset role';
end;
$$;
