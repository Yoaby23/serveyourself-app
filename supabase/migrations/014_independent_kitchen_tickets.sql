begin;

create table if not exists public.kitchen_tickets (
    id bigint generated always as identity primary key,
    order_id bigint not null references public.orders(id) on delete cascade,
    restaurant_id uuid not null references public.profiles(id) on delete cascade,
    items jsonb not null check (jsonb_typeof(items)='array' and jsonb_array_length(items)>0),
    notes text,
    status text not null default 'pendiente' check (status in ('pendiente','preparando','listo','entregado','cancelado')),
    service_type text not null check (service_type in ('pickup','dine_in')),
    table_id bigint references public.restaurant_tables(id) on delete set null,
    created_by uuid references public.profiles(id) on delete set null,
    waiter_name text,
    created_at timestamptz not null default now(),
    ready_at timestamptz,
    delivered_at timestamptz
);

create table if not exists public.kitchen_ticket_station_statuses (
    ticket_id bigint not null references public.kitchen_tickets(id) on delete cascade,
    restaurant_id uuid not null references public.profiles(id) on delete cascade,
    station_key text not null,
    kitchen_station_id bigint references public.kitchen_stations(id) on delete set null,
    status text not null default 'pendiente' check (status in ('pendiente','preparando','listo','entregado')),
    updated_at timestamptz not null default now(),
    primary key(ticket_id,station_key)
);

create index if not exists kitchen_tickets_restaurant_status_idx on public.kitchen_tickets(restaurant_id,status,created_at);
create index if not exists kitchen_tickets_order_idx on public.kitchen_tickets(order_id);
alter table public.kitchen_tickets enable row level security;
alter table public.kitchen_ticket_station_statuses enable row level security;

drop policy if exists "kitchen_tickets_staff_read" on public.kitchen_tickets;
create policy "kitchen_tickets_staff_read" on public.kitchen_tickets for select to authenticated using (
    public.has_restaurant_permission(restaurant_id,'view_kitchen')
    or created_by=auth.uid()
    or public.has_restaurant_permission(restaurant_id,'close_accounts')
);
drop policy if exists "kitchen_ticket_stations_staff_read" on public.kitchen_ticket_station_statuses;
create policy "kitchen_ticket_stations_staff_read" on public.kitchen_ticket_station_statuses for select to authenticated using (
    public.has_restaurant_permission(restaurant_id,'view_kitchen')
    or exists(select 1 from public.kitchen_tickets t where t.id=ticket_id and t.created_by=auth.uid())
);

grant select on public.kitchen_tickets,public.kitchen_ticket_station_statuses to authenticated;

-- Convierte cada comanda activa actual en un ticket inicial. A partir de aqui,
-- cada envio nuevo tendrá su propio registro y su propio estado.
insert into public.kitchen_tickets(order_id,restaurant_id,items,notes,status,service_type,table_id,created_by,waiter_name,created_at,ready_at)
select o.id,o.restaurant_id,
       case when jsonb_typeof(o.kitchen_items)='array' and jsonb_array_length(o.kitchen_items)>0 then o.kitchen_items else o.items end,
       o.notes,o.status,o.service_type,o.table_id,o.created_by,o.waiter_name,o.created_at,o.ready_at
from public.orders o
where o.status in ('pendiente','preparando','listo')
  and (o.payment_method<>'mercado_pago' or o.payment_status='approved')
  and not exists(select 1 from public.kitchen_tickets t where t.order_id=o.id);

insert into public.kitchen_ticket_station_statuses(ticket_id,restaurant_id,station_key,kitchen_station_id,status)
select distinct t.id,t.restaurant_id,coalesce(p.kitchen_station_id::text,'general'),p.kitchen_station_id,t.status
from public.kitchen_tickets t
cross join lateral jsonb_array_elements(t.items) i
join public.products p on p.id::text=i->>'id'
on conflict(ticket_id,station_key) do nothing;

