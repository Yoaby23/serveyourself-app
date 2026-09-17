-- Permisos configurables, rol Capitan de caja y separacion estricta de funciones.
-- Ejecutar despues de 006_allow_pos_orders_without_customer.sql.

begin;

alter table public.restaurant_staff
    add column if not exists can_create_orders boolean not null default false,
    add column if not exists can_view_kitchen boolean not null default false,
    add column if not exists can_close_accounts boolean not null default false;

alter table public.restaurant_staff drop constraint if exists restaurant_staff_staff_role_check;
alter table public.restaurant_staff add constraint restaurant_staff_staff_role_check
    check (staff_role in ('waiter', 'kitchen', 'cashier', 'manager'));

alter table public.restaurant_staff_invites drop constraint if exists restaurant_staff_invites_staff_role_check;
alter table public.restaurant_staff_invites add constraint restaurant_staff_invites_staff_role_check
    check (staff_role in ('waiter', 'kitchen', 'cashier', 'manager'));

update public.restaurant_staff set
    can_create_orders = staff_role in ('waiter', 'manager'),
    can_view_kitchen = staff_role in ('kitchen', 'manager'),
    can_close_accounts = staff_role in ('cashier', 'manager');

create or replace function public.has_restaurant_access(
    p_restaurant_id uuid,
    p_roles text[] default array['waiter', 'kitchen', 'cashier', 'manager']::text[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.profiles p
        where p.id = auth.uid() and p.id = p_restaurant_id and p.role = 'negocio'
    ) or exists (
        select 1 from public.restaurant_staff s
        where s.restaurant_id = p_restaurant_id
          and s.user_id = auth.uid()
          and s.is_active
          and s.staff_role = any(p_roles)
    );
$$;

create or replace function public.has_restaurant_permission(
    p_restaurant_id uuid,
    p_permission text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.profiles p
        where p.id = auth.uid() and p.id = p_restaurant_id and p.role = 'negocio'
    ) or exists (
        select 1 from public.restaurant_staff s
        where s.restaurant_id = p_restaurant_id
          and s.user_id = auth.uid()
          and s.is_active
          and case p_permission
              when 'create_orders' then s.can_create_orders
              when 'view_kitchen' then s.can_view_kitchen
              when 'close_accounts' then s.can_close_accounts
              else false
          end
    );
$$;

revoke all on function public.has_restaurant_permission(uuid, text) from public, anon;
grant execute on function public.has_restaurant_permission(uuid, text) to authenticated;

drop policy if exists "staff_read" on public.restaurant_staff;
create policy "staff_read" on public.restaurant_staff for select to authenticated
using (user_id = auth.uid() or restaurant_id = auth.uid());

drop policy if exists "tables_management" on public.restaurant_tables;
create policy "tables_management" on public.restaurant_tables for all to authenticated
using (restaurant_id = auth.uid())
with check (restaurant_id = auth.uid());

drop function if exists public.get_my_restaurant_access();
create function public.get_my_restaurant_access()
returns table (
    restaurant_id uuid,
    staff_role text,
    business_name text,
    can_create_orders boolean,
    can_view_kitchen boolean,
    can_close_accounts boolean
)
language sql
stable
security definer
set search_path = ''
as $$
    select access.restaurant_id, access.staff_role, access.business_name,
           access.can_create_orders, access.can_view_kitchen, access.can_close_accounts
    from (
        select p.id as restaurant_id, 'owner'::text as staff_role, p.business_name,
               true as can_create_orders, true as can_view_kitchen, true as can_close_accounts,
               0 as priority
        from public.profiles p
        where p.id = auth.uid() and p.role = 'negocio'
        union all
        select s.restaurant_id, s.staff_role, p.business_name,
               s.can_create_orders, s.can_view_kitchen, s.can_close_accounts, 1 as priority
        from public.restaurant_staff s
        join public.profiles p on p.id = s.restaurant_id
        where s.user_id = auth.uid() and s.is_active
    ) access
    order by access.priority, access.staff_role
    limit 1;
$$;

revoke all on function public.get_my_restaurant_access() from public, anon;
grant execute on function public.get_my_restaurant_access() to authenticated;

create or replace function public.create_staff_invite(p_staff_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_code text;
    v_invite public.restaurant_staff_invites%rowtype;
begin
    if p_staff_role not in ('waiter', 'kitchen', 'cashier', 'manager') then
        raise exception 'Rol de personal invalido';
    end if;
    if not exists (select 1 from public.profiles where id = v_user_id and role = 'negocio') then
        raise exception 'Solo el propietario puede invitar personal';
    end if;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    insert into public.restaurant_staff_invites (restaurant_id, code, staff_role, created_by)
    values (v_user_id, v_code, p_staff_role, v_user_id)
    returning * into v_invite;
    return jsonb_build_object('code', v_invite.code, 'role', v_invite.staff_role, 'expires_at', v_invite.expires_at);
end;
$$;

create or replace function public.accept_staff_invite(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_invite public.restaurant_staff_invites%rowtype;
    v_business_name text;
begin
    if v_user_id is null then raise exception 'Debes iniciar sesion'; end if;
    select * into v_invite from public.restaurant_staff_invites
    where code = upper(trim(p_code)) and used_at is null and expires_at > now()
    for update;
    if not found then raise exception 'El codigo no existe, ya fue usado o vencio'; end if;
    if v_invite.restaurant_id = v_user_id then raise exception 'El propietario no necesita una invitacion'; end if;

    insert into public.restaurant_staff (
        restaurant_id, user_id, staff_role, is_active,
        can_create_orders, can_view_kitchen, can_close_accounts
    ) values (
        v_invite.restaurant_id, v_user_id, v_invite.staff_role, true,
        v_invite.staff_role in ('waiter', 'manager'),
        v_invite.staff_role in ('kitchen', 'manager'),
        v_invite.staff_role in ('cashier', 'manager')
    ) on conflict (restaurant_id, user_id) do update set
        staff_role = excluded.staff_role,
        is_active = true,
        can_create_orders = excluded.can_create_orders,
        can_view_kitchen = excluded.can_view_kitchen,
        can_close_accounts = excluded.can_close_accounts;

    update public.restaurant_staff_invites set used_by = v_user_id, used_at = now()
    where id = v_invite.id;
    select business_name into v_business_name from public.profiles where id = v_invite.restaurant_id;
    return jsonb_build_object('restaurant_id', v_invite.restaurant_id, 'business_name', v_business_name, 'staff_role', v_invite.staff_role);
end;
$$;

drop function if exists public.list_restaurant_staff();
create function public.list_restaurant_staff()
returns table (
    id bigint, user_id uuid, full_name text, email text, staff_role text,
    is_active boolean, can_create_orders boolean, can_view_kitchen boolean,
    can_close_accounts boolean, created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select s.id, s.user_id, p.full_name, p.email, s.staff_role, s.is_active,
           s.can_create_orders, s.can_view_kitchen, s.can_close_accounts, s.created_at
    from public.restaurant_staff s
    join public.profiles p on p.id = s.user_id
    where s.restaurant_id = auth.uid()
    order by s.created_at desc;
$$;

revoke all on function public.list_restaurant_staff() from public, anon;
grant execute on function public.list_restaurant_staff() to authenticated;

create or replace function public.set_staff_permissions(
    p_staff_id bigint,
    p_can_create_orders boolean,
    p_can_view_kitchen boolean,
    p_can_close_accounts boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.restaurant_staff set
        can_create_orders = p_can_create_orders,
        can_view_kitchen = p_can_view_kitchen,
        can_close_accounts = p_can_close_accounts
    where id = p_staff_id and restaurant_id = auth.uid();
    if not found then raise exception 'Integrante no encontrado'; end if;
end;
$$;

revoke all on function public.set_staff_permissions(bigint, boolean, boolean, boolean) from public, anon;
grant execute on function public.set_staff_permissions(bigint, boolean, boolean, boolean) to authenticated;

drop policy if exists "orders_read_participants" on public.orders;
create policy "orders_read_participants" on public.orders for select to authenticated
using (
    customer_id = auth.uid()
    or restaurant_id = auth.uid()
    or public.has_restaurant_permission(restaurant_id, 'view_kitchen')
    or public.has_restaurant_permission(restaurant_id, 'close_accounts')
    or (created_by = auth.uid() and public.has_restaurant_permission(restaurant_id, 'create_orders'))
);

drop policy if exists "orders_update_restaurant" on public.orders;
create policy "orders_update_restaurant" on public.orders for update to authenticated
using (public.has_restaurant_permission(restaurant_id, 'view_kitchen'))
with check (
    public.has_restaurant_permission(restaurant_id, 'view_kitchen')
    and status in ('pendiente', 'preparando', 'listo', 'entregado', 'cancelado')
);

create or replace function public.create_pos_order(
    p_restaurant_id uuid,
    p_items jsonb,
    p_notes text default null,
    p_service_type text default 'pickup',
    p_table_id bigint default null,
    p_payment_method text default 'cash'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_restaurant public.profiles%rowtype;
    v_creator public.profiles%rowtype;
    v_item jsonb;
    v_product public.products%rowtype;
    v_quantity integer;
    v_items jsonb := '[]'::jsonb;
    v_total numeric := 0;
    v_order public.orders%rowtype;
begin
    if not public.has_restaurant_permission(p_restaurant_id, 'create_orders') then
        raise exception 'No tienes permiso para crear comandas';
    end if;
    if p_service_type not in ('pickup', 'dine_in') then raise exception 'Tipo de servicio invalido'; end if;
    if p_payment_method not in ('cash', 'transfer', 'card_terminal') then raise exception 'Metodo de pago invalido'; end if;
    if p_service_type = 'dine_in' then
        if p_table_id is null or not exists (
            select 1 from public.restaurant_tables where id = p_table_id and restaurant_id = p_restaurant_id and is_active
        ) then raise exception 'Selecciona una mesa activa'; end if;
    else p_table_id := null;
    end if;
    if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 50 then
        raise exception 'El pedido debe contener entre 1 y 50 productos';
    end if;
    select * into v_restaurant from public.profiles where id = p_restaurant_id and role = 'negocio';
    select * into v_creator from public.profiles where id = v_user_id;
    for v_item in select value from jsonb_array_elements(p_items) loop
        if coalesce(v_item ->> 'qty', '') !~ '^[0-9]+$' then raise exception 'Cantidad invalida'; end if;
        v_quantity := (v_item ->> 'qty')::integer;
        if v_quantity < 1 or v_quantity > 50 then raise exception 'Cantidad invalida'; end if;
        select * into v_product from public.products
        where id::text = v_item ->> 'id' and restaurant_id = p_restaurant_id and is_available;
        if not found then raise exception 'Un producto ya no esta disponible'; end if;
        v_items := v_items || jsonb_build_array(jsonb_build_object(
            'id', v_product.id, 'nombre', v_product.name, 'price', v_product.price, 'qty', v_quantity
        ));
        v_total := v_total + v_product.price * v_quantity;
    end loop;
    insert into public.orders (
        customer_id, restaurant_id, restaurant_name, items, total, notes, status,
        payment_method, payment_status, order_source, service_type, table_id, created_by, waiter_name
    ) values (
        null, p_restaurant_id, v_restaurant.business_name, v_items, round(v_total, 2),
        nullif(left(trim(coalesce(p_notes, '')), 500), ''), 'pendiente', p_payment_method,
        'pending', 'pos', p_service_type, p_table_id, v_user_id, v_creator.full_name
    ) returning * into v_order;
    return to_jsonb(v_order);
end;
$$;

create or replace function public.mark_pos_order_paid(p_order_id bigint, p_payment_method text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_order public.orders%rowtype;
begin
    if p_payment_method not in ('cash', 'transfer', 'card_terminal') then raise exception 'Metodo de pago invalido'; end if;
    select * into v_order from public.orders where id = p_order_id for update;
    if not found or v_order.order_source <> 'pos' then raise exception 'Pedido de punto de venta no encontrado'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id, 'close_accounts') then
        raise exception 'Solo caja o el propietario pueden cerrar cuentas';
    end if;
    if v_order.status = 'cancelado' then raise exception 'No se puede cobrar un pedido cancelado'; end if;
    if v_order.payment_status = 'approved' then raise exception 'Este pedido ya fue pagado'; end if;
    update public.orders set payment_method = p_payment_method, payment_status = 'approved'
    where id = p_order_id returning * into v_order;
    return to_jsonb(v_order);
end;
$$;

create or replace function public.update_kitchen_order_status(p_order_id bigint, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_order public.orders%rowtype;
begin
    select * into v_order from public.orders where id = p_order_id for update;
    if not found then raise exception 'Pedido no encontrado'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id, 'view_kitchen') then
        raise exception 'No tienes permiso para actualizar cocina';
    end if;
    if p_status not in ('preparando', 'listo', 'entregado') then raise exception 'Estado invalido'; end if;
    if (v_order.status = 'pendiente' and p_status <> 'preparando')
       or (v_order.status = 'preparando' and p_status <> 'listo')
       or (v_order.status = 'listo' and p_status <> 'entregado') then
        raise exception 'El cambio de estado no es valido';
    end if;
    update public.orders set
        status = p_status,
        ready_at = case when p_status = 'listo' then now() else ready_at end,
        delivered_at = case when p_status = 'entregado' then now() else delivered_at end,
        closed_at = case when p_status = 'entregado' then now() else closed_at end
    where id = p_order_id returning * into v_order;
    return to_jsonb(v_order);
end;
$$;

commit;
