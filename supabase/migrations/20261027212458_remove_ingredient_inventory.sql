begin;
set local lock_timeout='5s';
drop trigger if exists deduct_kitchen_ticket_inventory on public.kitchen_tickets;
drop trigger if exists check_new_order_inventory on public.orders;
drop trigger if exists check_new_ticket_inventory on public.kitchen_tickets;
drop trigger if exists protect_ingredient_unit on public.ingredients;
drop trigger if exists validate_recipe_restaurant on public.product_recipes;
drop trigger if exists refresh_recipe_inventory on public.product_recipes;
drop trigger if exists refresh_ingredient_inventory on public.ingredients;
create or replace function public.list_kitchen_priority_queue(p_restaurant_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
    if not public.has_restaurant_permission(p_restaurant_id,'view_kitchen') then raise exception 'Sin permiso para ver cocina';end if;

    with base as (
        select t.*,o.scheduled_for,o.assigned_driver_id,o.driver_latitude,o.driver_longitude,o.driver_location_at,o.delivery_status,
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
$$;


create or replace view public.public_qr_products as
select id,restaurant_id,name,price,category,image_url from public.products where is_available;
-- Compatibility field for previously cached clients; it no longer controls stock.
update public.products set inventory_available=true;
drop function public.kitchen_resource_status(uuid,jsonb);
drop function public.kitchen_resource_requirements(uuid,jsonb);
drop function public.adjust_inventory(uuid,numeric,text,text);
drop function public.check_new_order_inventory();
drop function public.check_new_ticket_inventory();
drop function public.deduct_kitchen_ticket_inventory();
drop function public.deduct_order_inventory();
drop function public.refresh_recipe_inventory();
drop function public.refresh_ingredient_inventory();
drop function public.refresh_product_inventory(uuid);
drop function public.protect_ingredient_unit();
drop function public.validate_recipe_restaurant();
drop table public.inventory_movements;
drop table public.product_recipes;
drop table public.ingredients;
commit;
