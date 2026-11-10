alter table public.orders add column delivery_assignment_id uuid;
create or replace function public.assign_delivery_driver(p_order_id bigint,p_driver_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;d public.delivery_drivers%rowtype;n text;active_count bigint;
begin
 select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
 if not found then raise exception 'Pedido no encontrado';end if;
 if not public.has_restaurant_permission(o.restaurant_id,'close_accounts') then raise exception 'Solo caja puede asignar repartidores';end if;
 if o.status='cancelado' or o.delivery_status not in ('accepted','preparing','ready_for_dispatch') then raise exception 'Confirma el pedido antes de asignar el reparto';end if;
 if o.payment_method='mercado_pago' and o.payment_status<>'approved' then raise exception 'Espera la confirmación del pago';end if;
 if o.assigned_driver_id=p_driver_id then return to_jsonb(o);end if;
 if o.assigned_driver_id is not null then raise exception 'Libera la asignación actual antes de cambiar repartidor';end if;
 if p_driver_id is null then raise exception 'Selecciona un repartidor';end if;
 perform pg_advisory_xact_lock(hashtextextended('delivery-driver:'||p_driver_id::text,0));
 select * into d from public.delivery_drivers where user_id=p_driver_id and status='active' and is_available;
 if not found then raise exception 'El repartidor debe estar activo y disponible';end if;
 select coalesce(nullif(p.full_name,''),d.full_name) into n from public.restaurant_staff s join public.profiles p on p.id=s.user_id
 where s.restaurant_id=o.restaurant_id and s.user_id=p_driver_id and s.is_active and s.can_deliver_orders;
 if n is null then raise exception 'El repartidor no pertenece al equipo de este restaurante';end if;
 select count(*) into active_count from public.orders where assigned_driver_id=p_driver_id and id<>o.id and status<>'cancelado' and delivery_status not in ('delivered','cancelled');
 if active_count>=1 then raise exception 'El repartidor ya tiene una entrega activa';end if;
 update public.orders set assigned_driver_id=p_driver_id,assigned_driver_name=n,assigned_at=now(),delivery_assignment_id=gen_random_uuid(),driver_claimed_at=null where id=o.id returning * into o;
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,o.delivery_status,'Caja asignó la entrega a '||n,auth.uid());
 return to_jsonb(o);
end;$$;
create or replace function public.list_delivery_drivers(p_restaurant_id uuid)
returns table(user_id uuid,full_name text,is_available boolean,last_location_at timestamptz,active_orders bigint)
language sql stable security definer set search_path='' as $$
 select s.user_id,coalesce(nullif(p.full_name,''),d.full_name),d.is_available,d.last_location_at,
 (select count(*) from public.orders o where o.assigned_driver_id=s.user_id and o.status<>'cancelado' and o.delivery_status not in ('delivered','cancelled'))
 from public.restaurant_staff s join public.profiles p on p.id=s.user_id join public.delivery_drivers d on d.user_id=s.user_id and d.status='active'
 where s.restaurant_id=p_restaurant_id and s.is_active and s.can_deliver_orders and public.has_restaurant_permission(p_restaurant_id,'close_accounts') order by p.full_name;
