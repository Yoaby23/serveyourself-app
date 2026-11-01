-- Execute under BEGIN / ROLLBACK.
do $$
declare owner_id uuid:=gen_random_uuid();customer_id uuid:=gen_random_uuid();cashier_id uuid:=gen_random_uuid();product_id uuid;request_id uuid:=gen_random_uuid();payload jsonb;o jsonb;again jsonb;blocked boolean;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-'||owner_id||'@example.invalid','{"role":"negocio","business_name":"Checkout QA"}'),
 (customer_id,'qa-'||customer_id||'@example.invalid','{"full_name":"Nombre del perfil"}'),
 (cashier_id,'qa-'||cashier_id||'@example.invalid','{"full_name":"Caja"}');
 update public.profiles set payment_transfer=true,payment_cash=true,accepting_orders=true,open_time=null,close_time=null where id=owner_id;
 insert into public.products(restaurant_id,name,price,is_available) values(owner_id,'Comida',50,true) returning id into product_id;
 insert into public.restaurant_staff(restaurant_id,user_id,staff_role,is_active,can_close_accounts) values(owner_id,cashier_id,'cashier',true,true);
 payload:=jsonb_build_object('restaurant_id',owner_id,'service_type','pickup','payment_method','transfer','pickup_name',' Ana ','items',jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)));
 perform set_config('request.jwt.claim.sub',customer_id::text,true);
 execute 'set local role authenticated';
 o:=public.create_customer_order_once(request_id,payload);
 assert o->>'pickup_name'='Ana','Customer pickup name missing';
 assert o->>'payment_status'='pending' and (o->>'payment_before_kitchen')::boolean;
 again:=public.create_customer_order_once(request_id,payload);
 assert again->>'id'=o->>'id','Retry created another order';
 blocked:=false;
 begin perform public.create_customer_order_once(gen_random_uuid(),payload||'{"pickup_name":" "}'::jsonb);exception when raise_exception then blocked:=true;end;
 assert blocked,'Blank name accepted';
 perform set_config('request.jwt.claim.sub',cashier_id::text,true);
 assert (select count(*)=1 from public.orders where id=(o->>'id')::bigint),'Cashier cannot see transfer order';
 assert (select count(*)=0 from public.kitchen_tickets where order_id=(o->>'id')::bigint),'Unpaid transfer entered kitchen';
 perform public.open_cash_shift(owner_id,0);
 blocked:=false;
 begin perform public.register_pos_payment_v2((o->>'id')::bigint,'cash',50,0,50);exception when raise_exception then blocked:=true;end;
 assert blocked,'Changed online transfer into cash';
 perform public.register_pos_payment_v2((o->>'id')::bigint,'transfer',50,0,null);
 assert (select count(*)=1 from public.kitchen_tickets where order_id=(o->>'id')::bigint),'Confirmed transfer has no kitchen ticket';
 perform set_config('request.jwt.claim.sub',customer_id::text,true);
 again:=public.create_customer_order_once(gen_random_uuid(),payload-'pickup_name');
 assert again->>'pickup_name'='Nombre del perfil','Cached clients lost profile-name fallback';
 execute 'reset role';
end;$$;
