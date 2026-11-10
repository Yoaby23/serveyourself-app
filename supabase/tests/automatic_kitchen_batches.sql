do $$
declare owner_id uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();product_id uuid;other_product uuid;items jsonb;o jsonb;q jsonb;ids bigint[]:='{}';v_id bigint;blocked boolean;result jsonb;before_count integer;v_qty integer;v_time numeric;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-auto-ml-'||owner_id||'@example.invalid',jsonb_build_object('role','negocio','business_name','Auto batch QA','full_name','QA')),
 (outsider,'qa-auto-ml-'||outsider||'@example.invalid','{"full_name":"Stranger"}');
 update public.profiles set open_time=null,close_time=null,accepting_orders=true where id=owner_id;
 insert into public.products(restaurant_id,name,price) values(owner_id,'Compartido',10) returning id into product_id;
 insert into public.products(restaurant_id,name,price) values(owner_id,'Otro',10) returning id into other_product;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 perform public.open_cash_shift(owner_id,0);
 for i in 1..3 loop
  items:=jsonb_build_array(jsonb_build_object('id',case when i=3 then other_product else product_id end,'qty',1));
  o:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'Batch QA');
  perform public.register_pos_payment_v2((o->>'id')::bigint,'cash',10,0,10);
  ids:=array_append(ids,(select id from public.kitchen_tickets where order_id=(o->>'id')::bigint));
 end loop;
 blocked:=false;begin perform public.start_kitchen_batch(owner_id,array[ids[1],ids[3]],null);exception when others then blocked:=true;end;assert blocked,'Cannot skip earlier incompatible tickets';
 assert (select count(*) from public.kitchen_tickets where id=any(ids) and status='pendiente')=3,'Failed batch partially started';
 execute 'reset role';update public.kitchen_tickets set notes='Sin azúcar' where id=ids[2];execute 'set local role authenticated';
 blocked:=false;begin perform public.start_kitchen_batch(owner_id,ids[1:2],null);exception when others then blocked:=true;end;assert blocked,'Special request was grouped';
 execute 'reset role';update public.kitchen_tickets set notes=null where id=ids[2];execute 'set local role authenticated';
 perform public.set_kitchen_ticket_priority(ids[2],1,null);
 blocked:=false;begin perform public.start_kitchen_batch(owner_id,ids[1:2],null);exception when others then blocked:=true;end;assert blocked,'Different priorities were grouped';
 perform public.set_kitchen_ticket_priority(ids[2],0,null);
 execute 'reset role';update public.orders set scheduled_for=now()+interval '1 hour' where id=(select order_id from public.kitchen_tickets where id=ids[2]);execute 'set local role authenticated';
 blocked:=false;begin perform public.start_kitchen_batch(owner_id,ids[1:2],null);exception when others then blocked:=true;end;assert blocked,'Future pickup was started too early';
 execute 'reset role';update public.orders set scheduled_for=null where id=(select order_id from public.kitchen_tickets where id=ids[2]);execute 'set local role authenticated';
 blocked:=false;begin perform public.start_kitchen_batch(owner_id,ids[2:3],null);exception when others then blocked:=true;end;assert blocked,'Unrelated products were grouped';
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 blocked:=false;begin perform public.start_kitchen_batch(owner_id,ids[1:2],null);exception when insufficient_privilege then blocked:=true;end;assert blocked,'Foreign account can start batch';
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 result:=public.start_kitchen_batch(owner_id,ids[1:2],null);
 assert (select count(*) from public.kitchen_tickets where id=any(ids[1:2]) and status='preparando' and started_at is not null)=2,'Batch did not start both measured timers';
 assert (select count(distinct order_id) from public.kitchen_tickets where id=any(ids))=3,'Batch merged accounts';
 assert (select count(*) from public.orders where id in(select order_id from public.kitchen_tickets where id=any(ids)) and payment_status='approved')=3,'Batch altered payments';
 blocked:=false;begin perform public.start_kitchen_batch(owner_id,ids[1:2],null);exception when others then blocked:=true;end;assert blocked,'Repeated batch start reset timers';
 execute 'reset role';update public.kitchen_tickets set started_at=now()-interval '12 minutes' where id=any(ids[1:2]);execute 'set local role authenticated';
 perform public.update_kitchen_ticket_status(ids[1],'listo');
 assert (select count(*) from public.kitchen_prep_samples where restaurant_id=owner_id)=1,'Finishing one ticket must learn once';
 assert (select status from public.kitchen_tickets where id=ids[2])='preparando','Finishing one ticket finished its neighbor';
 perform public.update_kitchen_ticket_status(ids[2],'listo');
 assert (select count(*) from public.kitchen_prep_samples where restaurant_id=owner_id and manual_request_id is null)=2,'Batch completion did not train automatically';
 -- Station flow must also learn; preparing a station sets the parent timer.
 perform public.update_kitchen_ticket_station_status(ids[3],'general','preparando');
 execute 'reset role';update public.kitchen_tickets set started_at=now()-interval '10 minutes' where id=ids[3];execute 'set local role authenticated';
 perform public.update_kitchen_ticket_station_status(ids[3],'general','listo');
 assert (select count(*) from public.kitchen_prep_samples where restaurant_id=owner_id)=3,'Station completion did not learn';
 -- Enough real completions automatically create a validated model, without any manual train RPC.
 for i in 1..12 loop
  v_qty:=1+(i-1)%3;v_time:=8+2*(v_qty+.35);
  items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',v_qty));
  o:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'Auto QA');
  perform public.register_pos_payment_v2((o->>'id')::bigint,'cash',v_qty*10,0,v_qty*10);
  select id into v_id from public.kitchen_tickets where order_id=(o->>'id')::bigint;
  perform public.update_kitchen_ticket_status(v_id,'preparando');
  execute 'reset role';update public.kitchen_tickets set started_at=now()-make_interval(secs=>round(v_time*60)::integer) where id=v_id;execute 'set local role authenticated';
  perform public.update_kitchen_ticket_status(v_id,'listo');
 end loop;
 assert (select sample_count from public.kitchen_ml_models where restaurant_id=owner_id and service_type='pickup')=15,'Automatic observations were not used to retrain';
 assert (select model_ready from public.kitchen_ml_models where restaurant_id=owner_id and service_type='pickup'),'Automatic model never became usable';
 -- Batch start must also work in a station-filtered view once its recommended start is due.
 execute 'reset role';update public.profiles set pickup_prep_minutes=10 where id=owner_id;execute 'set local role authenticated';
 ids:='{}';
 for i in 1..2 loop
  items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',1));
  o:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'Station batch QA');
  perform public.register_pos_payment_v2((o->>'id')::bigint,'cash',10,0,10);
  ids:=array_append(ids,(select id from public.kitchen_tickets where order_id=(o->>'id')::bigint));
 end loop;
 perform public.start_kitchen_batch(owner_id,ids,'general');
 assert (select count(*) from public.kitchen_ticket_station_statuses where ticket_id=any(ids) and station_key='general' and status='preparando')=2,'Station batch did not start';
 assert (select count(*) from public.kitchen_tickets where id=any(ids) and started_at is not null)=2,'Station batch did not start timers';
 -- A legacy ticket marked ready without a measured start must not train on time spent waiting.
 execute 'reset role';
 select count(*) into before_count from public.kitchen_prep_samples where restaurant_id=owner_id;
 insert into public.kitchen_tickets(order_id,restaurant_id,items,service_type,status,created_at)
 values((o->>'id')::bigint,owner_id,items,'dine_in','pendiente',now()-interval '1 hour') returning id into v_id;
 update public.kitchen_tickets set status='listo' where id=v_id;
 assert (select started_at from public.kitchen_tickets where id=v_id) is null,'Queue waiting was used as preparation start';
 assert (select count(*) from public.kitchen_prep_samples where restaurant_id=owner_id)=before_count,'Unmeasured legacy ticket contaminated training';
 assert not has_function_privilege('anon','public.start_kitchen_batch(uuid,bigint[],text)','execute'),'Anonymous batch execution allowed';
end;$$;
