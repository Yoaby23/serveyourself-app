alter table public.orders add column pickup_tracking_enabled boolean not null default false,
 add column pickup_customer_latitude double precision,
 add column pickup_customer_longitude double precision,
 add column pickup_location_accuracy double precision,
 add column pickup_location_at timestamptz,
 add column pickup_arrival_at timestamptz,
 add column pickup_transport text not null default 'car' check(pickup_transport in('car','walking','bicycle'));

create or replace function public.guard_pickup_location()
returns trigger language plpgsql set search_path='' as $$
begin
 if row(new.pickup_tracking_enabled,new.pickup_customer_latitude,new.pickup_customer_longitude,new.pickup_location_accuracy,new.pickup_location_at,new.pickup_arrival_at,new.pickup_transport)
 is distinct from row(old.pickup_tracking_enabled,old.pickup_customer_latitude,old.pickup_customer_longitude,old.pickup_location_accuracy,old.pickup_location_at,old.pickup_arrival_at,old.pickup_transport)
 and current_user not in('postgres','service_role','supabase_admin') then raise exception 'Usa la función segura para compartir tu llegada' using errcode='42501';end if;
 if new.status in('entregado','cancelado') or not new.pickup_tracking_enabled then
  new.pickup_tracking_enabled:=false;new.pickup_customer_latitude:=null;new.pickup_customer_longitude:=null;new.pickup_location_accuracy:=null;new.pickup_location_at:=null;new.pickup_arrival_at:=null;
 end if;
 return new;
end;$$;
create trigger guard_pickup_location before update on public.orders for each row execute function public.guard_pickup_location();

create or replace function public.set_pickup_location_sharing(p_order_id bigint,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
 if auth.uid() is null then raise exception 'Inicia sesión' using errcode='42501';end if;
 select * into o from public.orders where id=p_order_id and customer_id=auth.uid() for update;
 if not found then raise exception 'Pedido no disponible' using errcode='42501';end if;
 if p_enabled is null or o.service_type<>'pickup' or o.scheduled_for is null then raise exception 'Esta opción es para pickup programado';end if;
 if p_enabled and (o.status in('cancelado','entregado') or o.payment_status<>'approved') then raise exception 'El pickup debe estar pagado y activo para compartir la llegada';end if;
 update public.orders set pickup_tracking_enabled=p_enabled where id=o.id;
 return jsonb_build_object('enabled',p_enabled);
end;$$;

create or replace function public.update_pickup_arrival(p_order_id bigint,p_latitude double precision,p_longitude double precision,p_accuracy double precision,p_observed_at timestamptz,p_transport text default 'car')
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;r public.profiles%rowtype;v_km double precision;v_minutes integer;v_arrival timestamptz;
begin
 if auth.uid() is null then raise exception 'Inicia sesión' using errcode='42501';end if;
 select * into o from public.orders where id=p_order_id and customer_id=auth.uid() for update;
 if not found then raise exception 'Pedido no disponible' using errcode='42501';end if;
 if not o.pickup_tracking_enabled or o.service_type<>'pickup' or o.scheduled_for is null or o.payment_status<>'approved' or o.status in('cancelado','entregado') then raise exception 'Este pickup no tiene seguimiento activo';end if;
 if p_latitude is null or p_longitude is null or p_accuracy is null or not(p_latitude between -90 and 90) or not(p_longitude between -180 and 180) or not(p_accuracy between 0 and 100) then raise exception 'Se requiere una ubicación precisa (hasta 100 metros)';end if;
 if p_observed_at is null or p_observed_at<now()-interval '2 minutes' or p_observed_at>now()+interval '30 seconds' then raise exception 'La ubicación está desactualizada';end if;
 if p_transport is null or p_transport not in('car','walking','bicycle') then raise exception 'Medio de transporte inválido';end if;
 select * into r from public.profiles where id=o.restaurant_id;
 if r.latitude is null or r.longitude is null then raise exception 'El negocio aún no tiene una ubicación para calcular tu llegada';end if;
 v_km:=6371*acos(greatest(-1,least(1,cos(radians(p_latitude))*cos(radians(r.latitude))*cos(radians(r.longitude)-radians(p_longitude))+sin(radians(p_latitude))*sin(radians(r.latitude)))));
 if v_km>150 then raise exception 'Estás demasiado lejos para calcular una llegada fiable';end if;
 -- Approximate travel, not a promise: road factor and a two-minute arrival buffer.
 v_minutes:=case when v_km<=.1 then 0 else ceil(v_km*1.3/(case p_transport when 'walking' then 5 when 'bicycle' then 15 else 25 end)*60)::integer+2 end;
 v_arrival:=p_observed_at+make_interval(mins=>v_minutes);
 -- Ignore delayed responses: an older fix must never replace a newer position.
 if o.pickup_location_at is null or p_observed_at>=o.pickup_location_at then
  update public.orders set pickup_customer_latitude=p_latitude,pickup_customer_longitude=p_longitude,pickup_location_accuracy=p_accuracy,pickup_location_at=p_observed_at,pickup_arrival_at=v_arrival,pickup_transport=p_transport where id=o.id;
 else v_arrival:=o.pickup_arrival_at;v_minutes:=greatest(0,ceil(extract(epoch from(v_arrival-now()))/60)::integer);end if;
 return jsonb_build_object('eta_minutes',v_minutes,'arrival_at',v_arrival,'approximate',true);
end;$$;
revoke all on function public.guard_pickup_location() from public,anon,authenticated;
revoke all on function public.set_pickup_location_sharing(bigint,boolean),public.update_pickup_arrival(bigint,double precision,double precision,double precision,timestamptz,text) from public,anon;
grant execute on function public.set_pickup_location_sharing(bigint,boolean),public.update_pickup_arrival(bigint,double precision,double precision,double precision,timestamptz,text) to authenticated;
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
                when scheduled_for is not null then scheduled_for
                when service_type='delivery' then created_at+make_interval(mins=>delivery_prep_minutes)
                when service_type='dine_in' then created_at+make_interval(mins=>dine_in_prep_minutes)
                else created_at+make_interval(mins=>pickup_prep_minutes)
            end as target_ready_at
        from eta e
    ), ranked as (
        select x.*,
            x.target_ready_at-make_interval(secs=>round(x.predicted_minutes*60)::integer) as recommended_start_at,
            extract(epoch from (now()-(x.target_ready_at-make_interval(secs=>round(x.predicted_minutes*60)::integer))))/60*10
                + extract(epoch from (now()-x.created_at))/60*0.5 as priority_score
        from targets x
    )
    select coalesce(jsonb_agg(
        to_jsonb(r)-'restaurant_latitude'-'restaurant_longitude'-'pickup_prep_minutes'-'dine_in_prep_minutes'-'delivery_prep_minutes'-'vehicle_type'-'driver_latitude'-'driver_longitude'-'driver_location_at'
        || jsonb_build_object(
            'kitchen_ticket_station_statuses',r.station_statuses,
            'predicted_prep_minutes',round(r.predicted_minutes),
            'priority_reason',case
                when r.priority_override=2 then 'Urgente por cocina'
                when r.priority_override=1 then 'Prioridad alta manual'
                when r.priority_override=-1 then 'Pospuesto por cocina'
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
        ) order by case r.status when 'preparando' then 0 else 1 end,r.priority_override desc,r.recommended_start_at,r.created_at,r.id
    ),'[]'::jsonb) into v_result
    from ranked r;
    return v_result;
end;
$function$;