$$;
CREATE OR REPLACE FUNCTION public.list_delivery_offers()
 RETURNS TABLE(order_id bigint, restaurant_name text, pickup_address text, delivery_distance_km numeric, driver_earning numeric, item_count integer, delivery_status text, created_at timestamp with time zone, offer_response text, finishing_current_order boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$ select null::bigint,null::text,null::text,null::numeric,null::numeric,null::integer,null::text,null::timestamptz,null::text,null::boolean where false; $function$;
create or replace function public.claim_delivery_order(p_order_id bigint) returns jsonb language plpgsql security definer set search_path='' as $$ begin raise exception 'Caja asigna los pedidos al repartidor';end;$$;
create or replace function public.dismiss_delivery_offer(p_order_id bigint) returns void language plpgsql security definer set search_path='' as $$ begin raise exception 'Los pedidos se asignan desde caja';end;$$;
CREATE OR REPLACE FUNCTION public.accept_delivery_order(p_order_id bigint, p_accept boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;
begin select * into o from public.orders where id=p_order_id and service_type='delivery' for update;if not found then raise exception 'Pedido no encontrado';end if;if not (public.has_restaurant_permission(o.restaurant_id,'manage_delivery') or public.has_restaurant_permission(o.restaurant_id,'close_accounts')) then raise exception 'Sin permiso de delivery';end if;if o.delivery_status<>'pending_acceptance' then raise exception 'El pedido ya fue revisado';end if;
 if p_accept and o.payment_method='mercado_pago' and o.payment_status<>'approved' then raise exception 'Espera la confirmacion de Mercado Pago';end if;
 update public.orders set delivery_status=case when p_accept then 'accepted' else 'cancelled' end,accepted_at=case when p_accept then now() end,status=case when p_accept then status else 'cancelado' end,cancellation_reason=case when p_accept then cancellation_reason else 'Rechazado por el restaurante' end where id=o.id returning * into o;
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,o.delivery_status,case when p_accept then 'Pedido aceptado' else 'Pedido rechazado' end,auth.uid());return to_jsonb(o);end; $function$;
CREATE OR REPLACE FUNCTION public.release_delivery_order(p_order_id bigint, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;next_status text;
begin
  select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
  if not found then raise exception 'Pedido no encontrado';end if;
  if not public.has_restaurant_permission(o.restaurant_id,'close_accounts') then raise exception 'Sin permiso';end if;
  if o.delivery_status in('delivered','cancelled') then raise exception 'El pedido ya esta cerrado';end if;
  if char_length(trim(coalesce(p_reason,'')))<4 then raise exception 'Indica el motivo';end if;
  next_status:=case when o.status='listo' then 'ready_for_dispatch' when o.status='preparando' then 'preparing' else 'accepted' end;
  update public.orders set assigned_driver_id=null,assigned_driver_name=null,assigned_at=null,delivery_assignment_id=null,driver_claimed_at=null,
    delivery_status=next_status,driver_latitude=null,driver_longitude=null,driver_location_at=null
  where id=o.id returning * into o;
  insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id)
  values(o.id,o.restaurant_id,next_status,'Entrega liberada: '||left(trim(p_reason),240),auth.uid());
  return to_jsonb(o);
end; $function$;
create function public.release_delivery_order(p_order_id bigint,p_reason text,p_expected_driver uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_driver uuid;
begin
 select assigned_driver_id into current_driver from public.orders where id=p_order_id for update;
 if not found or current_driver is distinct from p_expected_driver then raise exception 'La asignación cambió. Actualiza el pedido';end if;
 return public.release_delivery_order(p_order_id,p_reason);
end;$$;
revoke all on function public.release_delivery_order(bigint,text,uuid) from public,anon;
grant execute on function public.release_delivery_order(bigint,text,uuid) to authenticated;

create or replace function public.notify_order_transition() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' and new.customer_id is not null and new.service_type='pickup' then
  perform public.enqueue_order_notification(new.id,null,'received','received');
 end if;
 if tg_op='INSERT' and new.service_type='pickup' and new.payment_before_kitchen and new.payment_status='pending' and new.payment_method in ('cash','transfer') then
  perform public.enqueue_order_notification(new.id,null,'cashier','pending');
 end if;
 if tg_op='UPDATE' and new.payment_status is distinct from old.payment_status and new.payment_status in ('approved','refunded','rejected','expired') and new.customer_id is not null then
  perform public.enqueue_order_notification(new.id,null,'payment',new.payment_status);
 end if;
 if new.status='cancelado' and (tg_op='INSERT' or new.status is distinct from old.status) then
  perform public.enqueue_order_notification(new.id,null,'order','cancelado');
 elsif new.service_type='delivery' then
  if new.delivery_status is not null and (tg_op='INSERT' or new.delivery_status is distinct from old.delivery_status or (new.delivery_status='pending_acceptance' and new.payment_status='approved' and old.payment_status is distinct from new.payment_status)) and (new.payment_method<>'mercado_pago' or new.payment_status='approved') then
   perform public.enqueue_order_notification(new.id,null,'delivery',new.delivery_status);
  end if;
  if new.assigned_driver_id is not null and (tg_op='INSERT' or new.assigned_driver_id is distinct from old.assigned_driver_id) then
   perform public.enqueue_order_notification(new.id,null,'driver',coalesce(new.delivery_assignment_id::text,new.assigned_driver_id::text));
  end if;
 end if;
 return new;
end;$$;

drop trigger if exists publish_delivery_marketplace_event on public.orders;
