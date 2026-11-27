begin;

-- Resume automatic predictions for kitchens left in the former calibration mode.
update public.profiles set kitchen_training_mode=false where kitchen_training_mode;

alter table public.kitchen_tickets add column dine_in_due_at timestamptz;

-- Existing active tickets use the configured time at deployment.
update public.kitchen_tickets t
set dine_in_due_at=t.created_at+make_interval(mins=>p.dine_in_prep_minutes)
from public.profiles p
where p.id=t.restaurant_id and t.service_type='dine_in' and t.status in ('pendiente','preparando');

create function sy_private.store_dine_in_deadline()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.service_type='dine_in' then
  select new.created_at+make_interval(mins=>p.dine_in_prep_minutes)
  into new.dine_in_due_at from public.profiles p where p.id=new.restaurant_id;
 end if;
 return new;
end;
$$;
revoke all on function sy_private.store_dine_in_deadline() from public,anon,authenticated;

create trigger kitchen_dine_in_initial_deadline
before insert on public.kitchen_tickets
for each row execute function sy_private.store_dine_in_deadline();

CREATE OR REPLACE FUNCTION public.retrain_kitchen_model(p_restaurant_id uuid, p_service_type text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare samples jsonb;training jsonb;fitted jsonb;final_fit jsonb;n integer;v_holdout integer;v_mae numeric;v_baseline numeric;v_default numeric;v_mean numeric;v_peak integer;v_off integer;v_ready boolean;v_off_min numeric;v_off_max numeric;v_peak_min numeric;v_peak_max numeric;v_products jsonb;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_restaurant_id::text||':'||p_service_type,0));
 -- Bounded recent history keeps learning cost predictable and adapts to recipe changes.
 select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at,s.id),'[]'::jsonb) into samples from
 (select id,ticket_id,work_units,prep_minutes,is_peak,created_at,items from public.kitchen_prep_samples where restaurant_id=p_restaurant_id and service_type=p_service_type
  and (ticket_id is null or exists (
    select 1 from public.kitchen_tickets t join public.orders o on o.id=t.order_id
    where t.id=public.kitchen_prep_samples.ticket_id and o.status<>'cancelado'
  ))
  order by created_at desc,id desc limit 500) s;
 n:=jsonb_array_length(samples);if n=0 then delete from public.kitchen_ml_models where restaurant_id=p_restaurant_id and service_type=p_service_type;return;end if;
 v_holdout:=case when n>=10 then greatest(2,floor(n*.2)::integer) else 0 end;
 select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into training from jsonb_array_elements(samples) with ordinality where ordinality<=n-v_holdout;
 fitted:=public.fit_kitchen_samples(training);final_fit:=public.fit_kitchen_samples(samples);
 select count(*) filter(where (x->>'is_peak')::boolean),count(*) filter(where not (x->>'is_peak')::boolean),avg((x->>'prep_minutes')::numeric) into v_peak,v_off,v_mean from jsonb_array_elements(samples) x;
 select case p_service_type when 'delivery' then delivery_prep_minutes when 'dine_in' then dine_in_prep_minutes else pickup_prep_minutes end
 into v_default from public.profiles where id=p_restaurant_id;
 if v_holdout>0 then
  select avg(abs((value->>'prep_minutes')::numeric - greatest(5,least(240,(fitted->>'intercept')::numeric+(fitted->>'per_work_unit')::numeric*(value->>'work_units')::numeric+case when (value->>'is_peak')::boolean then (fitted->>'peak_adjustment')::numeric else 0 end)))),
         avg(abs((value->>'prep_minutes')::numeric - greatest(5,least(240,coalesce(v_default,20)))))
  into v_mae,v_baseline from jsonb_array_elements(samples) with ordinality where ordinality>n-v_holdout;
 end if;
 select min((x->>'work_units')::numeric) filter(where not (x->>'is_peak')::boolean),max((x->>'work_units')::numeric) filter(where not (x->>'is_peak')::boolean),min((x->>'work_units')::numeric) filter(where (x->>'is_peak')::boolean),max((x->>'work_units')::numeric) filter(where (x->>'is_peak')::boolean)
 into v_off_min,v_off_max,v_peak_min,v_peak_max from jsonb_array_elements(samples) x;
 select coalesce(jsonb_agg(distinct item->>'id'),'[]'::jsonb) into v_products from jsonb_array_elements(samples) s cross join lateral jsonb_array_elements(s->'items') item;
 v_ready:=n>=10 and v_mae is not null and v_mae<=greatest(5,v_mean*.35) and v_mae<=v_baseline;
 insert into public.kitchen_ml_models(restaurant_id,service_type,sample_count,intercept,per_work_unit,peak_adjustment,mean_absolute_error,trained_at,training_sample_count,validation_sample_count,peak_sample_count,off_peak_sample_count,model_ready,off_peak_work_min,off_peak_work_max,peak_work_min,peak_work_max,trained_products)
 values(p_restaurant_id,p_service_type,n,(final_fit->>'intercept')::numeric,(final_fit->>'per_work_unit')::numeric,(final_fit->>'peak_adjustment')::numeric,v_mae,now(),n-v_holdout,v_holdout,v_peak,v_off,v_ready,v_off_min,v_off_max,v_peak_min,v_peak_max,v_products)
 on conflict(restaurant_id,service_type) do update set sample_count=excluded.sample_count,intercept=excluded.intercept,per_work_unit=excluded.per_work_unit,peak_adjustment=excluded.peak_adjustment,mean_absolute_error=excluded.mean_absolute_error,trained_at=excluded.trained_at,training_sample_count=excluded.training_sample_count,validation_sample_count=excluded.validation_sample_count,peak_sample_count=excluded.peak_sample_count,off_peak_sample_count=excluded.off_peak_sample_count,model_ready=excluded.model_ready,off_peak_work_min=excluded.off_peak_work_min,off_peak_work_max=excluded.off_peak_work_max,peak_work_min=excluded.peak_work_min,peak_work_max=excluded.peak_work_max,trained_products=excluded.trained_products;