create or replace function public.create_kitchen_ticket(p_order_id bigint,p_items jsonb,p_notes text default null)
returns bigint language plpgsql security definer set search_path='' as $$
declare v_order public.orders%rowtype; v_item jsonb; v_product public.products%rowtype; v_qty integer; v_items jsonb:='[]'::jsonb; v_ticket_id bigint;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found then raise exception 'Cuenta no encontrada'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'create_orders') then raise exception 'Sin permiso para crear comandas'; end if;
    if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 then raise exception 'Agrega productos'; end if;
    for v_item in select value from jsonb_array_elements(p_items) loop
        v_qty:=coalesce((v_item->>'qty')::integer,0);
        select * into v_product from public.products where id::text=v_item->>'id' and restaurant_id=v_order.restaurant_id;
        if not found or v_qty<1 or v_qty>50 then raise exception 'Producto o cantidad invalida'; end if;
        v_items:=v_items||jsonb_build_array(jsonb_build_object('id',v_product.id,'nombre',v_product.name,'price',v_product.price,'qty',v_qty,'station_id',v_product.kitchen_station_id));
    end loop;
    insert into public.kitchen_tickets(order_id,restaurant_id,items,notes,service_type,table_id,created_by,waiter_name)
    values(v_order.id,v_order.restaurant_id,v_items,nullif(left(trim(coalesce(p_notes,'')),500),''),v_order.service_type,v_order.table_id,v_order.created_by,v_order.waiter_name)
    returning id into v_ticket_id;
    insert into public.kitchen_ticket_station_statuses(ticket_id,restaurant_id,station_key,kitchen_station_id)
    select distinct v_ticket_id,v_order.restaurant_id,coalesce(p.kitchen_station_id::text,'general'),p.kitchen_station_id
    from jsonb_array_elements(v_items) i join public.products p on p.id::text=i->>'id'
    on conflict(ticket_id,station_key) do nothing;
    return v_ticket_id;
end; $$;

create or replace function public.refresh_order_kitchen_status(p_order_id bigint)
returns text language plpgsql security definer set search_path='' as $$
declare v_status text;
begin
    select case
      when count(*) filter(where status='preparando')>0 then 'preparando'
      when count(*) filter(where status='pendiente')>0 then 'pendiente'
      when count(*) filter(where status='listo')>0 then 'listo'
      else 'entregado' end into v_status
    from public.kitchen_tickets where order_id=p_order_id and status<>'cancelado';
    update public.orders set status=v_status,
      ready_at=case when v_status='listo' then coalesce(ready_at,now()) when v_status in ('pendiente','preparando') then null else ready_at end,
      delivered_at=case when v_status='entregado' then coalesce(delivered_at,now()) when v_status<>'entregado' then null else delivered_at end
    where id=p_order_id;
    return v_status;
end; $$;

