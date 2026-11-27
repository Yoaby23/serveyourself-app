do $$
declare
 owner_id uuid:=gen_random_uuid();
 item_id uuid;
 table_id bigint;
 sale bigint;
 salon_old bigint;
 salon_new bigint;
 pickup_due bigint;
 pickup_close bigint;
 original_deadline timestamptz;
 q jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,owner_id||'@example.invalid','{"role":"negocio","business_name":"QA salón"}');
 update public.profiles set accepting_orders=true,open_time=null,close_time=null,
  dine_in_prep_minutes=20,pickup_prep_minutes=20 where id=owner_id;
 insert into public.products(restaurant_id,name,price) values(owner_id,'Plato',10) returning id into item_id;
 insert into public.restaurant_tables(restaurant_id,name) values(owner_id,'Mesa QA') returning id into table_id;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 perform public.open_cash_shift(owner_id,0);
 sale:=(public.create_pos_table_order(owner_id,jsonb_build_array(jsonb_build_object('id',item_id,'qty',1)),null,'dine_in',table_id,'cash',null,null)->>'id')::bigint;
 select id,dine_in_due_at into salon_old,original_deadline from public.kitchen_tickets where order_id=sale;
 assert original_deadline=now()+interval '20 minutes','Initial deadline was not captured';
 execute 'reset role';
 update public.profiles set dine_in_prep_minutes=35 where id=owner_id;
 insert into public.restaurant_tables(restaurant_id,name) values(owner_id,'Mesa QA 2') returning id into table_id;
 execute 'set local role authenticated';
 sale:=(public.create_pos_table_order(owner_id,jsonb_build_array(jsonb_build_object('id',item_id,'qty',1)),null,'dine_in',table_id,'cash',null,null)->>'id')::bigint;
 select id into salon_new from public.kitchen_tickets where order_id=sale;
 for i in 1..2 loop
  sale:=(public.create_pos_table_order(owner_id,jsonb_build_array(jsonb_build_object('id',item_id,'qty',1)),null,'pickup',null,'cash',null,'QA retiro')->>'id')::bigint;
  perform public.register_pos_payment_v2(sale,'cash',10,0,10);
  if i=1 then select id into pickup_due from public.kitchen_tickets where order_id=sale;
  else select id into pickup_close from public.kitchen_tickets where order_id=sale;end if;
 end loop;
 execute 'reset role';
 update public.kitchen_tickets set created_at=now()-interval '30 minutes' where id=pickup_due;
 execute 'set local role authenticated';
 q:=public.list_kitchen_priority_queue(owner_id);
 assert (q->0->>'id')::bigint=pickup_due,'Salon must not block a much more urgent pickup';
 assert (q->1->>'id')::bigint=salon_old and (q->2->>'id')::bigint=salon_new,'Salon boost must preserve FIFO';
 assert (q->3->>'id')::bigint=pickup_close,'Salon must win a close comparison';
 assert (q->1->>'target_ready_at')::timestamptz=original_deadline,'Settings change moved the original deadline';
 assert (q->2->>'target_ready_at')::timestamptz=now()+interval '35 minutes','New ticket did not capture the new setting';
 execute 'reset role';
end;
$$;
