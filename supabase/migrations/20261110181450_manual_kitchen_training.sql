-- Manual measurements do not create operational orders or tickets; all samples keep item snapshots.
alter table public.kitchen_prep_samples alter column ticket_id drop not null;
alter table public.kitchen_prep_samples add column items jsonb not null default '[]'::jsonb,
 add column manual_request_id uuid unique,
 add column created_by uuid references auth.users(id) on delete set null;
update public.kitchen_prep_samples s set items=t.items from public.kitchen_tickets t where s.ticket_id=t.id;
alter table public.kitchen_prep_samples add constraint kitchen_sample_source check(ticket_id is not null or manual_request_id is not null);
revoke all on public.kitchen_prep_samples,public.kitchen_ml_models from anon;
revoke insert,update,delete on public.kitchen_prep_samples,public.kitchen_ml_models from authenticated;
grant select on public.kitchen_prep_samples,public.kitchen_ml_models to authenticated;

CREATE OR REPLACE FUNCTION public.retrain_kitchen_model(p_restaurant_id uuid, p_service_type text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare samples jsonb;training jsonb;fitted jsonb;final_fit jsonb;n integer;v_holdout integer;v_mae numeric;v_mean numeric;v_peak integer;v_off integer;v_ready boolean;v_off_min numeric;v_off_max numeric;v_peak_min numeric;v_peak_max numeric;v_products jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_restaurant_id::text||':'||p_service_type,0));
 -- Bounded recent history keeps learning cost predictable and adapts to recipe changes.
 select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at,s.id),'[]'::jsonb) into samples from
 (select id,ticket_id,work_units,prep_minutes,is_peak,created_at,items from public.kitchen_prep_samples where restaurant_id=p_restaurant_id and service_type=p_service_type order by created_at desc,id desc limit 500) s;
 n:=jsonb_array_length(samples);if n=0 then delete from public.kitchen_ml_models where restaurant_id=p_restaurant_id and service_type=p_service_type;return;end if;
 v_holdout:=case when n>=10 then greatest(2,floor(n*.2)::integer) else 0 end;
 select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into training from jsonb_array_elements(samples) with ordinality where ordinality<=n-v_holdout;
 fitted:=public.fit_kitchen_samples(training);final_fit:=public.fit_kitchen_samples(samples);
 select count(*) filter(where (x->>'is_peak')::boolean),count(*) filter(where not (x->>'is_peak')::boolean),avg((x->>'prep_minutes')::numeric) into v_peak,v_off,v_mean from jsonb_array_elements(samples) x;
 if v_holdout>0 then
  select avg(abs((value->>'prep_minutes')::numeric - greatest(5,least(240,(fitted->>'intercept')::numeric+(fitted->>'per_work_unit')::numeric*(value->>'work_units')::numeric+case when (value->>'is_peak')::boolean then (fitted->>'peak_adjustment')::numeric else 0 end))))
  into v_mae from jsonb_array_elements(samples) with ordinality where ordinality>n-v_holdout;
 end if;
 select min((x->>'work_units')::numeric) filter(where not (x->>'is_peak')::boolean),max((x->>'work_units')::numeric) filter(where not (x->>'is_peak')::boolean),min((x->>'work_units')::numeric) filter(where (x->>'is_peak')::boolean),max((x->>'work_units')::numeric) filter(where (x->>'is_peak')::boolean)
 into v_off_min,v_off_max,v_peak_min,v_peak_max from jsonb_array_elements(samples) x;
 select coalesce(jsonb_agg(distinct item->>'id'),'[]'::jsonb) into v_products from jsonb_array_elements(samples) s cross join lateral jsonb_array_elements(s->'items') item;
 v_ready:=n>=10 and v_mae is not null and v_mae<=greatest(5,v_mean*.35);
 insert into public.kitchen_ml_models(restaurant_id,service_type,sample_count,intercept,per_work_unit,peak_adjustment,mean_absolute_error,trained_at,training_sample_count,validation_sample_count,peak_sample_count,off_peak_sample_count,model_ready,off_peak_work_min,off_peak_work_max,peak_work_min,peak_work_max,trained_products)
 values(p_restaurant_id,p_service_type,n,(final_fit->>'intercept')::numeric,(final_fit->>'per_work_unit')::numeric,(final_fit->>'peak_adjustment')::numeric,v_mae,now(),n-v_holdout,v_holdout,v_peak,v_off,v_ready,v_off_min,v_off_max,v_peak_min,v_peak_max,v_products)
 on conflict(restaurant_id,service_type) do update set sample_count=excluded.sample_count,intercept=excluded.intercept,per_work_unit=excluded.per_work_unit,peak_adjustment=excluded.peak_adjustment,mean_absolute_error=excluded.mean_absolute_error,trained_at=excluded.trained_at,training_sample_count=excluded.training_sample_count,validation_sample_count=excluded.validation_sample_count,peak_sample_count=excluded.peak_sample_count,off_peak_sample_count=excluded.off_peak_sample_count,model_ready=excluded.model_ready,off_peak_work_min=excluded.off_peak_work_min,off_peak_work_max=excluded.off_peak_work_max,peak_work_min=excluded.peak_work_min,peak_work_max=excluded.peak_work_max,trained_products=excluded.trained_products;