create or replace function public.append_pos_order_items(p_order_id bigint,p_items jsonb,p_notes text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order public.orders%rowtype; v_item jsonb; v_product public.products%rowtype; v_qty integer; v_added jsonb:='[]'::jsonb; v_total numeric:=0; v_ticket_id bigint;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' or v_order.payment_status='approved' or v_order.status='cancelado' then raise exception 'La cuenta no esta abierta'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'create_orders') then raise exception 'Sin permiso para agregar productos'; end if;
    if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 then raise exception 'Agrega productos'; end if;
    for v_item in select value from jsonb_array_elements(p_items) loop
        v_qty:=(v_item->>'qty')::integer;
        select * into v_product from public.products where id::text=v_item->>'id' and restaurant_id=v_order.restaurant_id and is_available;
        if not found or v_qty<1 or v_qty>50 then raise exception 'Producto o cantidad invalida'; end if;
        v_added:=v_added||jsonb_build_array(jsonb_build_object('id',v_product.id,'nombre',v_product.name,'price',v_product.price,'qty',v_qty,'station_id',v_product.kitchen_station_id));
        v_total:=v_total+v_product.price*v_qty;
    end loop;
    update public.orders set items=items||v_added,total=total+v_total,
      notes=coalesce(nullif(left(trim(coalesce(p_notes,'')),500),''),notes),payment_status='pending'
    where id=p_order_id returning * into v_order;
    v_ticket_id:=public.create_kitchen_ticket(p_order_id,v_added,p_notes);
    perform public.refresh_order_kitchen_status(p_order_id);
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    values(p_order_id,v_order.restaurant_id,'items_added',jsonb_build_object('items',v_added,'amount',v_total,'kitchen_ticket_id',v_ticket_id),auth.uid());
    return to_jsonb(v_order)||jsonb_build_object('kitchen_ticket_id',v_ticket_id);
end; $$;

create or replace function public.create_or_append_pos_order(p_restaurant_id uuid,p_items jsonb,p_notes text default null,p_service_type text default 'pickup',p_table_id bigint default null,p_payment_method text default 'cash')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order_id bigint; v_result jsonb; v_ticket_id bigint;
begin
    if p_service_type='dine_in' then
        if p_table_id is null then raise exception 'Selecciona una mesa activa'; end if;
        perform pg_advisory_xact_lock(hashtextextended(p_restaurant_id::text||':'||p_table_id::text,0));
        select id into v_order_id from public.orders
        where restaurant_id=p_restaurant_id and table_id=p_table_id and order_source='pos' and payment_status='pending' and status<>'cancelado'
        order by created_at limit 1;
    end if;
    if v_order_id is not null then
        v_result:=public.append_pos_order_items(v_order_id,p_items,p_notes);
        return v_result||jsonb_build_object('was_appended',true);
    end if;
    v_result:=public.create_pos_order(p_restaurant_id,p_items,p_notes,p_service_type,p_table_id,p_payment_method);
    v_ticket_id:=public.create_kitchen_ticket((v_result->>'id')::bigint,v_result->'items',p_notes);
    return v_result||jsonb_build_object('was_appended',false,'kitchen_ticket_id',v_ticket_id);
end; $$;

create or replace function public.update_kitchen_ticket_status(p_ticket_id bigint,p_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ticket public.kitchen_tickets%rowtype;
begin
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id for update;
    if not found then raise exception 'Comanda no encontrada'; end if;
    if not public.has_restaurant_permission(v_ticket.restaurant_id,'view_kitchen') then raise exception 'Sin permiso de cocina'; end if;
    if (v_ticket.status='pendiente' and p_status<>'preparando') or (v_ticket.status='preparando' and p_status<>'listo') or (v_ticket.status='listo' and p_status<>'entregado') then raise exception 'Cambio de estado invalido'; end if;
    update public.kitchen_ticket_station_statuses set status=p_status,updated_at=now() where ticket_id=p_ticket_id;
    update public.kitchen_tickets set status=p_status,
      ready_at=case when p_status='listo' then coalesce(ready_at,now()) else ready_at end,
      delivered_at=case when p_status='entregado' then coalesce(delivered_at,now()) else delivered_at end
    where id=p_ticket_id returning * into v_ticket;
    perform public.refresh_order_kitchen_status(v_ticket.order_id);
    return to_jsonb(v_ticket);
end; $$;

create or replace function public.update_kitchen_ticket_station_status(p_ticket_id bigint,p_station_key text,p_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_station public.kitchen_ticket_station_statuses%rowtype; v_ticket public.kitchen_tickets%rowtype; v_status text;
begin
    select * into v_station from public.kitchen_ticket_station_statuses where ticket_id=p_ticket_id and station_key=p_station_key for update;
    if not found then raise exception 'Estacion de la comanda no encontrada'; end if;
    if not public.has_restaurant_permission(v_station.restaurant_id,'view_kitchen') then raise exception 'Sin permiso de cocina'; end if;
    if (v_station.status='pendiente' and p_status<>'preparando') or (v_station.status='preparando' and p_status<>'listo') or (v_station.status='listo' and p_status<>'entregado') then raise exception 'Cambio de estado invalido'; end if;
    update public.kitchen_ticket_station_statuses set status=p_status,updated_at=now() where ticket_id=p_ticket_id and station_key=p_station_key returning * into v_station;
    select case when bool_and(status='entregado') then 'entregado' when bool_and(status in ('listo','entregado')) then 'listo' when bool_or(status in ('preparando','listo','entregado')) then 'preparando' else 'pendiente' end
    into v_status from public.kitchen_ticket_station_statuses where ticket_id=p_ticket_id;
    update public.kitchen_tickets set status=v_status,
      ready_at=case when v_status='listo' then coalesce(ready_at,now()) else ready_at end,
      delivered_at=case when v_status='entregado' then coalesce(delivered_at,now()) else delivered_at end
    where id=p_ticket_id returning * into v_ticket;
    perform public.refresh_order_kitchen_status(v_ticket.order_id);
    return to_jsonb(v_station)||jsonb_build_object('ticket_status',v_status);
end; $$;

-- Los pedidos hechos por clientes también generan su ticket cuando pueden
-- entrar a cocina. Mercado Pago espera hasta que el webhook apruebe el cobro.
create or replace function public.sync_online_order_kitchen_ticket()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_ticket_id bigint; v_items jsonb;
begin
    if new.order_source='pos'
       or new.status not in ('pendiente','preparando','listo')
       or (new.payment_method='mercado_pago' and new.payment_status<>'approved')
       or exists(select 1 from public.kitchen_tickets t where t.order_id=new.id) then
        return new;
    end if;
    select coalesce(jsonb_agg(i.value||jsonb_build_object('station_id',p.kitchen_station_id)),'[]'::jsonb)
    into v_items
    from jsonb_array_elements(new.items) i
    join public.products p on p.id::text=i.value->>'id';
    insert into public.kitchen_tickets(order_id,restaurant_id,items,notes,status,service_type,table_id,created_by,waiter_name,created_at)
    values(new.id,new.restaurant_id,v_items,new.notes,new.status,new.service_type,new.table_id,new.created_by,new.waiter_name,new.created_at)
    returning id into v_ticket_id;
    insert into public.kitchen_ticket_station_statuses(ticket_id,restaurant_id,station_key,kitchen_station_id,status)
    select distinct v_ticket_id,new.restaurant_id,coalesce(p.kitchen_station_id::text,'general'),p.kitchen_station_id,new.status
    from jsonb_array_elements(v_items) i join public.products p on p.id::text=i->>'id'
    on conflict(ticket_id,station_key) do nothing;
    return new;
end; $$;

drop trigger if exists sync_online_order_kitchen_ticket on public.orders;
create trigger sync_online_order_kitchen_ticket
after insert or update of payment_status,status on public.orders
for each row execute function public.sync_online_order_kitchen_ticket();

revoke all on function public.create_kitchen_ticket(bigint,jsonb,text),public.refresh_order_kitchen_status(bigint),public.sync_online_order_kitchen_ticket() from public,anon,authenticated;
revoke all on function public.append_pos_order_items(bigint,jsonb,text),public.create_or_append_pos_order(uuid,jsonb,text,text,bigint,text),public.update_kitchen_ticket_status(bigint,text),public.update_kitchen_ticket_station_status(bigint,text,text) from public,anon;
grant execute on function public.append_pos_order_items(bigint,jsonb,text),public.create_or_append_pos_order(uuid,jsonb,text,text,bigint,text),public.update_kitchen_ticket_status(bigint,text),public.update_kitchen_ticket_station_status(bigint,text,text) to authenticated;

do $$ begin
    alter publication supabase_realtime add table public.kitchen_tickets;
exception when duplicate_object then null; end $$;

commit;
