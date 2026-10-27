begin;

create table public.restaurant_favorites (
 user_id uuid not null references auth.users(id) on delete cascade,
 restaurant_id uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(user_id,restaurant_id)
);
create index restaurant_favorites_restaurant_idx on public.restaurant_favorites(restaurant_id);
alter table public.restaurant_favorites enable row level security;
revoke all on public.restaurant_favorites from public,anon,authenticated;
grant select,insert,delete on public.restaurant_favorites to authenticated;
create policy favorites_read_own on public.restaurant_favorites for select to authenticated using(user_id=(select auth.uid()));
create policy favorites_insert_own on public.restaurant_favorites for insert to authenticated
with check(user_id=(select auth.uid()) and exists(select 1 from public.public_restaurants r where r.id=restaurant_id));
create policy favorites_delete_own on public.restaurant_favorites for delete to authenticated using(user_id=(select auth.uid()));

create or replace function public.set_restaurant_favorite(p_restaurant_id uuid,p_favorite boolean)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Inicia sesión para guardar favoritos';end if;
 if p_restaurant_id is null or p_favorite is null then raise exception 'Favorito inválido';end if;
 if p_favorite then
   insert into public.restaurant_favorites(user_id,restaurant_id) values(auth.uid(),p_restaurant_id) on conflict do nothing;
 else
   delete from public.restaurant_favorites where user_id=auth.uid() and restaurant_id=p_restaurant_id;
 end if;
 return p_favorite;
end;$$;
revoke all on function public.set_restaurant_favorite(uuid,boolean) from public,anon;
grant execute on function public.set_restaurant_favorite(uuid,boolean) to authenticated;

-- Meseros can see minimal table-account summaries even if another waiter created them.
-- No customer addresses, phone numbers, or payment details are exposed by this RPC.
create or replace function public.list_pos_table_accounts(p_restaurant_id uuid)
returns table(id bigint,total numeric,table_id bigint,waiter_name text,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.has_restaurant_permission(p_restaurant_id,'create_orders') then raise exception 'Sin permiso para ver las mesas';end if;
 return query select o.id,o.total,o.table_id,o.waiter_name,o.created_at from public.orders o
 where o.restaurant_id=p_restaurant_id and o.order_source='pos' and o.service_type='dine_in'
 and o.payment_status='pending' and o.status<>'cancelado'
 order by o.created_at,o.id;
end;$$;
revoke all on function public.list_pos_table_accounts(uuid) from public,anon;
grant execute on function public.list_pos_table_accounts(uuid) to authenticated;

create or replace function public.create_or_append_pos_order(p_restaurant_id uuid,p_items jsonb,p_notes text default null,p_service_type text default 'pickup',p_table_id bigint default null,p_payment_method text default 'cash')
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order_id bigint; v_result jsonb; v_ticket_id bigint;
begin
    if p_service_type='dine_in' then
        if p_table_id is null then raise exception 'Selecciona una mesa activa'; end if;
        perform pg_advisory_xact_lock(hashtextextended(p_restaurant_id::text||':'||p_table_id::text,0));
        select id into v_order_id from public.orders
        where restaurant_id=p_restaurant_id and table_id=p_table_id and order_source='pos' and payment_status='pending' and status<>'cancelado'
        order by created_at,id limit 1 for update;
    end if;
    if v_order_id is not null then
        v_result:=public.append_pos_order_items(v_order_id,p_items,p_notes);
        return v_result||jsonb_build_object('was_appended',true);
    end if;
    v_result:=public.create_pos_order(p_restaurant_id,p_items,p_notes,p_service_type,p_table_id,p_payment_method);
    v_ticket_id:=public.create_kitchen_ticket((v_result->>'id')::bigint,v_result->'items',p_notes);
    return v_result||jsonb_build_object('was_appended',false,'kitchen_ticket_id',v_ticket_id);
end; $$;

-- Keep the existing signature compatible with installed/older clients. A null account ID
-- now means auto-reuse for table service, never open another account on the same table.
create or replace function public.create_pos_table_order(p_restaurant_id uuid,p_items jsonb,p_notes text,p_service_type text,p_table_id bigint,p_payment_method text,p_existing_order_id bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare existing public.orders%rowtype;
begin
 if auth.uid() is null or not public.has_restaurant_permission(p_restaurant_id,'create_orders') then raise exception 'Sin permiso para crear comandas';end if;
 if p_service_type='dine_in' then
   if p_table_id is null or not exists(select 1 from public.restaurant_tables where id=p_table_id and restaurant_id=p_restaurant_id and is_active) then raise exception 'Selecciona una mesa activa';end if;
   perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_restaurant_id::text||':'||p_table_id::text,0));
   if p_existing_order_id is not null then
     select * into existing from public.orders where id=p_existing_order_id for update;
     if not found or existing.restaurant_id<>p_restaurant_id or existing.table_id is distinct from p_table_id
       or existing.order_source<>'pos' or existing.service_type<>'dine_in' or existing.payment_status<>'pending' or existing.status='cancelado' then
       raise exception 'La cuenta cambió o ya se cerró. Vuelve a seleccionar la mesa';end if;
   end if;
 elsif p_existing_order_id is not null or p_table_id is not null then
   raise exception 'Las órdenes para llevar no se agregan a una mesa';
 end if;
 return public.create_or_append_pos_order(p_restaurant_id,p_items,p_notes,p_service_type,p_table_id,p_payment_method);
end;$$;
revoke all on function public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint) from public,anon;
grant execute on function public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint) to authenticated;
commit;