end;$function$
;
CREATE OR REPLACE FUNCTION public.learn_from_kitchen_ticket()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_timezone text;
    v_minutes numeric;
    v_hour integer;
begin
    if new.status<>'listo' or old.status='listo' or new.started_at is null or new.ready_at is null then return new;end if;
    v_minutes:=extract(epoch from (new.ready_at-new.started_at))/60.0;
    if v_minutes<1 or v_minutes>240 then return new;end if;
    select coalesce(timezone,'UTC') into v_timezone from public.profiles where id=new.restaurant_id;
    v_hour:=extract(hour from new.started_at at time zone v_timezone)::integer;
    perform pg_advisory_xact_lock(hashtextextended(new.restaurant_id::text||':'||new.service_type,0));
    insert into public.kitchen_prep_samples(ticket_id,restaurant_id,service_type,work_units,is_peak,prep_minutes,items)
    values(new.id,new.restaurant_id,new.service_type,public.kitchen_work_units(new.items),v_hour between 13 and 16 or v_hour between 19 and 22,round(v_minutes,2),new.items)
    on conflict(ticket_id) do nothing;
    perform public.retrain_kitchen_model(new.restaurant_id,new.service_type);
    return new;
end;
$function$
;

-- Reuse exactly the same applicability checks and coefficients for preview and live tickets.
create or replace function public.kitchen_estimate(p_restaurant_id uuid,p_service_type text,p_items jsonb,p_is_peak boolean)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare m public.kitchen_ml_models%rowtype;v_default numeric;v_work numeric;v_use boolean;v_reason text;
begin
 select case p_service_type when 'delivery' then delivery_prep_minutes when 'dine_in' then dine_in_prep_minutes else pickup_prep_minutes end into v_default from public.profiles where id=p_restaurant_id;
 select * into m from public.kitchen_ml_models where restaurant_id=p_restaurant_id and service_type=p_service_type;
 v_work:=public.kitchen_work_units(p_items);
 v_use:=coalesce(m.model_ready,false) and not exists(select 1 from jsonb_array_elements(p_items) x where not(m.trained_products ? (x->>'id')))
 and case when p_is_peak then m.peak_sample_count>=3 and v_work between m.peak_work_min and m.peak_work_max else m.off_peak_sample_count>=3 and v_work between m.off_peak_work_min and m.off_peak_work_max end;
 v_use:=coalesce(v_use,false);
 v_reason:=case when coalesce(m.sample_count,0)<10 then 'Faltan preparaciones: registra al menos 10 por servicio.'
 when not m.model_ready then 'El error de validación aún es alto; agrega mediciones reales variadas.'
 when exists(select 1 from jsonb_array_elements(p_items) x where not(m.trained_products ? (x->>'id'))) then 'Hay productos sin entrenamiento.'
 when not v_use then 'Faltan ejemplos de estas cantidades o de este horario.'
 else 'Estimación calculada con los datos entrenados.' end;
 return jsonb_build_object('minutes',round(case when v_use then greatest(5,least(240,m.intercept+m.per_work_unit*v_work+case when p_is_peak then m.peak_adjustment else 0 end)) else greatest(5,least(240,coalesce(v_default,20))) end,2),
 'model_ready',v_use,'prediction_source',case when v_use then 'validated_model' else 'configured_time' end,'reason',v_reason,'sample_count',coalesce(m.sample_count,0),'mean_absolute_error',m.mean_absolute_error);
