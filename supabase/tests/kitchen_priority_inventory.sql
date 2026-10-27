-- Run inside a transaction and ROLLBACK after these assertions. Fixtures never survive.
do $$
declare owner_id uuid:=gen_random_uuid();other_id uuid:=gen_random_uuid();v_product uuid;v_other_product uuid;v_ingredient uuid;v_foreign uuid;
 v_order jsonb;t1 bigint;t2 bigint;told bigint;turgent bigint;model_ticket bigint;ids bigint[]:='{}';i integer;qty integer;items jsonb;v_work numeric;blocked boolean;queue jsonb;old_pos bigint;urgent_pos bigint;v_prediction numeric;v_status text;
 online_order_id bigint;online_ticket bigint;station1 bigint;station2 bigint;station_ticket bigint;v_count integer;stock_before numeric;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-kitchen-fix-'||owner_id||'@example.invalid','{"role":"negocio","business_name":"Kitchen Fix QA","full_name":"QA Owner"}'),
 (other_id,'qa-kitchen-fix-'||other_id||'@example.invalid','{"role":"negocio","business_name":"Other Kitchen QA","full_name":"QA Other"}');
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 update public.profiles set timezone='UTC',open_time=null,close_time=null,pickup_prep_minutes=20 where id=owner_id;
 perform public.open_cash_shift(owner_id,0);
 insert into public.products(restaurant_id,name,price,is_available) values(owner_id,'QA Main',100,true) returning id into v_product;
 insert into public.ingredients(restaurant_id,name,unit,stock) values(owner_id,'QA Ingredient','kg',10) returning id into v_ingredient;
 insert into public.product_recipes(product_id,ingredient_id,quantity) values(v_product,v_ingredient,3);
 items:=jsonb_build_array(jsonb_build_object('id',v_product,'qty',2));
 v_order:=public.create_pos_table_order(owner_id,items,'First','pickup',null,'cash',null);t1:=(v_order->>'kitchen_ticket_id')::bigint;
 assert public.predict_kitchen_minutes(t1)=20,'configured fallback not used';
 perform public.adjust_inventory(v_ingredient,-5,'waste','QA shortage');
 blocked:=false;begin perform public.update_kitchen_ticket_status(t1,'preparando');exception when others then blocked:=true;end;
 assert blocked,'preparation accepted a shortage';
 assert (select stock=5 from public.ingredients where id=v_ingredient),'shortage changed stock';
 assert (select status='pendiente' and not inventory_deducted from public.kitchen_tickets where id=t1),'failed start changed ticket';
 assert not exists(select 1 from public.inventory_movements where kitchen_ticket_id=t1),'failed start generated sale';
 queue:=public.list_kitchen_priority_queue(owner_id);
 assert exists(select 1 from jsonb_array_elements(queue) x where (x->>'id')::bigint=t1 and (x->>'has_shortage')::boolean and not (x->>'can_start')::boolean),'shortage not visible in queue';
 perform public.adjust_inventory(v_ingredient,1,'purchase','QA replenish');
 perform public.update_kitchen_ticket_status(t1,'preparando');
 assert (select stock=0 from public.ingredients where id=v_ingredient),'recipe amount not deducted';
 assert (select not inventory_available and is_available from public.products where id=v_product),'stock/manual availability conflated';
 update public.kitchen_tickets set started_at=now()-interval '10 minutes' where id=t1;
 perform public.update_kitchen_ticket_status(t1,'listo');
 assert (select stock=0 from public.ingredients where id=v_ingredient),'completion deducted twice';
 assert (select count(*)=1 from public.inventory_movements where kitchen_ticket_id=t1 and movement_type='sale'),'sale not deduplicated';
 assert (select count(*)=1 from public.kitchen_prep_samples where ticket_id=t1),'completion did not teach model';
 -- Splitting a financial account after cooking must not consume stock or demand it again.
 perform public.split_pos_order((select order_id from public.kitchen_tickets where id=t1),jsonb_build_array(jsonb_build_object('id',v_product,'qty',1)));
 assert (select stock=0 from public.ingredients where id=v_ingredient),'financial split consumed stock';
 blocked:=false;begin perform public.create_pos_table_order(owner_id,items,'No stock','pickup',null,'cash',null);exception when others then blocked:=true;end;
 assert blocked,'new order accepted missing ingredients';
 perform public.adjust_inventory(v_ingredient,12,'purchase','QA replenish');
 assert (select inventory_available from public.products where id=v_product),'availability not restored';
 blocked:=false;begin perform public.adjust_inventory(v_ingredient,-100,'waste','QA excessive');exception when others then blocked:=true;end;
 assert blocked and (select stock=12 from public.ingredients where id=v_ingredient),'excess adjustment clipped stock';
 assert not exists(select 1 from public.inventory_movements where restaurant_id=owner_id and reason='QA excessive'),'rejected adjustment created movement';
 blocked:=false;begin perform public.adjust_inventory(v_ingredient,-1,'purchase','QA bad direction');exception when others then blocked:=true;end;assert blocked,'negative purchase accepted';
 blocked:=false;begin update public.ingredients set unit='g' where id=v_ingredient;exception when others then blocked:=true;end;assert blocked,'unit changed without converting existing recipes and ledger';
 blocked:=false;begin perform public.adjust_inventory(v_ingredient,0.0001,'purchase','QA invalid precision');exception when others then blocked:=true;end;assert blocked,'adjustment rounded to a zero ledger movement';
 -- Two queued requests can contend for stock; only the one that can still consume may start.
 v_order:=public.create_pos_table_order(owner_id,items,'Second','pickup',null,'cash',null);t2:=(v_order->>'kitchen_ticket_id')::bigint;
 perform public.update_kitchen_ticket_status(t2,'preparando');
 assert (select stock=6 from public.ingredients where id=v_ingredient),'second round deduction wrong';
 -- Priority overrides must not be overtaken by accumulated waiting time.
 items:=jsonb_build_array(jsonb_build_object('id',v_product,'qty',1));
 v_order:=public.create_pos_table_order(owner_id,items,'Old normal','pickup',null,'cash',null);told:=(v_order->>'kitchen_ticket_id')::bigint;
 v_order:=public.create_pos_table_order(owner_id,items,'New urgent','pickup',null,'cash',null);turgent:=(v_order->>'kitchen_ticket_id')::bigint;
 update public.kitchen_tickets set created_at=now()-interval '4 hours' where id=told;
 perform public.set_kitchen_ticket_priority(turgent,2,'Urgent QA');
 queue:=public.list_kitchen_priority_queue(owner_id);
 select ordinality into old_pos from jsonb_array_elements(queue) with ordinality q(value,ordinality) where (value->>'id')::bigint=told;
 select ordinality into urgent_pos from jsonb_array_elements(queue) with ordinality q(value,ordinality) where (value->>'id')::bigint=turgent;
 assert urgent_pos<old_pos,'age outranked manual urgent';
 perform public.set_kitchen_ticket_priority(turgent,-1,'Postponed QA');queue:=public.list_kitchen_priority_queue(owner_id);
 select ordinality into old_pos from jsonb_array_elements(queue) with ordinality q(value,ordinality) where (value->>'id')::bigint=told;
 select ordinality into urgent_pos from jsonb_array_elements(queue) with ordinality q(value,ordinality) where (value->>'id')::bigint=turgent;
 assert old_pos<urgent_pos,'postponement ignored';
 -- Cross-restaurant recipes and direct unaudited stock edits must be denied for clients.
 insert into public.ingredients(restaurant_id,name,unit,stock) values(other_id,'QA Foreign','kg',10) returning id into v_foreign;
 execute 'set local role authenticated';
 blocked:=false;begin insert into public.product_recipes(product_id,ingredient_id,quantity) values(v_product,v_foreign,1);exception when others then blocked:=true;end;assert blocked,'cross-restaurant recipe accepted';
 blocked:=false;begin update public.ingredients set stock=100 where id=v_ingredient;exception when others then blocked:=true;end;assert blocked,'client bypassed stock ledger';
 assert not has_function_privilege('authenticated','public.kitchen_resource_status(uuid,jsonb)','execute'),'private inventory helper exposed';
 execute 'reset role';
 -- Known unbiased dataset: duration = 10 + 2*work + 10*peak, 20% held out.
 delete from public.kitchen_prep_samples where restaurant_id=owner_id;
 perform public.adjust_inventory(v_ingredient,100,'purchase','QA model stock');
 for i in 1..12 loop
  qty:=((i-1)%3)+1;
  v_order:=public.create_pos_table_order(owner_id,jsonb_build_array(jsonb_build_object('id',v_product,'qty',qty)),'Model QA','pickup',null,'cash',null);
  model_ticket:=(v_order->>'kitchen_ticket_id')::bigint;ids:=array_append(ids,model_ticket);
  update public.kitchen_tickets set started_at='2026-10-26T11:00:00Z' where id=model_ticket;
  v_work:=public.kitchen_work_units(jsonb_build_array(jsonb_build_object('id',v_product,'qty',qty)));
  insert into public.kitchen_prep_samples(ticket_id,restaurant_id,service_type,work_units,is_peak,prep_minutes,created_at) values(model_ticket,owner_id,'pickup',v_work,i>6,10+2*v_work+case when i>6 then 10 else 0 end,now()+make_interval(secs=>i));
 end loop;
 perform public.retrain_kitchen_model(owner_id,'pickup');
 assert abs(public.predict_kitchen_minutes(ids[1])-12.7)<.01,'peak effect counted twice';
 update public.kitchen_tickets set started_at='2026-10-26T14:00:00Z' where id=ids[1];
 assert abs(public.predict_kitchen_minutes(ids[1])-22.7)<.01,'peak effect missing';
 assert (select model_ready and validation_sample_count>=2 and training_sample_count<sample_count and mean_absolute_error<.01 from public.kitchen_ml_models where restaurant_id=owner_id and service_type='pickup'),'validation not independent or model not ready';
 assert public.kitchen_work_units(jsonb_build_array(jsonb_build_object('id',v_product,'qty',2)))=public.kitchen_work_units(jsonb_build_array(jsonb_build_object('id',v_product,'qty',1),jsonb_build_object('id',v_product,'qty',1))),'duplicate lines changed predicted workload';
 -- Product/workload coverage must reject unsupported extrapolation.
 insert into public.products(restaurant_id,name,price,is_available) values(owner_id,'QA Unknown Meal',100,true) returning id into v_other_product;
 update public.kitchen_tickets set items=jsonb_build_array(jsonb_build_object('id',v_other_product,'qty',1)) where id=ids[1];
 assert public.predict_kitchen_minutes(ids[1])=20,'unknown product used unrelated model';
 update public.kitchen_tickets set items=jsonb_build_array(jsonb_build_object('id',v_product,'qty',20)) where id=ids[1];
 assert public.predict_kitchen_minutes(ids[1])=20,'unsupported quantity extrapolated';
 update public.kitchen_tickets set items=jsonb_build_array(jsonb_build_object('id',v_product,'qty',1)) where id=ids[1];
 -- An unknown peak category must fall back instead of extrapolating falsely.
 update public.kitchen_prep_samples set is_peak=false,prep_minutes=10+2*work_units where restaurant_id=owner_id;
 perform public.retrain_kitchen_model(owner_id,'pickup');
 assert public.predict_kitchen_minutes(ids[1])=20,'unknown peak hour did not fall back';
 -- Excessive validation error must also fall back.
 update public.kitchen_prep_samples set prep_minutes=case when (ticket_id=any(ids[1:6])) then 10 else 200 end where restaurant_id=owner_id;
 perform public.retrain_kitchen_model(owner_id,'pickup');
 assert (select not model_ready from public.kitchen_ml_models where restaurant_id=owner_id and service_type='pickup'),'unreliable model accepted';
 assert public.predict_kitchen_minutes(ids[1])=20,'unreliable model used';
 -- Stock changes during checkout must not roll back an approved payment.
 v_order:=public.create_order_v2(owner_id,jsonb_build_array(jsonb_build_object('id',v_product,'qty',1)),'Paid order QA','cash');
 online_order_id:=(v_order->>'id')::bigint;
 update public.orders set payment_method='mercado_pago',payment_status='pending' where id=online_order_id;
 delete from public.kitchen_tickets where order_id=online_order_id;
 select stock into stock_before from public.ingredients where id=v_ingredient;
 perform public.adjust_inventory(v_ingredient,-stock_before,'waste','QA stock changed during checkout');
 perform public.reconcile_order_payment(online_order_id,jsonb_build_object('id','qa-payment','external_reference',online_order_id::text,'currency_id','MXN','transaction_amount',100,'status','approved','date_created',now(),'date_last_updated',now()));
 assert (select payment_status='approved' from public.orders where id=online_order_id),'stock shortage lost payment confirmation';
 select id into online_ticket from public.kitchen_tickets where order_id=online_order_id;
 assert online_ticket is not null,'paid order lost kitchen ticket';
 queue:=public.list_kitchen_priority_queue(owner_id);
 assert exists(select 1 from jsonb_array_elements(queue) x where (x->>'id')::bigint=online_ticket and (x->>'has_shortage')::boolean),'paid order shortage not visible';
 perform public.adjust_inventory(v_ingredient,100,'purchase','QA replenish after checkout');
 -- Two stations share one consumption for the whole ticket, with a single sample.
 insert into public.kitchen_stations(restaurant_id,name) values(owner_id,'QA Hot') returning id into station1;
 insert into public.kitchen_stations(restaurant_id,name) values(owner_id,'QA Cold') returning id into station2;
 update public.products set kitchen_station_id=station1 where id=v_product;
 insert into public.products(restaurant_id,name,price,is_available,kitchen_station_id) values(owner_id,'QA Side',50,true,station2) returning id into v_other_product;
 insert into public.product_recipes(product_id,ingredient_id,quantity) values(v_other_product,v_ingredient,2);
 select stock into stock_before from public.ingredients where id=v_ingredient;
 v_order:=public.create_pos_table_order(owner_id,jsonb_build_array(jsonb_build_object('id',v_product,'qty',1),jsonb_build_object('id',v_other_product,'qty',1)),'Stations QA','pickup',null,'cash',null);
 station_ticket:=(v_order->>'kitchen_ticket_id')::bigint;
 perform public.update_kitchen_ticket_station_status(station_ticket,station1::text,'preparando');
 assert (select stock=stock_before-5 from public.ingredients where id=v_ingredient),'shared ingredient demand not aggregated';
 perform public.update_kitchen_ticket_station_status(station_ticket,station2::text,'preparando');
 assert (select stock=stock_before-5 from public.ingredients where id=v_ingredient),'second station deducted twice';
 update public.kitchen_tickets set started_at=now()-interval '10 minutes' where id=station_ticket;
 perform public.update_kitchen_ticket_station_status(station_ticket,station1::text,'listo');
 perform public.update_kitchen_ticket_station_status(station_ticket,station2::text,'listo');
 assert (select status='listo' from public.kitchen_tickets where id=station_ticket),'all ready stations did not complete ticket';
 assert (select count(*)=1 from public.kitchen_prep_samples where ticket_id=station_ticket),'station completion did not record one sample';
 perform set_config('request.jwt.claim.sub',other_id::text,true);
 blocked:=false;begin perform public.list_kitchen_priority_queue(owner_id);exception when others then blocked:=true;end;assert blocked,'other restaurant queue leaked';
 raise notice 'Kitchen priority, inventory and validated model assertions passed';
end;$$;
