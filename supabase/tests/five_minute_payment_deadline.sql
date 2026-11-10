do $$
declare owner_id uuid:=gen_random_uuid();product_id uuid;paid jsonb;unpaid jsonb;blocked boolean:=false; deadline timestamptz;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(owner_id,owner_id||'@example.invalid','{"role":"negocio","business_name":"Deadline QA"}');
 insert into public.products(restaurant_id,name,price) values(owner_id,'QA',30) returning id into product_id;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 perform public.open_cash_shift(owner_id,0);
 paid:=public.cashier_create_takeaway(gen_random_uuid(),owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)),'Paid QA',null,'cash',30);
 unpaid:=public.cashier_create_takeaway(gen_random_uuid(),owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)),'Pending QA',null,'credit',null);
 deadline:=(unpaid->>'payment_expires_at')::timestamptz;
 assert deadline>(unpaid->>'created_at')::timestamptz+interval '299 seconds' and deadline<=(unpaid->>'created_at')::timestamptz+interval '5 minutes','Wrong deadline';
 execute 'reset role';
 update public.orders set payment_expires_at=clock_timestamp()-interval '1 second' where id in ((paid->>'id')::bigint,(unpaid->>'id')::bigint);
 execute 'set local role authenticated';
 begin
  perform public.register_pos_payment_v2((unpaid->>'id')::bigint,'cash',30,0,30);
 exception when raise_exception then blocked:=true;end;
 assert blocked,'Late payment accepted before cron cancellation';
 execute 'reset role';
 perform public.cancel_expired_unpaid_orders();
 assert exists(select from public.orders where id=(unpaid->>'id')::bigint and status='cancelado' and payment_status='expired'),'Unpaid order not cancelled';
 assert exists(select from public.orders where id=(paid->>'id')::bigint and status<>'cancelado' and payment_status='approved'),'Paid order cancelled';
 assert not exists(select from public.order_payments where order_id=(unpaid->>'id')::bigint),'Payment inserted after deadline';
end;$$;
