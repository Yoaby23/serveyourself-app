-- Suite de delivery: cobertura, tarifas, despacho, repartidores y seguimiento.
-- Ejecutar despues de 014_independent_kitchen_tickets.sql.

begin;

alter table public.profiles
    add column if not exists delivery_enabled boolean not null default false,
    add column if not exists delivery_radius_km numeric(6,2) not null default 5,
    add column if not exists delivery_base_fee numeric(12,2) not null default 0,
    add column if not exists delivery_fee_per_km numeric(12,2) not null default 0,
    add column if not exists delivery_free_over numeric(12,2),
    add column if not exists delivery_minimum numeric(12,2) not null default 0,
    add column if not exists delivery_prep_minutes integer not null default 30;

alter table public.profiles drop constraint if exists profiles_delivery_settings_check;
alter table public.profiles add constraint profiles_delivery_settings_check check (
    delivery_radius_km between 0.5 and 50 and delivery_base_fee >= 0
    and delivery_fee_per_km >= 0 and coalesce(delivery_free_over, 0) >= 0
    and delivery_minimum >= 0 and delivery_prep_minutes between 5 and 240
);

alter table public.orders
    add column if not exists subtotal numeric(12,2),
    add column if not exists delivery_fee numeric(12,2) not null default 0,
    add column if not exists delivery_distance_km numeric(8,2),
    add column if not exists delivery_address text,
    add column if not exists delivery_reference text,
    add column if not exists delivery_latitude double precision,
    add column if not exists delivery_longitude double precision,
    add column if not exists delivery_contact_name text,
    add column if not exists delivery_contact_phone text,
    add column if not exists scheduled_for timestamptz,
    add column if not exists delivery_status text,
    add column if not exists assigned_driver_id uuid references auth.users(id) on delete set null,
    add column if not exists assigned_driver_name text,
    add column if not exists delivery_code text,
    add column if not exists accepted_at timestamptz,
    add column if not exists assigned_at timestamptz,
    add column if not exists picked_up_at timestamptz,
    add column if not exists arrived_at timestamptz,
    add column if not exists driver_latitude double precision,
    add column if not exists driver_longitude double precision,
    add column if not exists driver_location_at timestamptz;

update public.orders set subtotal=total-delivery_fee where subtotal is null;
alter table public.orders drop constraint if exists orders_delivery_status_check;
alter table public.orders add constraint orders_delivery_status_check check (
    delivery_status is null or delivery_status in (
        'pending_acceptance','accepted','preparing','ready_for_dispatch',
        'picked_up','on_the_way','arrived','delivered','cancelled'
    )
);
alter table public.orders drop constraint if exists orders_service_type_check;
alter table public.orders add constraint orders_service_type_check check (service_type in ('pickup','dine_in','delivery'));

alter table public.kitchen_tickets drop constraint if exists kitchen_tickets_service_type_check;
alter table public.kitchen_tickets add constraint kitchen_tickets_service_type_check check (service_type in ('pickup','dine_in','delivery'));

alter table public.restaurant_staff
    add column if not exists can_manage_delivery boolean not null default false,
    add column if not exists can_deliver_orders boolean not null default false;
alter table public.restaurant_staff drop constraint if exists restaurant_staff_staff_role_check;
alter table public.restaurant_staff add constraint restaurant_staff_staff_role_check
    check (staff_role in ('waiter','kitchen','cashier','manager','driver'));
alter table public.restaurant_staff_invites drop constraint if exists restaurant_staff_invites_staff_role_check;
alter table public.restaurant_staff_invites add constraint restaurant_staff_invites_staff_role_check
    check (staff_role in ('waiter','kitchen','cashier','manager','driver'));
update public.restaurant_staff set
    can_manage_delivery=staff_role='manager',
    can_deliver_orders=staff_role='driver';

