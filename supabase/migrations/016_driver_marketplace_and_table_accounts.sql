-- Marketplace independiente de repartidores y cuentas multiples por mesa.
-- Ejecutar despues de 015_delivery_suite.sql.

begin;

create table if not exists public.platform_delivery_settings (
    id boolean primary key default true check (id),
    driver_base_pay numeric(12,2) not null default 25 check (driver_base_pay >= 0),
    driver_pay_per_km numeric(12,2) not null default 5 check (driver_pay_per_km >= 0),
    max_active_orders integer not null default 2 check (max_active_orders between 1 and 10),
    updated_at timestamptz not null default now()
);
insert into public.platform_delivery_settings(id) values(true) on conflict(id) do nothing;

create or replace function public.create_staff_invite(p_staff_role text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_code text;v_invite public.restaurant_staff_invites%rowtype;
begin
 if p_staff_role not in('waiter','kitchen','cashier','manager') then raise exception 'Los repartidores se registran directamente en ServeYourself';end if;
 if not exists(select 1 from public.profiles where id=auth.uid() and role='negocio') then raise exception 'Solo el propietario puede invitar personal';end if;
 v_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
 insert into public.restaurant_staff_invites(restaurant_id,code,staff_role,created_by) values(auth.uid(),v_code,p_staff_role,auth.uid()) returning * into v_invite;
 return jsonb_build_object('code',v_invite.code,'role',v_invite.staff_role,'expires_at',v_invite.expires_at);
end; $$;

create table if not exists public.delivery_drivers (
    user_id uuid primary key references auth.users(id) on delete cascade,
    full_name text not null check (char_length(full_name) between 2 and 120),
    phone text not null check (char_length(phone) between 7 and 30),
    vehicle_type text not null check (vehicle_type in ('motorcycle','bicycle','car','walking')),
    vehicle_plate text,
    status text not null default 'active' check (status in ('active','suspended')),
    is_available boolean not null default false,
    latitude double precision,
    longitude double precision,
    last_location_at timestamptz,
    rating numeric(3,2) not null default 5 check (rating between 0 and 5),
    completed_deliveries integer not null default 0,
    total_earnings numeric(14,2) not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
alter table public.delivery_drivers enable row level security;
drop policy if exists "delivery_drivers_own" on public.delivery_drivers;
create policy "delivery_drivers_own" on public.delivery_drivers for select to authenticated using(user_id=auth.uid());

alter table public.orders
    add column if not exists driver_earning numeric(12,2) not null default 0,
    add column if not exists driver_claimed_at timestamptz;

create or replace function public.calculate_driver_earning(p_distance numeric)
returns numeric language sql stable security definer set search_path='' as $$
select round(s.driver_base_pay + greatest(coalesce(p_distance,0),0) * s.driver_pay_per_km,2)
from public.platform_delivery_settings s where s.id=true;
$$;

update public.orders
set driver_earning=public.calculate_driver_earning(delivery_distance_km)
where service_type='delivery' and driver_earning=0;

create or replace function public.set_delivery_driver_earning()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.service_type='delivery' and coalesce(new.driver_earning,0)=0 then
   new.driver_earning:=public.calculate_driver_earning(new.delivery_distance_km);
 end if;
 return new;
end; $$;
drop trigger if exists set_delivery_driver_earning on public.orders;
create trigger set_delivery_driver_earning before insert or update of delivery_distance_km on public.orders
for each row execute function public.set_delivery_driver_earning();

create or replace function public.register_delivery_driver(p_full_name text,p_phone text,p_vehicle_type text,p_vehicle_plate text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.delivery_drivers%rowtype;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesion';end if;
 if char_length(trim(coalesce(p_full_name,'')))<2 or char_length(trim(coalesce(p_phone,'')))<7 then raise exception 'Completa nombre y telefono';end if;
 if p_vehicle_type not in('motorcycle','bicycle','car','walking') then raise exception 'Vehiculo invalido';end if;
 insert into public.delivery_drivers(user_id,full_name,phone,vehicle_type,vehicle_plate)
 values(auth.uid(),left(trim(p_full_name),120),left(trim(p_phone),30),p_vehicle_type,nullif(left(trim(coalesce(p_vehicle_plate,'')),20),''))
 on conflict(user_id) do update set full_name=excluded.full_name,phone=excluded.phone,vehicle_type=excluded.vehicle_type,vehicle_plate=excluded.vehicle_plate,updated_at=now()
 returning * into d;
 return to_jsonb(d);
end; $$;

create or replace function public.get_delivery_driver_profile()
returns jsonb language sql stable security definer set search_path='' as $$
select to_jsonb(d) from public.delivery_drivers d where d.user_id=auth.uid();
$$;

create or replace function public.set_marketplace_driver_availability(p_available boolean,p_latitude double precision default null,p_longitude double precision default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.delivery_drivers%rowtype;
begin
 if p_latitude is not null and (p_latitude not between -90 and 90 or p_longitude not between -180 and 180) then raise exception 'Ubicacion invalida';end if;
 update public.delivery_drivers set is_available=p_available,latitude=coalesce(p_latitude,latitude),longitude=coalesce(p_longitude,longitude),last_location_at=case when p_latitude is not null then now() else last_location_at end,updated_at=now()
 where user_id=auth.uid() and status='active' returning * into d;
 if not found then raise exception 'Primero registra tu cuenta de repartidor';end if;
 return to_jsonb(d);
end; $$;

create or replace function public.list_delivery_offers()
returns table(order_id bigint,restaurant_name text,pickup_address text,delivery_distance_km numeric,driver_earning numeric,item_count integer,delivery_status text,created_at timestamptz)
language sql stable security definer set search_path='' as $$
select o.id,o.restaurant_name,p.address,o.delivery_distance_km,o.driver_earning,
       coalesce(jsonb_array_length(o.items),0),o.delivery_status,o.created_at
from public.orders o join public.profiles p on p.id=o.restaurant_id
where exists(select 1 from public.delivery_drivers d where d.user_id=auth.uid() and d.status='active' and d.is_available)
  and o.service_type='delivery' and o.assigned_driver_id is null
  and o.delivery_status in('accepted','preparing','ready_for_dispatch')
  and (o.payment_method='cash' or o.payment_status='approved')
order by case o.delivery_status when 'ready_for_dispatch' then 0 when 'preparing' then 1 else 2 end,o.created_at;
$$;

create or replace function public.claim_delivery_order(p_order_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;d public.delivery_drivers%rowtype;lim integer;
begin
 select * into d from public.delivery_drivers where user_id=auth.uid() and status='active' and is_available for update;
 if not found then raise exception 'Conectate como repartidor antes de aceptar pedidos';end if;
 select max_active_orders into lim from public.platform_delivery_settings where id=true;
 if (select count(*) from public.orders where assigned_driver_id=auth.uid() and delivery_status not in('delivered','cancelled'))>=lim then raise exception 'Ya alcanzaste el maximo de entregas activas';end if;
 select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
 if not found then raise exception 'Pedido no encontrado';end if;
 if o.assigned_driver_id is not null then raise exception 'Otro repartidor ya acepto este pedido';end if;
 if o.delivery_status not in('accepted','preparing','ready_for_dispatch') or (o.payment_method='mercado_pago' and o.payment_status<>'approved') then raise exception 'Este pedido aun no esta disponible';end if;
 update public.orders set assigned_driver_id=auth.uid(),assigned_driver_name=d.full_name,assigned_at=now(),driver_claimed_at=now() where id=o.id returning * into o;
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,o.delivery_status,'Pedido aceptado por '||d.full_name,auth.uid());
 return to_jsonb(o);
end; $$;

create or replace function public.advance_delivery_order(p_order_id bigint,p_status text,p_latitude double precision default null,p_longitude double precision default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
 if not found then raise exception 'Pedido no encontrado';end if;
 if o.assigned_driver_id is distinct from auth.uid() or not exists(select 1 from public.delivery_drivers where user_id=auth.uid() and status='active') then raise exception 'Pedido no asignado a tu cuenta';end if;
 if not ((o.delivery_status='ready_for_dispatch' and p_status='picked_up') or (o.delivery_status='picked_up' and p_status='on_the_way') or (o.delivery_status='on_the_way' and p_status='arrived')) then raise exception 'Cambio de estado invalido';end if;
 update public.orders set delivery_status=p_status,picked_up_at=case when p_status='picked_up' then now() else picked_up_at end,arrived_at=case when p_status='arrived' then now() else arrived_at end,driver_latitude=coalesce(p_latitude,driver_latitude),driver_longitude=coalesce(p_longitude,driver_longitude),driver_location_at=case when p_latitude is not null then now() else driver_location_at end where id=o.id returning * into o;
 update public.delivery_drivers set latitude=coalesce(p_latitude,latitude),longitude=coalesce(p_longitude,longitude),last_location_at=case when p_latitude is not null then now() else last_location_at end,updated_at=now() where user_id=auth.uid();
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,p_status,case p_status when 'picked_up' then 'El repartidor recogio el pedido' when 'on_the_way' then 'Pedido en camino' else 'El repartidor llego' end,auth.uid());
 return to_jsonb(o);
end; $$;

create or replace function public.update_delivery_location(p_order_id bigint,p_latitude double precision,p_longitude double precision)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.orders where id=p_order_id and assigned_driver_id=auth.uid() and delivery_status in('picked_up','on_the_way','arrived')) then raise exception 'Pedido no asignado';end if;
 if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Ubicacion invalida';end if;
 update public.orders set driver_latitude=p_latitude,driver_longitude=p_longitude,driver_location_at=now() where id=p_order_id;
 update public.delivery_drivers set latitude=p_latitude,longitude=p_longitude,last_location_at=now(),updated_at=now() where user_id=auth.uid();
end; $$;

create or replace function public.confirm_delivery(p_order_id bigint,p_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
 if not found then raise exception 'Pedido no encontrado';end if;
 if o.assigned_driver_id is distinct from auth.uid() then raise exception 'Pedido no asignado';end if;
 if o.delivery_status not in('on_the_way','arrived') then raise exception 'Marca primero la llegada';end if;
 if trim(p_code)<>o.delivery_code then raise exception 'Codigo de entrega incorrecto';end if;
 if o.payment_method='cash' and not exists(select 1 from public.order_payments where order_id=o.id) then insert into public.order_payments(order_id,restaurant_id,shift_id,payment_method,amount,tip_amount,received_by) values(o.id,o.restaurant_id,null,'cash',o.total,0,auth.uid());end if;
 update public.orders set delivery_status='delivered',status='entregado',delivered_at=now(),payment_status=case when payment_method='cash' then 'approved' else payment_status end where id=o.id returning * into o;
 update public.delivery_drivers set is_available=true,completed_deliveries=completed_deliveries+1,total_earnings=total_earnings+o.driver_earning,updated_at=now() where user_id=auth.uid();
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,'delivered','Pedido entregado',auth.uid());
 return to_jsonb(o);
end; $$;

create or replace function public.create_pos_table_order(p_restaurant_id uuid,p_items jsonb,p_notes text,p_service_type text,p_table_id bigint,p_payment_method text,p_existing_order_id bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o jsonb;existing public.orders%rowtype;
begin
 if not public.has_restaurant_permission(p_restaurant_id,'create_orders') then raise exception 'Sin permiso para crear comandas';end if;
 if p_existing_order_id is not null then
   select * into existing from public.orders where id=p_existing_order_id for update;
   if not found or existing.restaurant_id<>p_restaurant_id or existing.service_type<>'dine_in' or existing.table_id is distinct from p_table_id or existing.payment_status<>'pending' or existing.status='cancelado' then raise exception 'La cuenta seleccionada ya no esta abierta';end if;
   o:=public.append_pos_order_items(p_existing_order_id,p_items,p_notes);
   return o||jsonb_build_object('was_appended',true);
 end if;
 o:=public.create_pos_order(p_restaurant_id,p_items,p_notes,p_service_type,p_table_id,p_payment_method);
 perform public.create_kitchen_ticket((o->>'id')::bigint,p_items,p_notes);
 return o||jsonb_build_object('was_appended',false);
end; $$;

grant select on public.delivery_drivers to authenticated;
revoke all on function public.calculate_driver_earning(numeric),public.register_delivery_driver(text,text,text,text),public.get_delivery_driver_profile(),public.set_marketplace_driver_availability(boolean,double precision,double precision),public.list_delivery_offers(),public.claim_delivery_order(bigint),public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint) from public,anon;
grant execute on function public.register_delivery_driver(text,text,text,text),public.get_delivery_driver_profile(),public.set_marketplace_driver_availability(boolean,double precision,double precision),public.list_delivery_offers(),public.claim_delivery_order(bigint),public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint) to authenticated;

commit;
