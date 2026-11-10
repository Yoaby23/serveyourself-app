do $$
declare owner_id uuid:=gen_random_uuid(); product_id uuid; request_id uuid:=gen_random_uuid(); result jsonb; retry jsonb; blocked boolean:=false; customer_id uuid; scheduled jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(owner_id,owner_id||'@example.invalid','{"role":"negocio","business_name":"Checkout QA"}');
 insert into public.products(restaurant_id,name,price) values(owner_id,'QA',50) returning id into product_id;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 perform public.open_cash_shift(owner_id,0);
 begin
  perform public.cashier_create_takeaway(request_id,owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)),'QA',null,'cash',20);
 exception when raise_exception then blocked:=true;end;
 assert blocked,'Accepted insufficient cash';
 result:=public.cashier_create_takeaway(request_id,owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)),'QA',null,'cash',100);
 assert result->>'payment_status'='approved','Not paid';
 assert (result->>'cash_change')::numeric=50,'Wrong change';
 retry:=public.cashier_create_takeaway(request_id,owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)),'QA',null,'cash',100);
 assert result->>'id'=retry->>'id','Duplicate retry';
 scheduled:=public.create_scheduled_pickup_order(owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)),null,'cash',now()+interval '1 hour');
 assert not (scheduled->>'payment_before_kitchen')::boolean,'Scheduled pickup still gated';
 execute 'reset role';
 assert (select count(*)=1 from public.order_payments where order_id=(result->>'id')::bigint),'Duplicate payment';
 assert exists(select from public.kitchen_tickets where order_id=(result->>'id')::bigint),'Paid takeaway absent from kitchen';
 assert exists(select from public.kitchen_tickets where order_id=(scheduled->>'id')::bigint and status<>'cancelado'),'Scheduled pickup absent from kitchen';
 insert into public.loyalty_customers(restaurant_id,customer_name,phone,credit_enabled,credit_limit) values(owner_id,'QA','1234567890',true,100) returning id into customer_id;
 execute 'set local role authenticated';
 result:=public.cashier_create_takeaway(gen_random_uuid(),owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',1)),'Credit QA',null,'credit',null);
 result:=public.charge_order_to_customer_credit((result->>'id')::bigint,customer_id,null,null);
 assert result->>'payment_status'='on_credit','Credit failed';
 execute 'reset role';
 assert exists(select from public.kitchen_tickets where order_id=(result->>'id')::bigint),'Credit takeaway absent from kitchen';
end;$$;
