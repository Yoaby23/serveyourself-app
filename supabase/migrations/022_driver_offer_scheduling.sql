-- Anticipa la siguiente solicitud cuando la entrega activa esta por terminar.
-- Mantiene la regla estricta de una sola entrega aceptada por repartidor.
-- Ejecutar despues de 021_production_readiness.sql.

begin;

drop function if exists public.list_delivery_offers();
create function public.list_delivery_offers()
returns table(order_id bigint,restaurant_name text,pickup_address text,delivery_distance_km numeric,
  driver_earning numeric,item_count integer,delivery_status text,created_at timestamptz,
  offer_response text,finishing_current_order boolean)
language sql stable security definer set search_path='' as $$
with driver as(
  select d.*,
    case d.vehicle_type
      when 'walking' then 5::numeric
      when 'bicycle' then 15::numeric
      else 25::numeric
    end as estimated_speed_kmh
  from public.delivery_drivers d
  where d.user_id=auth.uid() and d.status='active' and d.is_available
), active as(
  select o.*,
    case when o.driver_latitude is not null and o.driver_longitude is not null
      and o.delivery_latitude is not null and o.delivery_longitude is not null then
      6371*2*asin(sqrt(power(sin(radians(o.delivery_latitude-o.driver_latitude)/2),2)+
      cos(radians(o.driver_latitude))*cos(radians(o.delivery_latitude))*
      power(sin(radians(o.delivery_longitude-o.driver_longitude)/2),2))) else null end remaining_km,
    d.estimated_speed_kmh
  from public.orders o cross join driver d
  where o.assigned_driver_id=auth.uid()
    and o.delivery_status not in('delivered','cancelled')
), eligibility as(
  select not exists(select 1 from active)
    or exists(
      select 1 from active
      where delivery_status='arrived'
        or (
          delivery_status='on_the_way'
          and remaining_km is not null
          and (
            remaining_km<=2.5
            or ceil((remaining_km/nullif(estimated_speed_kmh,0))*60)<=8
          )
        )
    ) finishing
)
select o.id,o.restaurant_name,p.address,o.delivery_distance_km,o.driver_earning,
  coalesce(jsonb_array_length(o.items),0),o.delivery_status,o.created_at,r.response,e.finishing
from public.orders o join public.profiles p on p.id=o.restaurant_id
cross join driver d cross join eligibility e
left join public.delivery_offer_responses r on r.driver_id=auth.uid() and r.order_id=o.id
where e.finishing and o.service_type='delivery' and o.assigned_driver_id is null
  and o.delivery_status in('accepted','preparing','ready_for_dispatch')
  and(o.payment_method='cash' or o.payment_status='approved')
order by case o.delivery_status when 'ready_for_dispatch' then 0 when 'preparing' then 1 else 2 end,o.created_at;
$$;

revoke all on function public.list_delivery_offers() from public,anon;
grant execute on function public.list_delivery_offers() to authenticated;

commit;
