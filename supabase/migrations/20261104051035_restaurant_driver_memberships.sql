create function public.is_team_driver(p_restaurant_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.restaurant_staff s where s.user_id=auth.uid() and s.is_active and s.can_deliver_orders and (p_restaurant_id is null or s.restaurant_id=p_restaurant_id));
$$;
revoke all on function public.is_team_driver(uuid) from public,anon;
grant execute on function public.is_team_driver(uuid) to authenticated;

CREATE OR REPLACE FUNCTION public.create_staff_invite(p_staff_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_code text;v_invite public.restaurant_staff_invites%rowtype;
begin
 if p_staff_role not in('waiter','kitchen','cashier','manager','driver') then raise exception 'Rol no válido';end if;
 if not exists(select 1 from public.profiles where id=auth.uid() and role='negocio') then raise exception 'Solo el propietario puede invitar personal';end if;
 v_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
 insert into public.restaurant_staff_invites(restaurant_id,code,staff_role,created_by) values(auth.uid(),v_code,p_staff_role,auth.uid()) returning * into v_invite;
 return jsonb_build_object('code',v_invite.code,'role',v_invite.staff_role,'expires_at',v_invite.expires_at);
end; $function$;

CREATE OR REPLACE FUNCTION public.accept_staff_invite(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_invite public.restaurant_staff_invites%rowtype;v_name text;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesion';end if;
 select * into v_invite from public.restaurant_staff_invites where code=upper(trim(p_code)) and used_at is null and expires_at>now() for update;
 if not found then raise exception 'El codigo no existe, ya fue usado o vencio';end if;
 insert into public.restaurant_staff(restaurant_id,user_id,staff_role,is_active,can_create_orders,can_view_kitchen,can_close_accounts,can_manage_delivery,can_deliver_orders)
 values(v_invite.restaurant_id,auth.uid(),v_invite.staff_role,true,v_invite.staff_role in('waiter','manager'),v_invite.staff_role in('kitchen','manager'),v_invite.staff_role in('cashier','manager'),v_invite.staff_role='manager',v_invite.staff_role='driver')
 on conflict(restaurant_id,user_id) do update set staff_role=excluded.staff_role,is_active=true,can_create_orders=excluded.can_create_orders,can_view_kitchen=excluded.can_view_kitchen,can_close_accounts=excluded.can_close_accounts,can_manage_delivery=excluded.can_manage_delivery,can_deliver_orders=excluded.can_deliver_orders;
 update public.restaurant_staff_invites set used_by=auth.uid(),used_at=now() where id=v_invite.id;
 select business_name into v_name from public.profiles where id=v_invite.restaurant_id;
 if v_invite.staff_role='driver' then
   update public.delivery_drivers set status='active' where user_id=auth.uid() and status='pending_review';
 end if;
 return jsonb_build_object('restaurant_id',v_invite.restaurant_id,'business_name',v_name,'staff_role',v_invite.staff_role);
end; $function$;

CREATE OR REPLACE FUNCTION public.register_delivery_driver(p_full_name text, p_phone text, p_vehicle_type text, p_vehicle_plate text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d public.delivery_drivers%rowtype;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesion';end if;
 if not public.is_team_driver(null) then raise exception 'Necesitas una invitación como repartidor del restaurante';end if;
 if char_length(trim(coalesce(p_full_name,'')))<2 or char_length(trim(coalesce(p_phone,'')))<7 then raise exception 'Completa nombre y telefono';end if;
 if p_vehicle_type not in('motorcycle','bicycle','car','walking') then raise exception 'Vehiculo invalido';end if;
 insert into public.delivery_drivers(user_id,full_name,phone,vehicle_type,vehicle_plate,status)
 values(auth.uid(),left(trim(p_full_name),120),left(trim(p_phone),30),p_vehicle_type,nullif(left(trim(coalesce(p_vehicle_plate,'')),20),''),'active')
 on conflict(user_id) do update set status=case when delivery_drivers.status='pending_review' then 'active' else delivery_drivers.status end,full_name=excluded.full_name,phone=excluded.phone,vehicle_type=excluded.vehicle_type,vehicle_plate=excluded.vehicle_plate,updated_at=now()
 returning * into d;
 return to_jsonb(d);
end; $function$;

CREATE OR REPLACE FUNCTION public.list_delivery_offers()
 RETURNS TABLE(order_id bigint, restaurant_name text, pickup_address text, delivery_distance_km numeric, driver_earning numeric, item_count integer, delivery_status text, created_at timestamp with time zone, offer_response text, finishing_current_order boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
where public.is_team_driver(o.restaurant_id) and e.finishing and o.service_type='delivery' and o.assigned_driver_id is null
  and o.delivery_status in('accepted','preparing','ready_for_dispatch')
  and(o.payment_method='cash' or o.payment_status='approved')
order by case o.delivery_status when 'ready_for_dispatch' then 0 when 'preparing' then 1 else 2 end,o.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.claim_delivery_order(p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;d public.delivery_drivers%rowtype;
begin
  select * into d from public.delivery_drivers where user_id=auth.uid() and status='active' and is_available for update;
  if not found then raise exception 'Tu cuenta debe estar aprobada y en linea';end if;
  if exists(select 1 from public.orders where assigned_driver_id=auth.uid() and delivery_status not in('delivered','cancelled')) then
    raise exception 'Termina tu entrega activa antes de aceptar otra';
  end if;
  select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
  if not found then raise exception 'Pedido no encontrado';end if;
  if not public.is_team_driver(o.restaurant_id) then raise exception 'La entrega pertenece a otro restaurante';end if;
  if o.assigned_driver_id is not null then raise exception 'Otro repartidor ya acepto este pedido';end if;
  if o.delivery_status not in('accepted','preparing','ready_for_dispatch')
    or(o.payment_method='mercado_pago' and o.payment_status<>'approved') then raise exception 'Este pedido aun no esta disponible';end if;
  update public.orders set assigned_driver_id=auth.uid(),assigned_driver_name=d.full_name,
    assigned_at=now(),driver_claimed_at=now() where id=o.id returning * into o;
  delete from public.delivery_offer_responses where order_id=o.id;
  insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id)
  values(o.id,o.restaurant_id,o.delivery_status,'Pedido aceptado por '||d.full_name,auth.uid());
  return to_jsonb(o);
end; $function$;

CREATE OR REPLACE FUNCTION public.dismiss_delivery_offer(p_order_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not exists(select 1 from public.delivery_drivers where user_id=auth.uid() and status='active') then
    raise exception 'Cuenta de repartidor no activa';
  end if;
  if not exists(select 1 from public.orders where id=p_order_id and public.is_team_driver(restaurant_id) and service_type='delivery' and assigned_driver_id is null
    and delivery_status in('accepted','preparing','ready_for_dispatch')) then raise exception 'La oferta ya no esta disponible';end if;
  insert into public.delivery_offer_responses(driver_id,order_id,response)
  values(auth.uid(),p_order_id,'dismissed')
  on conflict(driver_id,order_id) do update set response='dismissed',updated_at=now();
end; $function$;
alter table public.delivery_marketplace_events add column restaurant_id uuid;
update public.delivery_marketplace_events e set restaurant_id=o.restaurant_id from public.orders o where o.id=e.order_id;
create function public.set_delivery_event_restaurant() returns trigger language plpgsql security definer set search_path='' as $$
begin select restaurant_id into strict new.restaurant_id from public.orders where id=new.order_id; return new; end;$$;
revoke all on function public.set_delivery_event_restaurant() from public,anon,authenticated;
create trigger set_delivery_event_restaurant before insert on public.delivery_marketplace_events for each row execute function public.set_delivery_event_restaurant();
alter table public.delivery_marketplace_events alter column restaurant_id set not null;
drop policy active_drivers_read_marketplace_events on public.delivery_marketplace_events;
create policy team_driver_delivery_events on public.delivery_marketplace_events for select to authenticated using(public.is_team_driver(restaurant_id));
create function public.team_drivers_for_push(p_restaurant_id uuid) returns table(user_id uuid) language sql stable security invoker set search_path='' as $$
 select d.user_id from public.restaurant_staff s join public.delivery_drivers d on d.user_id=s.user_id where s.restaurant_id=p_restaurant_id and s.is_active and s.can_deliver_orders and d.status='active' and d.is_available;
$$;
revoke all on function public.team_drivers_for_push(uuid) from public,anon,authenticated;
grant execute on function public.team_drivers_for_push(uuid) to service_role;
update public.delivery_drivers d set status='active' where d.status='pending_review' and exists(select 1 from public.restaurant_staff s where s.user_id=d.user_id and s.is_active and s.can_deliver_orders);

create or replace function public.set_marketplace_driver_availability(p_available boolean,p_latitude double precision default null,p_longitude double precision default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.delivery_drivers%rowtype;
begin
 if p_available and not public.is_team_driver(null) then raise exception 'Necesitas pertenecer al equipo de reparto'; end if;
 if p_latitude is not null and (p_latitude not between -90 and 90 or p_longitude not between -180 and 180) then raise exception 'Ubicacion invalida';end if;
 update public.delivery_drivers set is_available=p_available,latitude=coalesce(p_latitude,latitude),longitude=coalesce(p_longitude,longitude),last_location_at=case when p_latitude is not null then now() else last_location_at end,updated_at=now()
 where user_id=auth.uid() and status='active' returning * into d;
 if not found then raise exception 'Primero registra tu cuenta de repartidor';end if;
 return to_jsonb(d);
end; $$;
