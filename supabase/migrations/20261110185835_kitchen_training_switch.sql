alter table public.profiles add column kitchen_training_mode boolean not null default false;
create or replace function public.get_kitchen_mode(p_restaurant_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(public.has_restaurant_permission(p_restaurant_id,'view_kitchen'),false) then raise exception 'Sin permiso de cocina' using errcode='42501';end if;
 return (select jsonb_build_object('training_mode',kitchen_training_mode) from public.profiles where id=p_restaurant_id);
end;$$;
create or replace function public.set_kitchen_mode(p_restaurant_id uuid,p_training_mode boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(public.has_restaurant_permission(p_restaurant_id,'view_kitchen'),false) then raise exception 'Sin permiso de cocina' using errcode='42501';end if;
 if p_training_mode is null then raise exception 'Indica el modo de cocina';end if;
 update public.profiles set kitchen_training_mode=p_training_mode where id=p_restaurant_id;
 return jsonb_build_object('training_mode',p_training_mode);
end;$$;
create or replace function public.kitchen_estimate(p_restaurant_id uuid,p_service_type text,p_items jsonb,p_is_peak boolean)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare m public.kitchen_ml_models%rowtype;v_default numeric;v_work numeric;v_use boolean;v_reason text;v_training boolean;
begin
 select case p_service_type when 'delivery' then delivery_prep_minutes when 'dine_in' then dine_in_prep_minutes else pickup_prep_minutes end,kitchen_training_mode into v_default,v_training from public.profiles where id=p_restaurant_id;
 select * into m from public.kitchen_ml_models where restaurant_id=p_restaurant_id and service_type=p_service_type;
 v_work:=public.kitchen_work_units(p_items);
 v_use:=not coalesce(v_training,false) and coalesce(m.model_ready,false) and not exists(select 1 from jsonb_array_elements(p_items) x where not(m.trained_products ? (x->>'id')))
 and case when p_is_peak then m.peak_sample_count>=3 and v_work between m.peak_work_min and m.peak_work_max else m.off_peak_sample_count>=3 and v_work between m.off_peak_work_min and m.off_peak_work_max end;
 v_use:=coalesce(v_use,false);
 v_reason:=case when v_training then 'Modo entrenamiento: usando tiempo configurado.' when coalesce(m.sample_count,0)<10 then 'Faltan preparaciones: registra al menos 10 por servicio.'
 when not m.model_ready then 'El error de validación aún es alto; agrega mediciones reales variadas.'
 when exists(select 1 from jsonb_array_elements(p_items) x where not(m.trained_products ? (x->>'id'))) then 'Hay productos sin entrenamiento.'
 when not v_use then 'Faltan ejemplos de estas cantidades o de este horario.'
 else 'Estimación calculada con los datos entrenados.' end;
 return jsonb_build_object('minutes',round(case when v_use then greatest(5,least(240,m.intercept+m.per_work_unit*v_work+case when p_is_peak then m.peak_adjustment else 0 end)) else greatest(5,least(240,coalesce(v_default,20))) end,2),
 'model_ready',v_use,'prediction_source',case when v_use then 'validated_model' else 'configured_time' end,'reason',v_reason,'sample_count',coalesce(m.sample_count,0),'mean_absolute_error',m.mean_absolute_error);
end;$$;
create or replace function public.start_kitchen_batch(p_restaurant_id uuid,p_ticket_ids bigint[],p_station_key text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_count integer;v_queue jsonb;v_selected jsonb;v_minpos bigint;v_maxpos bigint;v_minpriority integer;v_maxpriority integer;v_common text;v_id bigint;v_state text;
begin
 if auth.uid() is null or not coalesce(public.has_restaurant_permission(p_restaurant_id,'view_kitchen'),false) then raise exception 'Sin permiso de cocina' using errcode='42501';end if;
 perform 1 from public.profiles where id=p_restaurant_id for share;
 if (select kitchen_training_mode from public.profiles where id=p_restaurant_id) then raise exception 'Desactiva Entrenamiento para usar la preparación conjunta';end if;
 v_count:=coalesce(cardinality(p_ticket_ids),0);
 if v_count not between 2 and 5 or (select count(distinct x) from unnest(p_ticket_ids) x)<>v_count then raise exception 'Selecciona entre 2 y 5 comandas distintas';end if;
 if p_station_key is not null and (length(p_station_key)>40 or p_station_key='') then raise exception 'Estación inválida';end if;
 if (select count(*) from public.kitchen_tickets where id=any(p_ticket_ids) and restaurant_id=p_restaurant_id)<>v_count then raise exception 'Comandas inválidas para este negocio';end if;
 -- Match the lock order of individual ticket operations: orders, tickets, stations.
 perform 1 from public.orders where id in(select order_id from public.kitchen_tickets where id=any(p_ticket_ids)) order by id for update;
 perform 1 from public.kitchen_tickets where id=any(p_ticket_ids) order by id for update;
 perform 1 from public.kitchen_ticket_station_statuses where ticket_id=any(p_ticket_ids) order by ticket_id,station_key for update;
 v_queue:=public.list_kitchen_priority_queue(p_restaurant_id);
 with pending as (
  select value,row_number() over(order by ordinality) pos from jsonb_array_elements(v_queue) with ordinality
  where case when p_station_key is null then value->>'status'='pendiente'
   else exists(select 1 from jsonb_array_elements(value->'kitchen_ticket_station_statuses') s where s->>'station_key'=p_station_key and s->>'status'='pendiente') end
 ), chosen as (select * from pending where (value->>'id')::bigint=any(p_ticket_ids))
 select jsonb_agg(value order by pos),min(pos),max(pos) into v_selected,v_minpos,v_maxpos from chosen;
 if coalesce(jsonb_array_length(v_selected),0)<>v_count or v_maxpos-v_minpos+1<>v_count then raise exception 'La cola cambió. Actualiza las comandas antes de agrupar';end if;
 select min((x->>'priority_override')::integer),max((x->>'priority_override')::integer) into v_minpriority,v_maxpriority from jsonb_array_elements(v_selected) x;
 if v_minpriority<0 or v_minpriority<>v_maxpriority then raise exception 'Solo agrupa comandas con la misma prioridad';end if;
 if exists(select 1 from jsonb_array_elements(v_selected) x where length(trim(coalesce(x->>'notes','')))>0) then raise exception 'Las comandas con notas se preparan individualmente';end if;
 if exists(select 1 from jsonb_array_elements(v_selected) x cross join lateral jsonb_array_elements(x->'items') i where exists(select 1 from jsonb_each(i) kv where kv.key in('notes','note','modifiers','options','instructions') and kv.value not in('null'::jsonb,'""'::jsonb,'[]'::jsonb,'{}'::jsonb))) then raise exception 'Las preparaciones especiales se revisan individualmente';end if;
 if exists(select 1 from jsonb_array_elements(v_selected) x where (x->>'recommended_start_at')::timestamptz>now()+interval '5 minutes') or
 (select max((x->>'recommended_start_at')::timestamptz)-min((x->>'recommended_start_at')::timestamptz)>interval '5 minutes' or max((x->>'target_ready_at')::timestamptz)-min((x->>'target_ready_at')::timestamptz)>interval '5 minutes' from jsonb_array_elements(v_selected) x) then raise exception 'Los horarios de estas comandas requieren preparación individual';end if;
 select i->>'id'||'@'||coalesce(i->>'station_id',p.kitchen_station_id::text,'general') into v_common
 from jsonb_array_elements(v_selected) t cross join lateral jsonb_array_elements(t->'items') i
 join public.products p on p.id::text=i->>'id' and p.restaurant_id=p_restaurant_id
 where p_station_key is null or coalesce(i->>'station_id',p.kitchen_station_id::text,'general')=p_station_key
 group by i->>'id',coalesce(i->>'station_id',p.kitchen_station_id::text,'general') having count(distinct t->>'id')=v_count limit 1;
 if v_common is null then raise exception 'No hay productos iguales en la misma estación';end if;
 foreach v_id in array p_ticket_ids loop
  if p_station_key is null then perform public.update_kitchen_ticket_status(v_id,'preparando');
  else perform public.update_kitchen_ticket_station_status(v_id,p_station_key,'preparando');end if;
 end loop;
 return jsonb_build_object('ticket_ids',to_jsonb(p_ticket_ids),'status','preparando');
end;$$;
revoke all on function public.get_kitchen_mode(uuid),public.set_kitchen_mode(uuid,boolean) from public,anon;
grant execute on function public.get_kitchen_mode(uuid),public.set_kitchen_mode(uuid,boolean) to authenticated;