end;$$;
create or replace function public.predict_kitchen_minutes(p_ticket_id bigint)
returns numeric language plpgsql stable security definer set search_path='' as $$
declare t public.kitchen_tickets%rowtype;v_hour integer;
begin
 select * into t from public.kitchen_tickets where id=p_ticket_id;if not found then raise exception 'Comanda no encontrada';end if;
 select extract(hour from coalesce(t.started_at,now()) at time zone coalesce(p.timezone,'UTC'))::integer into v_hour from public.profiles p where p.id=t.restaurant_id;
 return (public.kitchen_estimate(t.restaurant_id,t.service_type,t.items,v_hour between 13 and 16 or v_hour between 19 and 22)->>'minutes')::numeric;
end;$$;
create or replace function public.kitchen_model_usable(p_ticket_id bigint)
returns boolean language sql stable security definer set search_path='' as $$
 select (public.kitchen_estimate(t.restaurant_id,t.service_type,t.items,
 extract(hour from coalesce(t.started_at,now()) at time zone coalesce(p.timezone,'UTC'))::integer between 13 and 16 or
 extract(hour from coalesce(t.started_at,now()) at time zone coalesce(p.timezone,'UTC'))::integer between 19 and 22)->>'model_ready')::boolean
 from public.kitchen_tickets t join public.profiles p on p.id=t.restaurant_id where t.id=p_ticket_id;
$$;

-- Browser input never chooses work units, model coefficients or another restaurant's products.
create or replace function public.validate_kitchen_training_items(p_restaurant_id uuid,p_service_type text,p_items jsonb)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_items jsonb;v_count integer;
begin
 if auth.uid() is null or not coalesce(public.has_restaurant_permission(p_restaurant_id,'view_kitchen'),false) then raise exception 'Sin permiso para entrenar esta cocina' using errcode='42501';end if;
 if p_service_type is null or p_service_type not in('pickup','dine_in','delivery') then raise exception 'Servicio inválido';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Selecciona los productos de la preparación';end if;
 if jsonb_array_length(p_items) not between 1 and 50 then raise exception 'Selecciona de 1 a 50 productos';end if;
 if exists(select 1 from jsonb_array_elements(p_items) x where jsonb_typeof(x)<>'object' or coalesce(x->>'id','') !~ '^[0-9a-fA-F-]{36}$' or coalesce(x->>'qty','') !~ '^[0-9]{1,3}$' or (x->>'qty')::numeric not between 1 and 100) then raise exception 'Productos o cantidades inválidos (1 a 100)';end if;
 if (select count(distinct (x->>'id')::uuid) from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items) then raise exception 'No repitas el mismo producto';end if;
 select jsonb_agg(jsonb_build_object('id',p.id,'nombre',p.name,'qty',(x->>'qty')::integer) order by p.id),count(*) into v_items,v_count
 from jsonb_array_elements(p_items) x join public.products p on p.id=(x->>'id')::uuid and p.restaurant_id=p_restaurant_id;
 if v_count<>jsonb_array_length(p_items) then raise exception 'Hay productos que no pertenecen a este negocio';end if;
 return v_items;
end;$$;

create or replace function public.preview_kitchen_training(p_restaurant_id uuid,p_service_type text,p_items jsonb,p_is_peak boolean)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_items jsonb;
begin
 v_items:=public.validate_kitchen_training_items(p_restaurant_id,p_service_type,p_items);
 if p_is_peak is null then raise exception 'Selecciona el horario';end if;
 return public.kitchen_estimate(p_restaurant_id,p_service_type,v_items,p_is_peak);
end;$$;

