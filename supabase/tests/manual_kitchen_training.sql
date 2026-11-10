-- Run in a transaction and roll back: synthetic observations must never reach a real business.
do $$
declare owner_id uuid:=gen_random_uuid();stranger_id uuid:=gen_random_uuid();product_id uuid;other_product uuid;items jsonb;req uuid;result jsonb;sample_id bigint;v_qty integer;v_peak boolean;v_minutes numeric;blocked boolean;before_count integer;ticket bigint;ord jsonb;q jsonb;expected numeric;claims text;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-ml-'||owner_id||'@example.invalid',jsonb_build_object('role','negocio','business_name','Kitchen training QA','full_name','QA')),
 (stranger_id,'qa-ml-'||stranger_id||'@example.invalid','{"full_name":"Stranger"}');
 update public.profiles set open_time=null,close_time=null,accepting_orders=true,pickup_prep_minutes=60 where id=owner_id;
 insert into public.products(restaurant_id,name,price) values(owner_id,'Entrenado',100) returning id into product_id;
 insert into public.products(restaurant_id,name,price) values(owner_id,'Sin entrenamiento',100) returning id into other_product;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 result:=public.get_kitchen_training_status(owner_id);
 assert result->'models'='[]'::jsonb,'Expected clean isolated model';
 items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',2));
 result:=public.preview_kitchen_training(owner_id,'pickup',items,false);
 assert result->>'prediction_source'='configured_time' and (result->>'minutes')::numeric=60,'Cold start must use configured time';
 for i in 1..12 loop
  v_qty:=1+(i-1)%3;v_peak:=i%2=0;v_minutes:=8+2*(v_qty+.35)+case when v_peak then 5 else 0 end;
  items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',v_qty));req:=gen_random_uuid();
  result:=public.save_kitchen_training_sample(owner_id,'pickup',items,v_minutes,v_peak,req);
  if i=1 then sample_id:=(result->>'sample_id')::bigint;end if;
  result:=public.save_kitchen_training_sample(owner_id,'pickup',items,v_minutes,v_peak,req);
  assert (result->>'duplicate')::boolean,'Network retry must be idempotent';
 end loop;
 result:=public.train_kitchen_model(owner_id,'pickup');
 assert (result->>'sample_count')::integer=12,'Duplicate retry contaminated training';
 assert (result->>'model_ready')::boolean,'Known linear observations failed validation';
 assert (result->>'validation_sample_count')::integer>=2,'Must validate with reserved observations';
 assert abs((result->>'per_work_unit')::numeric-2)<.001,'Quantity coefficient not learned';
 assert abs((result->>'peak_adjustment')::numeric-5)<.001,'Peak coefficient not learned';
 items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',2));
 result:=public.preview_kitchen_training(owner_id,'pickup',items,false);
 assert result->>'prediction_source'='validated_model' and abs((result->>'minutes')::numeric-12.7)<.01,'Prediction ignored trained coefficients';
 result:=public.preview_kitchen_training(owner_id,'pickup',items,true);
 assert abs((result->>'minutes')::numeric-17.7)<.01,'Peak prediction ignored trained data';
 result:=public.preview_kitchen_training(owner_id,'dine_in',items,false);
 assert result->>'prediction_source'='configured_time','Must not borrow another service model';
 result:=public.preview_kitchen_training(owner_id,'pickup',jsonb_build_array(jsonb_build_object('id',other_product,'qty',2)),false);
 assert result->>'prediction_source'='configured_time','Unknown product must use fallback';
 result:=public.preview_kitchen_training(owner_id,'pickup',jsonb_build_array(jsonb_build_object('id',product_id,'qty',90)),false);
 assert result->>'prediction_source'='configured_time','Extrapolation outside observed quantities must use fallback';
 blocked:=false;begin perform public.save_kitchen_training_sample(owner_id,'pickup',items,0,false,gen_random_uuid());exception when others then blocked:=true;end;assert blocked,'Invalid duration accepted';
 blocked:=false;begin perform public.save_kitchen_training_sample(owner_id,'pickup',items||items,10,false,gen_random_uuid());exception when others then blocked:=true;end;assert blocked,'Duplicate products accepted';
 blocked:=false;begin perform public.save_kitchen_training_sample(owner_id,'pickup',items,10,false,req);exception when others then blocked:=true;end;assert blocked,'Reused key with changed data accepted';
 result:=public.save_kitchen_training_sample(owner_id,'dine_in',items,12,false,gen_random_uuid());
 perform public.delete_kitchen_training_sample((result->>'sample_id')::bigint);
 result:=public.train_kitchen_model(owner_id,'dine_in');
 assert (result->>'sample_count')::integer=0 and not (result->>'model_ready')::boolean,'Deleting the last sample must clear a stale model';
 -- The public queue must consume these coefficients, rather than just reporting training success.
 perform public.open_cash_shift(owner_id,0);
 ord:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'QA ML');
 perform public.register_pos_payment_v2((ord->>'id')::bigint,'cash',200,0,200);
 q:=public.list_kitchen_priority_queue(owner_id);
 assert jsonb_array_length(q)=1,'Missing pending kitchen ticket';
 ticket:=(q->0->>'id')::bigint;
 assert q->0->>'prediction_source'='validated_model','Live queue did not use trained model';
 expected:=case when extract(hour from now() at time zone (select timezone from public.profiles where id=owner_id))::integer between 13 and 16 or extract(hour from now() at time zone (select timezone from public.profiles where id=owner_id))::integer between 19 and 22 then 18 else 13 end;
 assert (q->0->>'predicted_prep_minutes')::numeric=expected,'Live queue estimate diverged from training preview';
 perform public.update_kitchen_ticket_status(ticket,'preparando');
 perform set_config('request.jwt.claim.sub',stranger_id::text,true);
 blocked:=false;begin perform public.train_kitchen_model(owner_id,'pickup');exception when insufficient_privilege then blocked:=true;end;assert blocked,'Foreign account can train';
 blocked:=false;begin perform public.save_kitchen_training_sample(owner_id,'pickup',items,10,false,gen_random_uuid());exception when insufficient_privilege then blocked:=true;end;assert blocked,'Foreign account can add observations';
 blocked:=false;begin perform public.delete_kitchen_training_sample(sample_id);exception when insufficient_privilege then blocked:=true;end;assert blocked,'Foreign account can delete observations';
 blocked:=false;begin perform public.get_kitchen_training_status(owner_id);exception when insufficient_privilege then blocked:=true;end;assert blocked,'Foreign account can view training';
 assert not exists(select 1 from public.kitchen_prep_samples where restaurant_id=owner_id),'RLS exposes foreign samples';
 execute 'reset role';
 -- Marking a genuinely timed ticket ready still records and retrains automatically.
 update public.kitchen_tickets set started_at=now()-interval '12 minutes' where id=ticket;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 perform public.update_kitchen_ticket_status(ticket,'listo');
 assert exists(select 1 from public.kitchen_prep_samples s where s.ticket_id=ticket and s.items is not null and s.manual_request_id is null),'Automatic learning stopped';
 perform public.delete_kitchen_training_sample(sample_id);
 assert not exists(select 1 from public.kitchen_prep_samples where id=sample_id),'Manual observation was not removed';
 blocked:=false;begin perform public.delete_kitchen_training_sample((select id from public.kitchen_prep_samples where ticket_id=ticket));exception when others then blocked:=true;end;assert blocked,'Real observation deleted through manual editor';
 execute 'reset role';
 assert not has_function_privilege('anon','public.train_kitchen_model(uuid,text)','execute'),'Anonymous training allowed';
 assert not has_function_privilege('authenticated','public.kitchen_estimate(uuid,text,jsonb,boolean)','execute'),'Internal model exposed';
 assert not has_table_privilege('authenticated','public.kitchen_ml_models','update'),'Browser can overwrite coefficients';
end;$$;
