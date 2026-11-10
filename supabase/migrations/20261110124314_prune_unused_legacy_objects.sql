-- Retire superseded RPCs and empty storage. Historical rows remain in their original tables.
set local lock_timeout='5s';
lock table public.delivery_driver_status,public.delivery_offer_responses,public.products in access exclusive mode;
do $$
begin
 if exists(select 1 from public.delivery_driver_status) or exists(select 1 from public.delivery_offer_responses) then
  raise exception 'Cleanup stopped: a retired table contains records';
 end if;
 if exists(select 1 from public.products where inventory_available is distinct from true) then
  raise exception 'Cleanup stopped: legacy availability contains non-default values';
 end if;
end;$$;

-- Keep the former availability endpoint compatible with installed clients.
create or replace function public.set_driver_availability(p_available boolean,p_latitude double precision default null,p_longitude double precision default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;restaurant uuid;
begin
 result:=public.set_marketplace_driver_availability(p_available,p_latitude,p_longitude);
 select restaurant_id into restaurant from public.restaurant_staff where user_id=auth.uid() and is_active and can_deliver_orders order by id limit 1;
 return result||jsonb_build_object('restaurant_id',restaurant);
end;$$;

drop trigger sync_order_station_statuses on public.orders;
drop function public.sync_order_station_statuses() restrict;
drop function public.update_kitchen_order_status(bigint,text) restrict;
drop function public.update_kitchen_station_status(bigint,text,text) restrict;
drop function public.create_order(uuid,jsonb,text) restrict;
drop function public.mark_pos_order_paid(bigint,text) restrict;
drop function public.publish_delivery_marketplace_event() restrict;
drop function public.team_drivers_for_push(uuid) restrict;

-- PL/pgSQL string bodies do not expose all dependencies through pg_depend.
do $$
begin
 if exists(select 1 from pg_proc where pronamespace='public'::regnamespace and prokind='f'
  and prosrc ~ '\m(delivery_driver_status|delivery_offer_responses|inventory_available|order_station_statuses)\M') then
  raise exception 'Cleanup stopped: a remaining function references retired storage';
 end if;
end;$$;
drop table public.delivery_driver_status restrict;
drop table public.delivery_offer_responses restrict;
alter table public.products drop column inventory_available restrict;

-- delivery_marketplace_events and order_station_statuses retain historical records.
-- Finance, kitchen prediction, notification, auth and payment-retry storage remain operational.
