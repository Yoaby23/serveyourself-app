-- Run inside a transaction and ROLLBACK after the checks.
do $$
declare owner_id uuid:=gen_random_uuid();first_waiter uuid:=gen_random_uuid();second_waiter uuid:=gen_random_uuid();customer_id uuid:=gen_random_uuid();stranger_id uuid:=gen_random_uuid();
 product_id uuid;table_id bigint;first_order jsonb;second_order jsonb;new_order jsonb;items jsonb;blocked boolean;summary_count integer;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-'||owner_id||'@example.invalid','{"role":"negocio","business_name":"QA table restaurant","full_name":"Owner"}'),
 (first_waiter,'qa-'||first_waiter||'@example.invalid','{"full_name":"Waiter One"}'),
 (second_waiter,'qa-'||second_waiter||'@example.invalid','{"full_name":"Waiter Two"}'),
 (customer_id,'qa-'||customer_id||'@example.invalid','{"full_name":"QA Customer"}'),
 (stranger_id,'qa-'||stranger_id||'@example.invalid','{"full_name":"QA Stranger"}');
 insert into public.products(restaurant_id,name,price,is_available) values(owner_id,'QA meal',100,true) returning id into product_id;
 insert into public.restaurant_tables(restaurant_id,name) values(owner_id,'QA table') returning id into table_id;
 insert into public.restaurant_staff(restaurant_id,user_id,staff_role,is_active,can_create_orders,can_view_kitchen,can_close_accounts)
 values(owner_id,first_waiter,'waiter',true,true,false,false),(owner_id,second_waiter,'waiter',true,true,false,false);
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 perform public.open_cash_shift(owner_id,0);
 items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',1));
 execute 'set local role authenticated';
 perform set_config('request.jwt.claim.sub',first_waiter::text,true);
 first_order:=public.create_pos_table_order(owner_id,items,'First round','dine_in',table_id,'cash',null,'QA Cliente');
 perform set_config('request.jwt.claim.sub',second_waiter::text,true);
 second_order:=public.create_pos_table_order(owner_id,items,'Second round','dine_in',table_id,'cash',null,'QA Cliente');
 assert first_order->>'id'=second_order->>'id','second waiter created another account';
 assert (second_order->>'total')::numeric=200,'round totals not accumulated';
 execute 'reset role'; -- Inspect fixtures as administrator; waiters cannot read all kitchen tickets.
 assert (select count(*)=2 from public.kitchen_tickets where order_id=(first_order->>'id')::bigint),'rounds must have separate kitchen tickets';
 execute 'set local role authenticated';
 select count(*) into summary_count from public.list_pos_table_accounts(owner_id);
 assert summary_count=1,'second waiter cannot see shared table account summary';
 blocked:=false;
 perform set_config('request.jwt.claim.sub',stranger_id::text,true);
 begin perform public.list_pos_table_accounts(owner_id);exception when others then blocked:=true;end;
 assert blocked,'stranger can inspect table accounts';
 perform set_config('request.jwt.claim.sub',customer_id::text,true);
 perform public.set_restaurant_favorite(owner_id,true);
 perform public.set_restaurant_favorite(owner_id,true);
 assert (select count(*)=1 from public.restaurant_favorites),'duplicate favorites';
 blocked:=false;
 begin perform public.set_restaurant_favorite(stranger_id,true);exception when others then blocked:=true;end;
 assert blocked,'non-restaurant favorite accepted';
 blocked:=false;
 begin insert into public.restaurant_favorites(user_id,restaurant_id) values(stranger_id,owner_id);exception when others then blocked:=true;end;
 assert blocked,'user can write another users favorite';
 perform set_config('request.jwt.claim.sub',stranger_id::text,true);
 assert (select count(*)=0 from public.restaurant_favorites),'other users favorites leaked';
 perform public.set_restaurant_favorite(owner_id,false);
 perform set_config('request.jwt.claim.sub',customer_id::text,true);
 assert (select count(*)=1 from public.restaurant_favorites),'another user deleted favorite';
 perform public.set_restaurant_favorite(owner_id,false);
 assert (select count(*)=0 from public.restaurant_favorites),'favorite not removed';
 execute 'reset role';
 -- A closed account must not receive more items; a newly occupied table gets a new account.
 update public.orders set payment_status='approved' where id=(first_order->>'id')::bigint;
 perform set_config('request.jwt.claim.sub',first_waiter::text,true);
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,'Stale round','dine_in',table_id,'cash',(first_order->>'id')::bigint,'QA Cliente');exception when others then blocked:=true;end;
 assert blocked,'closed account accepted another round';
 new_order:=public.create_pos_table_order(owner_id,items,'New sitting','dine_in',table_id,'cash',null,'QA Cliente');
 assert new_order->>'id'<>first_order->>'id','new sitting reused paid account';
 -- Revoking staff access must hide even previously created kitchen rounds.
 execute 'reset role';
 update public.restaurant_staff set is_active=false where user_id=first_waiter;
 execute 'set local role authenticated';
 perform set_config('request.jwt.claim.sub',first_waiter::text,true);
 assert (select count(*)=0 from public.kitchen_tickets where restaurant_id=owner_id),'Inactive waiter retained kitchen access';
 assert (select count(*)=0 from public.kitchen_ticket_station_statuses where restaurant_id=owner_id),'Inactive waiter retained station access';
 execute 'reset role';
 raise notice 'Favorites and single table account database checks passed';
end;$$;
