-- Execute in a transaction and ROLLBACK. Never creates durable accounts or orders.
do $$
declare
 owner_id uuid:=gen_random_uuid();customer_id uuid:=gen_random_uuid();other_id uuid:=gen_random_uuid();
 product_id uuid;v_request_id uuid:=gen_random_uuid();payload jsonb;first_order jsonb;second_order jsonb;order_id bigint;outcome jsonb;
 t timestamptz:=now();blocked boolean:=false;bounds jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-'||owner_id||'@example.invalid','{"role":"negocio","business_name":"QA restaurant","full_name":"QA Owner"}'),
 (customer_id,'qa-'||customer_id||'@example.invalid','{"full_name":"QA Customer"}'),
 (other_id,'qa-'||other_id||'@example.invalid','{"full_name":"QA Other"}');
 perform set_config('request.jwt.claim.sub',customer_id::text,true);
 perform public.complete_business_registration('{"full_name":"QA Customer","business_name":"QA Business","address":"QA local","phone":"0000000000"}');
 assert (select role='negocio' and business_name='QA Business' from public.profiles where id=customer_id),'business onboarding failed';
 assert (select role='cliente' from public.profiles where id=other_id),'onboarding changed another account';
 assert not has_column_privilege('authenticated','public.profiles','role','UPDATE'),'general role UPDATE must stay revoked';
 assert not has_function_privilege('anon','public.complete_business_registration(jsonb)','EXECUTE'),'anonymous onboarding allowed';
 assert not has_function_privilege('authenticated','public.reconcile_order_payment(bigint,jsonb)','EXECUTE'),'client payment writes allowed';
 assert not has_function_privilege('anon','public.handle_new_user()','EXECUTE'),'anonymous trigger execution allowed';
 insert into public.products(restaurant_id,name,price,is_available) values(owner_id,'QA product',100,true) returning id into product_id;
 payload:=jsonb_build_object('restaurant_id',owner_id,'items',jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)),'notes','QA rollback','payment_method','cash','service_type','pickup');
 first_order:=public.create_customer_order_once(v_request_id,payload);
 second_order:=public.create_customer_order_once(v_request_id,payload);
 assert first_order->>'id'=second_order->>'id','retry created a duplicate';
 assert (select count(*)=1 from public.customer_order_requests where customer_order_requests.request_id=v_request_id),'request not deduplicated';
 begin
  perform public.create_customer_order_once(v_request_id,payload||'{"notes":"changed"}'::jsonb);
 exception when others then blocked:=true;end;
 assert blocked,'same key accepted a different payload';
 order_id:=(first_order->>'id')::bigint;
 update public.orders set payment_method='mercado_pago',payment_status='pending' where id=order_id;
 outcome:=public.reconcile_order_payment(order_id,jsonb_build_object('id','qa-payment','external_reference',order_id::text,'currency_id','MXN','transaction_amount',100,'status','approved','date_created',t,'date_last_updated',t));
 assert outcome->>'payment_status'='approved','payment not approved';
 perform public.reconcile_order_payment(order_id,jsonb_build_object('id','qa-payment','external_reference',order_id::text,'currency_id','MXN','transaction_amount',100,'status','pending','date_created',t,'date_last_updated',t+interval '1 second'));
 assert (select payment_status='approved' from public.orders where id=order_id),'payment regressed to pending';
 perform public.reconcile_order_payment(order_id,jsonb_build_object('id','qa-other','external_reference',order_id::text,'currency_id','MXN','transaction_amount',100,'status','rejected','date_created',t,'date_last_updated',t+interval '2 seconds'));
 assert (select payment_status='approved' and mercado_pago_payment_id='qa-payment' from public.orders where id=order_id),'other payment overwrote approved payment';
 perform public.begin_order_refund(order_id,'qa-payment','QA rollback',customer_id);
 blocked:=false;
 begin update public.orders set status='preparando' where id=order_id;exception when others then blocked:=true;end;
 assert blocked,'preparation allowed during refund';
 perform public.finish_order_refund(order_id,'qa-refund');
 perform public.finish_order_refund(order_id,'qa-refund');
 assert (select payment_status='refunded' from public.orders where id=order_id),'refund did not complete';
 perform public.reconcile_order_payment(order_id,jsonb_build_object('id','qa-payment','external_reference',order_id::text,'currency_id','MXN','transaction_amount',100,'status','approved','date_created',t,'date_last_updated',t+interval '3 seconds'));
 assert (select payment_status='refunded' from public.orders where id=order_id),'refund overwritten by delayed approval';
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 update public.profiles set timezone='America/Mexico_City' where id=owner_id;
 bounds:=public.get_report_bounds(owner_id,'2026-10-26','2026-10-26');
 assert (bounds->>'from')::timestamptz='2026-10-26T06:00:00Z'::timestamptz,'wrong report timezone';
 assert (bounds->>'to')::timestamptz='2026-10-27T06:00:00Z'::timestamptz,'report upper bound not exclusive';
 perform set_config('request.jwt.claim.sub',other_id::text,true);
 blocked:=false;
 begin perform public.get_report_bounds(owner_id,'2026-10-26','2026-10-26');exception when others then blocked:=true;end;
 assert blocked,'another user accessed report bounds';
 raise notice 'QA reliability database checks passed';
end;$$;