create table if not exists public.customer_addresses (
    id uuid primary key default gen_random_uuid(),
    customer_id uuid not null references auth.users(id) on delete cascade,
    label text not null default 'Casa' check (char_length(label) between 1 and 40),
    address text not null check (char_length(address) between 5 and 300),
    reference text check (char_length(reference) <= 300),
    latitude double precision not null check (latitude between -90 and 90),
    longitude double precision not null check (longitude between -180 and 180),
    contact_name text not null check (char_length(contact_name) between 2 and 120),
    contact_phone text not null check (char_length(contact_phone) between 7 and 30),
    is_default boolean not null default false,
    created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.delivery_driver_status (
    restaurant_id uuid not null references public.profiles(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    is_available boolean not null default false,
    latitude double precision, longitude double precision,
    last_location_at timestamptz, updated_at timestamptz not null default now(),
    primary key (restaurant_id,user_id)
);
create table if not exists public.delivery_events (
    id bigint generated always as identity primary key,
    order_id bigint not null references public.orders(id) on delete cascade,
    restaurant_id uuid not null references public.profiles(id) on delete cascade,
    status text not null, message text, actor_id uuid references auth.users(id) on delete set null,
    created_at timestamptz not null default now()
);
create table if not exists public.delivery_incidents (
    id bigint generated always as identity primary key,
    order_id bigint not null references public.orders(id) on delete cascade,
    restaurant_id uuid not null references public.profiles(id) on delete cascade,
    driver_id uuid references auth.users(id) on delete set null,
    incident_type text not null check (incident_type in ('customer_unavailable','wrong_address','vehicle','delay','other')),
    notes text not null check (char_length(notes) between 3 and 500),
    status text not null default 'open' check (status in ('open','resolved')),
    created_at timestamptz not null default now(), resolved_at timestamptz
);

alter table public.customer_addresses enable row level security;
alter table public.delivery_driver_status enable row level security;
alter table public.delivery_events enable row level security;
alter table public.delivery_incidents enable row level security;

create or replace function public.has_restaurant_access(p_restaurant_id uuid,p_roles text[] default array['waiter','kitchen','cashier','manager','driver']::text[])
returns boolean language sql stable security definer set search_path='' as $$
select exists(select 1 from public.profiles p where p.id=auth.uid() and p.id=p_restaurant_id and p.role='negocio')
or exists(select 1 from public.restaurant_staff s where s.restaurant_id=p_restaurant_id and s.user_id=auth.uid() and s.is_active and s.staff_role=any(p_roles)); $$;

create or replace function public.has_restaurant_permission(p_restaurant_id uuid,p_permission text)
returns boolean language sql stable security definer set search_path='' as $$
select exists(select 1 from public.profiles p where p.id=auth.uid() and p.id=p_restaurant_id and p.role='negocio')
or exists(select 1 from public.restaurant_staff s where s.restaurant_id=p_restaurant_id and s.user_id=auth.uid() and s.is_active and case p_permission
 when 'create_orders' then s.can_create_orders when 'view_kitchen' then s.can_view_kitchen
 when 'close_accounts' then s.can_close_accounts when 'manage_delivery' then s.can_manage_delivery
 when 'deliver_orders' then s.can_deliver_orders else false end); $$;

drop function if exists public.get_my_restaurant_access();
create function public.get_my_restaurant_access() returns table(
 restaurant_id uuid,staff_role text,business_name text,can_create_orders boolean,can_view_kitchen boolean,
 can_close_accounts boolean,can_manage_delivery boolean,can_deliver_orders boolean
) language sql stable security definer set search_path='' as $$
select a.restaurant_id,a.staff_role,a.business_name,a.can_create_orders,a.can_view_kitchen,a.can_close_accounts,a.can_manage_delivery,a.can_deliver_orders from (
 select p.id restaurant_id,'owner'::text staff_role,p.business_name,true can_create_orders,true can_view_kitchen,true can_close_accounts,true can_manage_delivery,false can_deliver_orders,0 priority from public.profiles p where p.id=auth.uid() and p.role='negocio'
 union all
 select s.restaurant_id,s.staff_role,p.business_name,s.can_create_orders,s.can_view_kitchen,s.can_close_accounts,s.can_manage_delivery,s.can_deliver_orders,1 from public.restaurant_staff s join public.profiles p on p.id=s.restaurant_id where s.user_id=auth.uid() and s.is_active
) a order by a.priority limit 1; $$;

create or replace function public.create_staff_invite(p_staff_role text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_code text;v_invite public.restaurant_staff_invites%rowtype;
begin
 if p_staff_role not in('waiter','kitchen','cashier','manager','driver') then raise exception 'Rol de personal invalido';end if;
 if not exists(select 1 from public.profiles where id=auth.uid() and role='negocio') then raise exception 'Solo el propietario puede invitar personal';end if;
 v_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
 insert into public.restaurant_staff_invites(restaurant_id,code,staff_role,created_by) values(auth.uid(),v_code,p_staff_role,auth.uid()) returning * into v_invite;
 return jsonb_build_object('code',v_invite.code,'role',v_invite.staff_role,'expires_at',v_invite.expires_at);
end; $$;

create or replace function public.accept_staff_invite(p_code text) returns jsonb language plpgsql security definer set search_path='' as $$
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
 return jsonb_build_object('restaurant_id',v_invite.restaurant_id,'business_name',v_name,'staff_role',v_invite.staff_role);
end; $$;

drop function if exists public.list_restaurant_staff();
create function public.list_restaurant_staff() returns table(id bigint,user_id uuid,full_name text,email text,staff_role text,is_active boolean,can_create_orders boolean,can_view_kitchen boolean,can_close_accounts boolean,can_manage_delivery boolean,can_deliver_orders boolean,created_at timestamptz)
language sql stable security definer set search_path='' as $$ select s.id,s.user_id,p.full_name,p.email,s.staff_role,s.is_active,s.can_create_orders,s.can_view_kitchen,s.can_close_accounts,s.can_manage_delivery,s.can_deliver_orders,s.created_at from public.restaurant_staff s join public.profiles p on p.id=s.user_id where s.restaurant_id=auth.uid() order by s.created_at desc; $$;

drop function if exists public.set_staff_permissions(bigint,boolean,boolean,boolean);
drop function if exists public.set_staff_permissions(bigint,boolean,boolean,boolean,boolean,boolean);
create function public.set_staff_permissions(p_staff_id bigint,p_can_create_orders boolean,p_can_view_kitchen boolean,p_can_close_accounts boolean,p_can_manage_delivery boolean,p_can_deliver_orders boolean)
returns void language plpgsql security definer set search_path='' as $$ begin update public.restaurant_staff set can_create_orders=p_can_create_orders,can_view_kitchen=p_can_view_kitchen,can_close_accounts=p_can_close_accounts,can_manage_delivery=p_can_manage_delivery,can_deliver_orders=p_can_deliver_orders where id=p_staff_id and restaurant_id=auth.uid();if not found then raise exception 'Integrante no encontrado';end if;end; $$;

drop view if exists public.public_restaurants;
create view public.public_restaurants as select id,business_name,address,open_time,close_time,avatar_url,rating,latitude,longitude,timezone,accepting_orders,payment_cash,payment_transfer,payment_online,bank_name,bank_account_holder,bank_clabe,mercado_pago_connected,delivery_enabled,delivery_radius_km,delivery_base_fee,delivery_fee_per_km,delivery_free_over,delivery_minimum,delivery_prep_minutes from public.profiles where role='negocio';

create or replace function public.calculate_delivery_quote(p_restaurant_id uuid,p_latitude double precision,p_longitude double precision,p_subtotal numeric)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r public.profiles%rowtype;d numeric;fee numeric;eta integer;
begin
 select * into r from public.profiles where id=p_restaurant_id and role='negocio';
 if not found or not r.delivery_enabled then raise exception 'Este restaurante no ofrece delivery';end if;
 if r.latitude is null or r.longitude is null then raise exception 'El restaurante debe configurar su ubicacion';end if;
 if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Ubicacion de entrega invalida';end if;
 d:=round((6371*2*asin(sqrt(power(sin(radians(p_latitude-r.latitude)/2),2)+cos(radians(r.latitude))*cos(radians(p_latitude))*power(sin(radians(p_longitude-r.longitude)/2),2))))::numeric,2);
 if d>r.delivery_radius_km then raise exception 'La direccion esta fuera de la zona de entrega (% km)',r.delivery_radius_km;end if;
 if p_subtotal<r.delivery_minimum then raise exception 'El pedido minimo para delivery es $%',r.delivery_minimum;end if;
 fee:=case when r.delivery_free_over is not null and p_subtotal>=r.delivery_free_over then 0 else round(r.delivery_base_fee+d*r.delivery_fee_per_km,2) end;
 eta:=r.delivery_prep_minutes+greatest(5,ceil(d*4)::integer);
 return jsonb_build_object('distance_km',d,'delivery_fee',fee,'subtotal',round(p_subtotal,2),'total',round(p_subtotal+fee,2),'eta_minutes',eta,'within_zone',true);
end; $$;

create or replace function public.create_delivery_order(p_restaurant_id uuid,p_items jsonb,p_notes text,p_payment_method text,p_address text,p_reference text,p_latitude double precision,p_longitude double precision,p_contact_name text,p_contact_phone text,p_scheduled_for timestamptz default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.profiles%rowtype;i jsonb;p public.products%rowtype;q integer;items jsonb:='[]';sub numeric:=0;quote jsonb;o public.orders%rowtype;local_time time;is_open boolean:=true;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesion';end if;
 if p_payment_method not in('cash','mercado_pago') then raise exception 'Delivery solo acepta efectivo o Mercado Pago';end if;
 select * into r from public.profiles where id=p_restaurant_id and role='negocio';if not found or not r.delivery_enabled or not r.accepting_orders then raise exception 'Delivery no disponible';end if;
 if p_payment_method='cash' and not r.payment_cash then raise exception 'El restaurante no acepta efectivo';end if;
 if p_payment_method='mercado_pago' and (not r.payment_online or not r.mercado_pago_connected) then raise exception 'Mercado Pago no esta disponible';end if;
 if r.open_time is not null and r.close_time is not null then local_time:=(now() at time zone r.timezone)::time;is_open:=case when r.open_time<=r.close_time then local_time between r.open_time and r.close_time else local_time>=r.open_time or local_time<=r.close_time end;end if;
 if not is_open then raise exception 'El restaurante esta cerrado';end if;
 if char_length(trim(coalesce(p_address,'')))<5 or char_length(trim(coalesce(p_contact_name,'')))<2 or char_length(trim(coalesce(p_contact_phone,'')))<7 then raise exception 'Completa direccion, nombre y telefono';end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>50 then raise exception 'Pedido invalido';end if;
 for i in select value from jsonb_array_elements(p_items) loop
  q:=coalesce((i->>'qty')::integer,0);select * into p from public.products where id::text=i->>'id' and restaurant_id=p_restaurant_id and is_available;
  if not found or q<1 or q>50 then raise exception 'Producto o cantidad invalida';end if;
  items:=items||jsonb_build_array(jsonb_build_object('id',p.id,'nombre',p.name,'price',p.price,'qty',q,'station_id',p.kitchen_station_id));sub:=sub+p.price*q;
 end loop;
 quote:=public.calculate_delivery_quote(p_restaurant_id,p_latitude,p_longitude,sub);
 insert into public.orders(customer_id,restaurant_id,restaurant_name,items,subtotal,delivery_fee,total,notes,status,payment_method,payment_status,service_type,order_source,delivery_distance_km,delivery_address,delivery_reference,delivery_latitude,delivery_longitude,delivery_contact_name,delivery_contact_phone,scheduled_for,delivery_status,delivery_code)
 values(auth.uid(),p_restaurant_id,r.business_name,items,sub,(quote->>'delivery_fee')::numeric,(quote->>'total')::numeric,nullif(left(trim(coalesce(p_notes,'')),500),''),'pendiente',p_payment_method,case when p_payment_method='mercado_pago' then 'pending' else 'not_required' end,'delivery','online',(quote->>'distance_km')::numeric,left(trim(p_address),300),nullif(left(trim(coalesce(p_reference,'')),300),''),p_latitude,p_longitude,left(trim(p_contact_name),120),left(trim(p_contact_phone),30),p_scheduled_for,'pending_acceptance',lpad(floor(random()*10000)::integer::text,4,'0')) returning * into o;
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,'pending_acceptance','Pedido delivery recibido',auth.uid());return to_jsonb(o)||jsonb_build_object('eta_minutes',quote->'eta_minutes');
end; $$;

create or replace function public.accept_delivery_order(p_order_id bigint,p_accept boolean default true) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin select * into o from public.orders where id=p_order_id and service_type='delivery' for update;if not found then raise exception 'Pedido no encontrado';end if;if not public.has_restaurant_permission(o.restaurant_id,'manage_delivery') then raise exception 'Sin permiso de delivery';end if;if o.delivery_status<>'pending_acceptance' then raise exception 'El pedido ya fue revisado';end if;
 if p_accept and o.payment_method='mercado_pago' and o.payment_status<>'approved' then raise exception 'Espera la confirmacion de Mercado Pago';end if;
 update public.orders set delivery_status=case when p_accept then 'accepted' else 'cancelled' end,accepted_at=case when p_accept then now() end,status=case when p_accept then status else 'cancelado' end,cancellation_reason=case when p_accept then cancellation_reason else 'Rechazado por el restaurante' end where id=o.id returning * into o;
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,o.delivery_status,case when p_accept then 'Pedido aceptado' else 'Pedido rechazado' end,auth.uid());return to_jsonb(o);end; $$;

create or replace function public.assign_delivery_driver(p_order_id bigint,p_driver_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;n text;
begin select * into o from public.orders where id=p_order_id and service_type='delivery' for update;if not found then raise exception 'Pedido no encontrado';end if;if not public.has_restaurant_permission(o.restaurant_id,'manage_delivery') then raise exception 'Sin permiso de despacho';end if;if o.delivery_status in('delivered','cancelled') then raise exception 'Pedido cerrado';end if;
 select p.full_name into n from public.restaurant_staff s join public.profiles p on p.id=s.user_id where s.restaurant_id=o.restaurant_id and s.user_id=p_driver_id and s.is_active and s.can_deliver_orders;if n is null then raise exception 'Repartidor no disponible';end if;
 update public.orders set assigned_driver_id=p_driver_id,assigned_driver_name=n,assigned_at=now() where id=o.id returning * into o;insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,o.delivery_status,'Asignado a '||n,auth.uid());return to_jsonb(o);end; $$;

create or replace function public.set_driver_availability(p_available boolean,p_latitude double precision default null,p_longitude double precision default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare rid uuid;
begin select restaurant_id into rid from public.restaurant_staff where user_id=auth.uid() and is_active and can_deliver_orders limit 1;if rid is null then raise exception 'No eres repartidor activo';end if;
 insert into public.delivery_driver_status(restaurant_id,user_id,is_available,latitude,longitude,last_location_at,updated_at) values(rid,auth.uid(),p_available,p_latitude,p_longitude,case when p_latitude is not null then now() end,now()) on conflict(restaurant_id,user_id) do update set is_available=excluded.is_available,latitude=coalesce(excluded.latitude,public.delivery_driver_status.latitude),longitude=coalesce(excluded.longitude,public.delivery_driver_status.longitude),last_location_at=case when excluded.latitude is not null then now() else public.delivery_driver_status.last_location_at end,updated_at=now();return jsonb_build_object('restaurant_id',rid,'is_available',p_available);end; $$;

create or replace function public.list_delivery_drivers(p_restaurant_id uuid) returns table(user_id uuid,full_name text,is_available boolean,last_location_at timestamptz,active_orders bigint)
language sql stable security definer set search_path='' as $$
 select s.user_id,p.full_name,coalesce(d.is_available,false),d.last_location_at,
   (select count(*) from public.orders o where o.assigned_driver_id=s.user_id and o.delivery_status not in('delivered','cancelled'))
 from public.restaurant_staff s join public.profiles p on p.id=s.user_id
 left join public.delivery_driver_status d on d.restaurant_id=s.restaurant_id and d.user_id=s.user_id
 where s.restaurant_id=p_restaurant_id and s.is_active and s.can_deliver_orders
   and public.has_restaurant_permission(p_restaurant_id,'manage_delivery') order by p.full_name; $$;

create or replace function public.advance_delivery_order(p_order_id bigint,p_status text,p_latitude double precision default null,p_longitude double precision default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin select * into o from public.orders where id=p_order_id and service_type='delivery' for update;if not found then raise exception 'Pedido no encontrado';end if;if o.assigned_driver_id is distinct from auth.uid() or not public.has_restaurant_permission(o.restaurant_id,'deliver_orders') then raise exception 'Pedido no asignado a tu cuenta';end if;
 if not ((o.delivery_status='ready_for_dispatch' and p_status='picked_up') or (o.delivery_status='picked_up' and p_status='on_the_way') or (o.delivery_status='on_the_way' and p_status='arrived')) then raise exception 'Cambio de estado invalido';end if;
 update public.orders set delivery_status=p_status,picked_up_at=case when p_status='picked_up' then now() else picked_up_at end,arrived_at=case when p_status='arrived' then now() else arrived_at end,driver_latitude=coalesce(p_latitude,driver_latitude),driver_longitude=coalesce(p_longitude,driver_longitude),driver_location_at=case when p_latitude is not null then now() else driver_location_at end where id=o.id returning * into o;
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,p_status,case p_status when 'picked_up' then 'El repartidor recogio el pedido' when 'on_the_way' then 'Pedido en camino' else 'El repartidor llego' end,auth.uid());return to_jsonb(o);end; $$;

create or replace function public.update_delivery_location(p_order_id bigint,p_latitude double precision,p_longitude double precision) returns void language plpgsql security definer set search_path='' as $$
declare rid uuid;begin select restaurant_id into rid from public.orders where id=p_order_id and assigned_driver_id=auth.uid() and delivery_status in('picked_up','on_the_way','arrived');if rid is null then raise exception 'Pedido no asignado';end if;if p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then raise exception 'Ubicacion invalida';end if;update public.orders set driver_latitude=p_latitude,driver_longitude=p_longitude,driver_location_at=now() where id=p_order_id;update public.delivery_driver_status set latitude=p_latitude,longitude=p_longitude,last_location_at=now(),updated_at=now() where restaurant_id=rid and user_id=auth.uid();end; $$;

create or replace function public.confirm_delivery(p_order_id bigint,p_code text) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin select * into o from public.orders where id=p_order_id and service_type='delivery' for update;if not found then raise exception 'Pedido no encontrado';end if;if o.assigned_driver_id is distinct from auth.uid() then raise exception 'Pedido no asignado';end if;if o.delivery_status not in('on_the_way','arrived') then raise exception 'Marca primero la llegada';end if;if trim(p_code)<>o.delivery_code then raise exception 'Codigo de entrega incorrecto';end if;
 if o.payment_method='cash' and not exists(select 1 from public.order_payments where order_id=o.id) then insert into public.order_payments(order_id,restaurant_id,shift_id,payment_method,amount,tip_amount,received_by) values(o.id,o.restaurant_id,null,'cash',o.total,0,auth.uid());end if;
 update public.orders set delivery_status='delivered',status='entregado',delivered_at=now(),payment_status=case when payment_method='cash' then 'approved' else payment_status end where id=o.id returning * into o;update public.delivery_driver_status set is_available=true,updated_at=now() where restaurant_id=o.restaurant_id and user_id=auth.uid();insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,'delivered','Pedido entregado',auth.uid());return to_jsonb(o);end; $$;

create or replace function public.report_delivery_incident(p_order_id bigint,p_type text,p_notes text) returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;i public.delivery_incidents%rowtype;begin select * into o from public.orders where id=p_order_id and service_type='delivery';if not found then raise exception 'Pedido no encontrado';end if;if not (o.assigned_driver_id=auth.uid() or public.has_restaurant_permission(o.restaurant_id,'manage_delivery')) then raise exception 'Sin permiso';end if;insert into public.delivery_incidents(order_id,restaurant_id,driver_id,incident_type,notes) values(o.id,o.restaurant_id,o.assigned_driver_id,p_type,left(trim(p_notes),500)) returning * into i;return to_jsonb(i);end; $$;

create or replace function public.sync_delivery_kitchen_state() returns trigger language plpgsql security definer set search_path='' as $$
begin if new.service_type='delivery' and new.status is distinct from old.status and new.delivery_status not in('picked_up','on_the_way','arrived','delivered','cancelled') then update public.orders set delivery_status=case new.status when 'preparando' then 'preparing' when 'listo' then 'ready_for_dispatch' when 'cancelado' then 'cancelled' else delivery_status end where id=new.id;end if;return new;end; $$;
drop trigger if exists sync_delivery_kitchen_state on public.orders;
create trigger sync_delivery_kitchen_state after update of status on public.orders for each row execute function public.sync_delivery_kitchen_state();

create or replace function public.sync_online_order_kitchen_ticket() returns trigger language plpgsql security definer set search_path='' as $$
declare v_ticket_id bigint;v_items jsonb;
begin if new.order_source='pos' or new.status not in('pendiente','preparando','listo') or (new.payment_method='mercado_pago' and new.payment_status<>'approved') or (new.service_type='delivery' and new.delivery_status not in('accepted','preparing','ready_for_dispatch')) or exists(select 1 from public.kitchen_tickets t where t.order_id=new.id) then return new;end if;
 select coalesce(jsonb_agg(i.value||jsonb_build_object('station_id',p.kitchen_station_id)),'[]'::jsonb) into v_items from jsonb_array_elements(new.items)i join public.products p on p.id::text=i.value->>'id';insert into public.kitchen_tickets(order_id,restaurant_id,items,notes,status,service_type,table_id,created_by,waiter_name,created_at) values(new.id,new.restaurant_id,v_items,new.notes,new.status,new.service_type,new.table_id,new.created_by,new.waiter_name,new.created_at) returning id into v_ticket_id;insert into public.kitchen_ticket_station_statuses(ticket_id,restaurant_id,station_key,kitchen_station_id,status) select distinct v_ticket_id,new.restaurant_id,coalesce(p.kitchen_station_id::text,'general'),p.kitchen_station_id,new.status from jsonb_array_elements(v_items)i join public.products p on p.id::text=i->>'id' on conflict(ticket_id,station_key) do nothing;return new;end; $$;
drop trigger if exists sync_online_order_kitchen_ticket on public.orders;
create trigger sync_online_order_kitchen_ticket after insert or update of payment_status,status,delivery_status on public.orders for each row execute function public.sync_online_order_kitchen_ticket();

drop policy if exists "customer_addresses_own" on public.customer_addresses;
create policy "customer_addresses_own" on public.customer_addresses for all to authenticated using(customer_id=auth.uid()) with check(customer_id=auth.uid());
drop policy if exists "driver_status_access" on public.delivery_driver_status;
create policy "driver_status_access" on public.delivery_driver_status for select to authenticated using(user_id=auth.uid() or public.has_restaurant_permission(restaurant_id,'manage_delivery'));
drop policy if exists "delivery_events_read" on public.delivery_events;
create policy "delivery_events_read" on public.delivery_events for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and (o.customer_id=auth.uid() or o.assigned_driver_id=auth.uid() or public.has_restaurant_permission(o.restaurant_id,'manage_delivery'))));
drop policy if exists "delivery_incidents_read" on public.delivery_incidents;
create policy "delivery_incidents_read" on public.delivery_incidents for select to authenticated using(driver_id=auth.uid() or public.has_restaurant_permission(restaurant_id,'manage_delivery'));
drop policy if exists "orders_read_participants" on public.orders;
create policy "orders_read_participants" on public.orders for select to authenticated using(customer_id=auth.uid() or restaurant_id=auth.uid() or assigned_driver_id=auth.uid() or public.has_restaurant_permission(restaurant_id,'view_kitchen') or public.has_restaurant_permission(restaurant_id,'close_accounts') or public.has_restaurant_permission(restaurant_id,'manage_delivery') or(created_by=auth.uid() and public.has_restaurant_permission(restaurant_id,'create_orders')));

