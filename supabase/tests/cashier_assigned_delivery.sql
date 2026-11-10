do $$
declare owner_id uuid:=gen_random_uuid();other_id uuid:=gen_random_uuid();cashier uuid:=gen_random_uuid();driver uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();product uuid;first_id bigint;second_id bigint;ticket bigint;blocked boolean;first_assignment uuid;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,owner_id||'@example.invalid','{"role":"negocio","business_name":"Dispatch QA"}'),
 (other_id,other_id||'@example.invalid','{"role":"negocio","business_name":"Other"}'),
 (cashier,cashier||'@example.invalid','{"full_name":"Cash QA"}'),
 (driver,driver||'@example.invalid','{"full_name":"Driver QA"}'),
 (outsider,outsider||'@example.invalid','{"full_name":"Other Driver"}');
 insert into public.restaurant_staff(restaurant_id,user_id,staff_role,is_active,can_close_accounts,can_deliver_orders) values(owner_id,cashier,'cashier',true,true,false),(owner_id,driver,'driver',true,false,true),(other_id,outsider,'driver',true,false,true);
 insert into public.delivery_drivers(user_id,full_name,phone,vehicle_type,status,is_available) values(driver,'Driver QA','1234567890','walking','active',true),(outsider,'Other Driver','1234567890','walking','active',true);
 insert into public.products(restaurant_id,name,price) values(owner_id,'QA',30) returning id into product;
 insert into public.orders(restaurant_id,items,total,service_type,delivery_status,payment_method) values(owner_id,jsonb_build_array(jsonb_build_object('id',product,'nombre','QA','qty',1,'price',30)),30,'delivery','pending_acceptance','cash') returning id into first_id;
 insert into public.orders(restaurant_id,items,total,service_type,delivery_status,payment_method) values(owner_id,jsonb_build_array(jsonb_build_object('id',product,'nombre','QA','qty',1,'price',30)),30,'delivery','pending_acceptance','cash') returning id into second_id;
 perform set_config('request.jwt.claim.sub',driver::text,true);execute 'set local role authenticated';
 assert not exists(select from public.list_delivery_offers()),'Driver sees self-service offers';
 blocked:=false;begin perform public.claim_delivery_order(first_id);exception when raise_exception then blocked:=true;end;assert blocked,'Driver accepted own order';
 blocked:=false;begin perform public.assign_delivery_driver(first_id,driver);exception when raise_exception then blocked:=true;end;assert blocked,'Driver assigned own order';
 perform set_config('request.jwt.claim.sub',cashier::text,true);
 assert exists(select from public.list_delivery_drivers(owner_id) where user_id=driver and is_available),'Cash cannot see its active driver';
 assert not exists(select from public.list_delivery_drivers(owner_id) where user_id=outsider),'Foreign driver visible';
 perform public.accept_delivery_order(first_id,true);perform public.accept_delivery_order(second_id,true);
 blocked:=false;begin perform public.assign_delivery_driver(first_id,outsider);exception when raise_exception then blocked:=true;end;assert blocked,'Foreign driver assigned';
 first_assignment:=(public.assign_delivery_driver(first_id,driver)->>'delivery_assignment_id')::uuid;
 assert (public.assign_delivery_driver(first_id,driver)->>'delivery_assignment_id')::uuid=first_assignment,'Repeated assignment changed identity';
 blocked:=false;begin perform public.assign_delivery_driver(second_id,driver);exception when raise_exception then blocked:=true;end;assert blocked,'Busy driver assigned twice';
 perform set_config('request.jwt.claim.sub',driver::text,true);
 blocked:=false;begin perform public.release_delivery_order(first_id,'Cannot take it');exception when raise_exception then blocked:=true;end;assert blocked,'Driver rejected assigned order';
 perform set_config('request.jwt.claim.sub',cashier::text,true);
 blocked:=false;begin perform public.release_delivery_order(first_id,'Change driver',outsider);exception when raise_exception then blocked:=true;end;assert blocked,'Stale assignment released';
 perform public.release_delivery_order(first_id,'Change driver',driver);
 assert (public.assign_delivery_driver(first_id,driver)->>'delivery_assignment_id')::uuid<>first_assignment,'Reassignment did not create a new notice identity';
 execute 'reset role';
 assert (select count(*)=2 from public.order_notification_events where order_id=first_id and kind='driver'),'Driver assignment notifications missing or duplicated';
 select id into ticket from public.kitchen_tickets where order_id=first_id;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);execute 'set local role authenticated';
 perform public.update_kitchen_ticket_status(ticket,'preparando');perform public.update_kitchen_ticket_status(ticket,'listo');
 perform set_config('request.jwt.claim.sub',driver::text,true);
 assert public.advance_delivery_order(first_id,'picked_up',null,null)->>'delivery_status'='picked_up','Assigned driver cannot collect order';
 execute 'reset role';
end;$$;
