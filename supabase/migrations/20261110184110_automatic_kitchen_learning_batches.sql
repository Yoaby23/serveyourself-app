-- Only measured preparation time is training data; queue waiting must never be substituted.
create or replace function public.prepare_kitchen_ticket_timing()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='preparando' and old.status is distinct from 'preparando' then
  new.started_at:=coalesce(new.started_at,now());
  if new.predicted_prep_minutes is null then
   new.predicted_prep_minutes:=public.predict_kitchen_minutes(new.id);
   new.prediction_source:=case when public.kitchen_model_usable(new.id) then 'validated_model' else 'configured_time' end;
   if new.prediction_source='validated_model' then select mean_absolute_error into new.prediction_error_minutes from public.kitchen_ml_models where restaurant_id=new.restaurant_id and service_type=new.service_type;end if;
  end if;
 elsif new.status='listo' and old.status is distinct from 'listo' then
  new.started_at:=coalesce(new.started_at,old.started_at);
  new.ready_at:=coalesce(new.ready_at,now());
  new.predicted_prep_minutes:=coalesce(new.predicted_prep_minutes,public.predict_kitchen_minutes(new.id));
  new.prediction_source:=coalesce(new.prediction_source,'configured_time');
 end if;
 return new;
end;$$;

create or replace function public.learn_from_kitchen_ticket()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_timezone text;v_minutes numeric;v_hour integer;
begin
 if new.status<>'listo' or old.status='listo' or new.started_at is null or new.ready_at is null then return new;end if;
 if exists(select 1 from public.orders where id=new.order_id and status='cancelado') then return new;end if;
 v_minutes:=extract(epoch from(new.ready_at-new.started_at))/60.0;
 if v_minutes<1 or v_minutes>240 then return new;end if;
 select coalesce(timezone,'UTC') into v_timezone from public.profiles where id=new.restaurant_id;
 v_hour:=extract(hour from new.started_at at time zone v_timezone)::integer;
 perform pg_advisory_xact_lock(hashtextextended(new.restaurant_id::text||':'||new.service_type,0));
 insert into public.kitchen_prep_samples(ticket_id,restaurant_id,service_type,work_units,is_peak,prep_minutes,items)
 values(new.id,new.restaurant_id,new.service_type,public.kitchen_work_units(new.items),v_hour between 13 and 16 or v_hour between 19 and 22,round(v_minutes,2),new.items)
 on conflict(ticket_id) do nothing;
 if found then perform public.retrain_kitchen_model(new.restaurant_id,new.service_type);end if;
 return new;
end;$$;
-- Reassert the automatic hook used by both whole-ticket and per-station completion.
drop trigger if exists learn_from_kitchen_ticket on public.kitchen_tickets;
create trigger learn_from_kitchen_ticket after update of status on public.kitchen_tickets for each row execute function public.learn_from_kitchen_ticket();

-- Start a suggested batch atomically. Tickets, payments, notes and fulfillment remain separate.
create or replace function public.start_kitchen_batch(p_restaurant_id uuid,p_ticket_ids bigint[],p_station_key text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_count integer;v_queue jsonb;v_selected jsonb;v_minpos bigint;v_maxpos bigint;v_minpriority integer;v_maxpriority integer;v_common text;v_id bigint;v_state text;
begin
 if auth.uid() is null or not coalesce(public.has_restaurant_permission(p_restaurant_id,'view_kitchen'),false) then raise exception 'Sin permiso de cocina' using errcode='42501';end if;
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
revoke all on function public.start_kitchen_batch(uuid,bigint[],text) from public,anon;
grant execute on function public.start_kitchen_batch(uuid,bigint[],text) to authenticated;
revoke all on function public.prepare_kitchen_ticket_timing(),public.learn_from_kitchen_ticket() from public,anon,authenticated;