revoke update on public.profiles from authenticated;
grant update(phone,address,open_time,close_time,avatar_url,latitude,longitude,timezone,accepting_orders,payment_cash,payment_transfer,payment_online,bank_name,bank_account_holder,bank_clabe,delivery_enabled,delivery_radius_km,delivery_base_fee,delivery_fee_per_km,delivery_free_over,delivery_minimum,delivery_prep_minutes) on public.profiles to authenticated;
grant select on public.public_restaurants,public.customer_addresses,public.delivery_driver_status,public.delivery_events,public.delivery_incidents to authenticated;
grant insert,update,delete on public.customer_addresses to authenticated;
revoke all on function public.calculate_delivery_quote(uuid,double precision,double precision,numeric),public.create_delivery_order(uuid,jsonb,text,text,text,text,double precision,double precision,text,text,timestamptz),public.accept_delivery_order(bigint,boolean),public.assign_delivery_driver(bigint,uuid),public.set_driver_availability(boolean,double precision,double precision),public.list_delivery_drivers(uuid),public.advance_delivery_order(bigint,text,double precision,double precision),public.update_delivery_location(bigint,double precision,double precision),public.confirm_delivery(bigint,text),public.report_delivery_incident(bigint,text,text) from public,anon;
grant execute on function public.calculate_delivery_quote(uuid,double precision,double precision,numeric),public.create_delivery_order(uuid,jsonb,text,text,text,text,double precision,double precision,text,text,timestamptz),public.accept_delivery_order(bigint,boolean),public.assign_delivery_driver(bigint,uuid),public.set_driver_availability(boolean,double precision,double precision),public.list_delivery_drivers(uuid),public.advance_delivery_order(bigint,text,double precision,double precision),public.update_delivery_location(bigint,double precision,double precision),public.confirm_delivery(bigint,text),public.report_delivery_incident(bigint,text,text),public.get_my_restaurant_access(),public.create_staff_invite(text),public.accept_staff_invite(text),public.list_restaurant_staff(),public.set_staff_permissions(bigint,boolean,boolean,boolean,boolean,boolean) to authenticated;

do $$ begin alter publication supabase_realtime add table public.delivery_events;exception when duplicate_object then null;end $$;
do $$ begin alter publication supabase_realtime add table public.delivery_driver_status;exception when duplicate_object then null;end $$;

commit;