create or replace function public.save_kitchen_training_sample(p_restaurant_id uuid,p_service_type text,p_items jsonb,p_prep_minutes numeric,p_is_peak boolean,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_items jsonb;v_id bigint;s public.kitchen_prep_samples%rowtype;
begin
 v_items:=public.validate_kitchen_training_items(p_restaurant_id,p_service_type,p_items);
 if p_prep_minutes is null or p_prep_minutes::text in('NaN','Infinity','-Infinity') or p_prep_minutes not between 1 and 240 or p_is_peak is null or p_request_id is null then raise exception 'Indica duración real de 1 a 240 minutos y horario';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_restaurant_id::text||':'||p_service_type,0));
 select * into s from public.kitchen_prep_samples where manual_request_id=p_request_id;
 if found then
  if s.restaurant_id<>p_restaurant_id or s.service_type<>p_service_type or s.items<>v_items or s.prep_minutes<>round(p_prep_minutes,2) or s.is_peak<>p_is_peak then raise exception 'La solicitud ya fue usada con otros datos';end if;
  return jsonb_build_object('sample_id',s.id,'duplicate',true);
 end if;
 insert into public.kitchen_prep_samples(restaurant_id,service_type,items,work_units,is_peak,prep_minutes,manual_request_id,created_by)
 values(p_restaurant_id,p_service_type,v_items,public.kitchen_work_units(v_items),p_is_peak,round(p_prep_minutes,2),p_request_id,auth.uid()) returning id into v_id;
 perform public.retrain_kitchen_model(p_restaurant_id,p_service_type);
 return jsonb_build_object('sample_id',v_id,'duplicate',false);
end;$$;

create or replace function public.train_kitchen_model(p_restaurant_id uuid,p_service_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(public.has_restaurant_permission(p_restaurant_id,'view_kitchen'),false) then raise exception 'Sin permiso para entrenar esta cocina' using errcode='42501';end if;
 if p_service_type is null or p_service_type not in('pickup','dine_in','delivery') then raise exception 'Servicio inválido';end if;
 perform public.retrain_kitchen_model(p_restaurant_id,p_service_type);
 return coalesce((select to_jsonb(m)-'restaurant_id' from public.kitchen_ml_models m where restaurant_id=p_restaurant_id and service_type=p_service_type),jsonb_build_object('sample_count',0,'model_ready',false));
end;$$;

create or replace function public.delete_kitchen_training_sample(p_sample_id bigint)
returns void language plpgsql security definer set search_path='' as $$
declare s public.kitchen_prep_samples%rowtype;
begin
 select * into s from public.kitchen_prep_samples where id=p_sample_id;
 if auth.uid() is null or not coalesce(public.has_restaurant_permission(s.restaurant_id,'view_kitchen'),false) then raise exception 'Sin permiso para modificar esta cocina' using errcode='42501';end if;
 if s.manual_request_id is null then raise exception 'Solo se pueden eliminar las mediciones manuales';end if;
 perform pg_advisory_xact_lock(hashtextextended(s.restaurant_id::text||':'||s.service_type,0));
 delete from public.kitchen_prep_samples where id=p_sample_id and manual_request_id is not null;
 perform public.retrain_kitchen_model(s.restaurant_id,s.service_type);
end;$$;

create or replace function public.get_kitchen_training_status(p_restaurant_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(public.has_restaurant_permission(p_restaurant_id,'view_kitchen'),false) then raise exception 'Sin permiso para ver esta cocina' using errcode='42501';end if;
 return jsonb_build_object('models',coalesce((select jsonb_agg(to_jsonb(m)-'restaurant_id') from public.kitchen_ml_models m where restaurant_id=p_restaurant_id),'[]'::jsonb),
 'recent_samples',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc,s.id desc) from (select id,service_type,items,prep_minutes,is_peak,created_at,(manual_request_id is not null) as manual from public.kitchen_prep_samples where restaurant_id=p_restaurant_id order by created_at desc,id desc limit 30) s),'[]'::jsonb));
end;$$;
revoke all on function public.kitchen_estimate(uuid,text,jsonb,boolean),public.validate_kitchen_training_items(uuid,text,jsonb),public.retrain_kitchen_model(uuid,text),public.predict_kitchen_minutes(bigint),public.kitchen_model_usable(bigint),public.learn_from_kitchen_ticket() from public,anon,authenticated;
revoke all on function public.preview_kitchen_training(uuid,text,jsonb,boolean),public.save_kitchen_training_sample(uuid,text,jsonb,numeric,boolean,uuid),public.train_kitchen_model(uuid,text),public.delete_kitchen_training_sample(bigint),public.get_kitchen_training_status(uuid) from public,anon;
grant execute on function public.preview_kitchen_training(uuid,text,jsonb,boolean),public.save_kitchen_training_sample(uuid,text,jsonb,numeric,boolean,uuid),public.train_kitchen_model(uuid,text),public.delete_kitchen_training_sample(bigint),public.get_kitchen_training_status(uuid) to authenticated;