end;$function$
;

CREATE OR REPLACE FUNCTION public.list_kitchen_priority_queue(p_restaurant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb;
begin
    if not public.has_restaurant_permission(p_restaurant_id,'view_kitchen') then raise exception 'Sin permiso para ver cocina';end if;

    with base as (
        select t.*,o.pickup_name,o.pickup_tracking_enabled,o.pickup_arrival_at,o.pickup_location_at,o.scheduled_for,o.assigned_driver_id,o.driver_latitude,o.driver_longitude,o.driver_location_at,o.delivery_status,
               p.latitude as restaurant_latitude,p.longitude as restaurant_longitude,p.pickup_prep_minutes,p.dine_in_prep_minutes,p.delivery_prep_minutes,
               d.vehicle_type,m.sample_count,coalesce(t.prediction_error_minutes,m.mean_absolute_error) as mean_absolute_error,m.validation_sample_count,
               case when t.predicted_prep_minutes is not null then coalesce(t.prediction_source,'configured_time')='validated_model' else public.kitchen_model_usable(t.id) end as usable_model,
               coalesce(t.predicted_prep_minutes,public.predict_kitchen_minutes(t.id)) as predicted_minutes,
               coalesce((select jsonb_agg(to_jsonb(s)) from public.kitchen_ticket_station_statuses s where s.ticket_id=t.id),'[]'::jsonb) as station_statuses
        from public.kitchen_tickets t
        join public.orders o on o.id=t.order_id
        join public.profiles p on p.id=t.restaurant_id
        left join public.delivery_drivers d on d.user_id=o.assigned_driver_id
        left join public.kitchen_ml_models m on m.restaurant_id=t.restaurant_id and m.service_type=t.service_type
        where t.restaurant_id=p_restaurant_id and t.status in('pendiente','preparando') and o.status<>'cancelado' and (o.payment_method<>'mercado_pago' or o.payment_status='approved')
    ), eta as (
        select b.*,
            case when b.service_type='pickup' and b.scheduled_for is not null and b.pickup_tracking_enabled and b.pickup_location_at>now()-interval '3 minutes' and b.pickup_arrival_at is not null then greatest(0,ceil(extract(epoch from(b.pickup_arrival_at-now()))/60))::integer else null end as pickup_eta_minutes,
            case when b.service_type='delivery' and b.assigned_driver_id is not null
                       and b.driver_latitude is not null and b.driver_longitude is not null
                       and b.restaurant_latitude is not null and b.restaurant_longitude is not null
                       and b.driver_location_at>now()-interval '3 minutes'
                then greatest(1,ceil(
                    (6371*acos(greatest(-1,least(1,
                        cos(radians(b.driver_latitude))*cos(radians(b.restaurant_latitude))*cos(radians(b.restaurant_longitude)-radians(b.driver_longitude))+
                        sin(radians(b.driver_latitude))*sin(radians(b.restaurant_latitude))
                    )))) / case b.vehicle_type when 'walking' then 5 when 'bicycle' then 15 else 25 end * 60
                ))::integer
                else null end as driver_eta_minutes
        from base b
    ), targets as (
        select e.*,
            case
                when service_type='pickup' and pickup_eta_minutes is not null then greatest(now(),pickup_arrival_at)
                when service_type='delivery' and driver_eta_minutes is not null then now()+make_interval(mins=>driver_eta_minutes)
                when service_type='dine_in' then coalesce(dine_in_due_at,created_at+make_interval(mins=>dine_in_prep_minutes))
                when scheduled_for is not null then scheduled_for
                when service_type='delivery' then created_at+make_interval(mins=>delivery_prep_minutes)
                else created_at+make_interval(mins=>pickup_prep_minutes)
            end as target_ready_at
        from eta e
    ), ranked as (
        select x.*,
            x.target_ready_at-make_interval(secs=>round(x.predicted_minutes*60)::integer) as recommended_start_at,
            extract(epoch from (now()-(x.target_ready_at-make_interval(secs=>round(x.predicted_minutes*60)::integer))))/60*10
                + extract(epoch from (now()-x.created_at))/60*0.5 as priority_score
        from targets x
    ), ordered as (
        select r.*,
            case when service_type='dine_in' and status='pendiente' then
                min(recommended_start_at) over (
                    partition by service_type,status order by created_at,id
                    rows between current row and unbounded following
                ) - interval '3 minutes'
            else recommended_start_at end as queue_start_at
        from ranked r
    )
    select coalesce(jsonb_agg(
        to_jsonb(r)-'restaurant_latitude'-'restaurant_longitude'-'pickup_prep_minutes'-'dine_in_prep_minutes'-'delivery_prep_minutes'-'vehicle_type'-'driver_latitude'-'driver_longitude'-'driver_location_at'
        || jsonb_build_object(
            'kitchen_ticket_station_statuses',r.station_statuses,
            'priority_override',0,
            'predicted_prep_minutes',round(r.predicted_minutes),
            'priority_reason',case
                when r.service_type='delivery' and r.driver_eta_minutes is not null then 'Repartidor llega en '||r.driver_eta_minutes||' min'
                when r.service_type='pickup' and r.pickup_eta_minutes is not null then case when r.pickup_eta_minutes=0 then 'Cliente en el restaurante' else 'Cliente llega en aproximadamente '||r.pickup_eta_minutes||' min' end
                when r.service_type='pickup' and r.scheduled_for is not null then 'Recogida programada'
                when r.service_type='delivery' then 'Delivery en espera de repartidor'
                when r.service_type='dine_in' then 'Servicio en mesa'
                else 'Recogida lo antes posible'
            end,
            'model_ready',r.usable_model,
            'can_start',true,
            'minimum_samples',10,
            'prediction_source',case when r.usable_model then 'validated_model' else 'configured_time' end
        ) order by case r.status when 'preparando' then 0 else 1 end,r.queue_start_at,r.created_at,r.id
    ),'[]'::jsonb) into v_result
    from ordered r;
    return v_result;
end;
$function$;

do $$
declare model record;
begin
 for model in select restaurant_id,service_type from public.kitchen_ml_models order by restaurant_id,service_type loop
  perform public.retrain_kitchen_model(model.restaurant_id,model.service_type);
 end loop;
end;
$$;

commit;
