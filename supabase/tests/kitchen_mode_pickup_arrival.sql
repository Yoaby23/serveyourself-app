do $$
declare owner_id uuid:=gen_random_uuid();customer uuid:=gen_random_uuid();outsider uuid:=gen_random_uuid();product_id uuid;o jsonb;o2 jsonb;items jsonb;ticket bigint;ticket2 bigint;result jsonb;q jsonb;scheduled timestamptz:=now()+interval '1 hour';arrival timestamptz;blocked boolean;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-switch-'||owner_id||'@example.invalid',jsonb_build_object('role','negocio','business_name','Mode pickup QA','full_name','QA')),
 (customer,'qa-switch-'||customer||'@example.invalid','{"full_name":"Customer"}'),
 (outsider,'qa-switch-'||outsider||'@example.invalid','{"full_name":"Stranger"}');
 update public.profiles set open_time=null,close_time=null,accepting_orders=true,latitude=20,longitude=-103,pickup_prep_minutes=20 where id=owner_id;
 insert into public.products(restaurant_id,name,price) values(owner_id,'Pickup QA',10) returning id into product_id;
 items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',1));
 perform set_config('request.jwt.claim.sub',owner_id::text,true);execute 'set local role authenticated';
 result:=public.get_kitchen_mode(owner_id);assert not(result->>'training_mode')::boolean,'Automatic kitchen must be preconfigured';
 for i in 1..12 loop perform public.save_kitchen_training_sample(owner_id,'pickup',items,15,i%2=0,gen_random_uuid());end loop;
 result:=public.preview_kitchen_training(owner_id,'pickup',items,false);assert (result->>'model_ready')::boolean and (result->>'minutes')::numeric=15,'Automatic mode must use trained coefficients';
 perform public.set_kitchen_mode(owner_id,true);
 result:=public.preview_kitchen_training(owner_id,'pickup',items,false);assert not(result->>'model_ready')::boolean and (result->>'minutes')::numeric=20,'Training mode must use configured time';
 blocked:=false;begin perform public.start_kitchen_batch(owner_id,array[1::bigint,2::bigint],null);exception when others then blocked:=sqlerrm like '%Desactiva Entrenamiento%';end;assert blocked,'Training mode allowed automatic batching';
 perform public.set_kitchen_mode(owner_id,false);
 result:=public.preview_kitchen_training(owner_id,'pickup',items,false);assert (result->>'model_ready')::boolean,'Disabling training did not enable trained model';
 perform public.open_cash_shift(owner_id,0);
 o:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'Location QA');perform public.register_pos_payment_v2((o->>'id')::bigint,'cash',10,0,10);
 o2:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'Unpaid location QA');
 select id into ticket from public.kitchen_tickets where order_id=(o->>'id')::bigint;
 execute 'reset role';update public.orders set customer_id=customer,scheduled_for=scheduled where id in((o->>'id')::bigint,(o2->>'id')::bigint);execute 'set local role authenticated';
 q:=public.list_kitchen_priority_queue(owner_id);assert (q->0->>'target_ready_at')::timestamptz=scheduled,'Pickup without tracking lost its scheduled time';
 perform set_config('request.jwt.claim.sub',customer::text,true);
 blocked:=false;begin perform public.set_pickup_location_sharing((o2->>'id')::bigint,true);exception when others then blocked:=true;end;assert blocked,'Unpaid pickup enabled arrival sharing';
 perform public.set_pickup_location_sharing((o->>'id')::bigint,true);
 result:=public.update_pickup_arrival((o->>'id')::bigint,20.01,-103,10,now(),'car');arrival:=(result->>'arrival_at')::timestamptz;
 assert (result->>'approximate')::boolean,'Arrival must be labeled approximate';
 blocked:=false;begin perform public.update_pickup_arrival((o->>'id')::bigint,20,-103,200,now(),'car');exception when others then blocked:=true;end;assert blocked,'Inaccurate location accepted';
 blocked:=false;begin perform public.update_pickup_arrival((o->>'id')::bigint,20,-103,10,now()-interval '4 minutes','car');exception when others then blocked:=true;end;assert blocked,'Stale location accepted';
 blocked:=false;begin update public.orders set pickup_arrival_at=now() where id=(o->>'id')::bigint;exception when insufficient_privilege then blocked:=true;end;assert blocked,'Client can forge ETA directly';
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 q:=public.list_kitchen_priority_queue(owner_id);
 assert (q->0->>'target_ready_at')::timestamptz=arrival,'Kitchen ignored customer arrival';
 assert (q->0->>'recommended_start_at')::timestamptz=arrival-interval '15 minutes','Start did not combine arrival with learned preparation time';
 assert q->0->>'priority_reason' like 'Cliente llega en aproximadamente%','Kitchen did not explain pickup arrival';
 assert not((q->0) ? 'pickup_customer_latitude'),'Queue exposes raw customer coordinates';
 execute 'reset role';update public.orders set pickup_location_at=now()-interval '4 minutes' where id=(o->>'id')::bigint;execute 'set local role authenticated';
 q:=public.list_kitchen_priority_queue(owner_id);assert (q->0->>'target_ready_at')::timestamptz=scheduled,'Stale sharing must fall back to schedule';
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 blocked:=false;begin perform public.set_kitchen_mode(owner_id,true);exception when insufficient_privilege then blocked:=true;end;assert blocked,'Foreign account changes kitchen mode';
 blocked:=false;begin perform public.update_pickup_arrival((o->>'id')::bigint,20,-103,10,now(),'car');exception when insufficient_privilege then blocked:=true;end;assert blocked,'Foreign account can send location';
 blocked:=false;begin perform public.set_pickup_location_sharing((o->>'id')::bigint,false);exception when insufficient_privilege then blocked:=true;end;assert blocked,'Foreign account can change location consent';
 perform set_config('request.jwt.claim.sub',customer::text,true);
 perform public.set_pickup_location_sharing((o->>'id')::bigint,false);
 assert (select pickup_customer_latitude is null and pickup_arrival_at is null from public.orders where id=(o->>'id')::bigint),'Disabling sharing did not clear location';
 perform public.set_pickup_location_sharing((o->>'id')::bigint,true);
 result:=public.update_pickup_arrival((o->>'id')::bigint,20,-103,10,now(),'walking');assert (result->>'eta_minutes')::integer=0,'Arrival at the business was not detected';
 execute 'reset role';update public.orders set status='entregado' where id=(o->>'id')::bigint;
 assert (select not pickup_tracking_enabled and pickup_customer_latitude is null and pickup_location_at is null from public.orders where id=(o->>'id')::bigint),'Delivered order retained pickup location';
 assert not has_function_privilege('anon','public.update_pickup_arrival(bigint,double precision,double precision,double precision,timestamptz,text)','execute'),'Anonymous location access allowed';
end;$$;
