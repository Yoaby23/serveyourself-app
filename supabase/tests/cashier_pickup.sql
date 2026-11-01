-- Run inside BEGIN / ROLLBACK.
do $$
declare owner_id uuid:=gen_random_uuid();cashier_id uuid:=gen_random_uuid();stranger_id uuid:=gen_random_uuid();
 product_id uuid;items jsonb;result jsonb;ticket_id bigint;blocked boolean;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-'||owner_id||'@example.invalid','{"role":"negocio","business_name":"Cashier pickup QA"}'),
 (cashier_id,'qa-'||cashier_id||'@example.invalid','{"full_name":"Cashier"}'),
 (stranger_id,'qa-'||stranger_id||'@example.invalid','{"full_name":"Other"}');
 insert into public.products(restaurant_id,name,price,is_available) values(owner_id,'Meal',25,true) returning id into product_id;
 insert into public.restaurant_staff(restaurant_id,user_id,staff_role,is_active,can_create_orders,can_close_accounts)
 values(owner_id,cashier_id,'cashier',true,false,true);
 items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',2));
 execute 'set local role authenticated';
 perform set_config('request.jwt.claim.sub',cashier_id::text,true);
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'Ana');exception when raise_exception then blocked:=true;end;
 assert blocked,'Closed cash shift accepted a new pickup';
 perform public.open_cash_shift(owner_id,0);
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,' ');exception when raise_exception then blocked:=true;end;
 assert blocked,'Empty pickup name accepted';
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,null,'dine_in',null,'cash',null,null);exception when raise_exception then blocked:=true;end;
 assert blocked,'Cashier gained salon permission';
 result:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,' Ana ');
 assert result->>'pickup_name'='Ana' and (result->>'total')::numeric=50;
 assert (result->>'created_by')::uuid=cashier_id and result->>'service_type'='pickup';
 ticket_id:=(result->>'kitchen_ticket_id')::bigint;
 assert ticket_id is not null,'Pickup has no kitchen ticket';
 assert (select count(*)=1 from public.orders where id=(result->>'id')::bigint),'Cashier cannot read pickup';
 perform public.register_pos_payment_v2((result->>'id')::bigint,'cash',50,0,100);
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 perform public.update_kitchen_ticket_status(ticket_id,'preparando');
 perform public.update_kitchen_ticket_status(ticket_id,'listo');
 perform set_config('request.jwt.claim.sub',cashier_id::text,true);
 result:=public.mark_kitchen_ticket_delivered(ticket_id);
 assert result->>'status'='entregado';
 blocked:=false;
 begin perform public.mark_kitchen_ticket_delivered(ticket_id);exception when raise_exception then blocked:=true;end;
 assert blocked,'Duplicate delivery accepted';
 perform set_config('request.jwt.claim.sub',stranger_id::text,true);
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'Ana');exception when raise_exception then blocked:=true;end;
 assert blocked,'Stranger created pickup';
 execute 'reset role';
 update public.restaurant_staff set is_active=false where restaurant_id=owner_id and user_id=cashier_id;
 execute 'set local role authenticated';
 perform set_config('request.jwt.claim.sub',cashier_id::text,true);
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'Ana');exception when raise_exception then blocked:=true;end;
 assert blocked,'Inactive cashier created pickup';
 execute 'reset role';
end;$$;
