-- Complete the existing authenticated checkout without introducing another endpoint.
do $$
declare definition text;
begin
 definition:=pg_get_functiondef('public.create_customer_order_once(uuid,jsonb)'::regprocedure);
 definition:=replace(definition,'v_order public.orders%rowtype;','v_order public.orders%rowtype;v_pickup_name text;');
 definition:=replace(definition,'   v_created:=public.create_scheduled_pickup_order',
 '   v_pickup_name:=case when p_payload ? ''pickup_name'' then btrim(p_payload->>''pickup_name'') else (select nullif(btrim(full_name),'''') from public.profiles where id=v_user) end;
   if v_pickup_name is null or char_length(v_pickup_name) not between 1 and 80 then raise exception ''Indica el nombre de quien recoge (1 a 80 caracteres)'';end if;
   v_created:=public.create_scheduled_pickup_order');
 definition:=replace(definition,' else raise exception ''Servicio inválido'';end if;',
 '   update public.orders set pickup_name=v_pickup_name where id=(v_created->>''id'')::bigint returning * into v_order;
   v_created:=to_jsonb(v_order);
 else raise exception ''Servicio inválido'';end if;');
 execute definition;
 definition:=pg_get_functiondef('public.register_pos_payment_v2(bigint,text,numeric,numeric,numeric)'::regprocedure);
 definition:=replace(definition,'v_order.payment_method=''cash''','v_order.payment_method in (''cash'',''transfer'')');
 definition:=replace(definition,'p_payment_method is distinct from ''cash''','p_payment_method is distinct from v_order.payment_method');
 definition:=replace(definition,'Este pedido se paga en efectivo en caja','Confirma el método de pago elegido por el cliente');
 execute definition;
 definition:=pg_get_functiondef('public.cancel_order(bigint,text)'::regprocedure);
 definition:=replace(definition,'order_record.payment_method=''cash''','order_record.payment_method in (''cash'',''transfer'')');
 execute definition;
end;$$;
