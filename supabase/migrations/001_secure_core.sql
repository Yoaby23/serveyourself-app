-- Base segura para perfiles, productos y pedidos de ServeYourself.
-- Ejecutar en Supabase SQL Editor antes de desplegar el frontend de esta versión.

begin;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;

alter table public.orders
    add column if not exists customer_id uuid references auth.users(id) on delete set null,
    add column if not exists restaurant_name text;

update public.orders as orders
set restaurant_name = profiles.business_name
from public.profiles as profiles
where orders.restaurant_id = profiles.id
  and orders.restaurant_name is null;

alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders
    add constraint orders_status_check
    check (status in ('pendiente', 'preparando', 'listo', 'entregado', 'cancelado'));

-- La aplicación pública solo necesita estos datos de cada restaurante. La vista
-- evita revelar correo y teléfono de los perfiles mediante consultas generales.
create or replace view public.public_restaurants as
select id, business_name, address, open_time, close_time, avatar_url, rating
from public.profiles
where role = 'negocio';

revoke all on public.profiles from anon;
grant select on public.public_restaurants to authenticated;
grant select, insert on public.profiles to authenticated;
revoke update on public.profiles from authenticated;
grant update (phone, address, open_time, close_time, avatar_url) on public.profiles to authenticated;
grant select, insert, update, delete on public.products to authenticated;
grant select, update, delete on public.orders to authenticated;
revoke insert on public.orders from anon, authenticated;

-- Sustituye cualquier política permisiva creada durante el prototipo.
do $$
declare
    policy_record record;
begin
    for policy_record in
        select schemaname, tablename, policyname
        from pg_policies
        where schemaname = 'public'
          and tablename in ('profiles', 'products', 'orders')
    loop
        execute format(
            'drop policy if exists %I on %I.%I',
            policy_record.policyname,
            policy_record.schemaname,
            policy_record.tablename
        );
    end loop;
end;
$$;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
on public.profiles for select
to authenticated
using (id = auth.uid());

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
on public.profiles for insert
to authenticated
with check (id = auth.uid() and role in ('cliente', 'negocio'));

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid() and role in ('cliente', 'negocio'));

drop policy if exists "products_read" on public.products;
create policy "products_read"
on public.products for select
to authenticated
using (is_available = true or restaurant_id = auth.uid());

drop policy if exists "products_insert_owner" on public.products;
create policy "products_insert_owner"
on public.products for insert
to authenticated
with check (
    restaurant_id = auth.uid()
    and exists (
        select 1 from public.profiles
        where id = auth.uid() and role = 'negocio'
    )
    and price > 0
);

drop policy if exists "products_update_owner" on public.products;
create policy "products_update_owner"
on public.products for update
to authenticated
using (restaurant_id = auth.uid())
with check (restaurant_id = auth.uid() and price > 0);

drop policy if exists "products_delete_owner" on public.products;
create policy "products_delete_owner"
on public.products for delete
to authenticated
using (restaurant_id = auth.uid());

drop policy if exists "orders_read_participants" on public.orders;
create policy "orders_read_participants"
on public.orders for select
to authenticated
using (customer_id = auth.uid() or restaurant_id = auth.uid());

drop policy if exists "orders_update_restaurant" on public.orders;
create policy "orders_update_restaurant"
on public.orders for update
to authenticated
using (restaurant_id = auth.uid())
with check (
    restaurant_id = auth.uid()
    and status in ('pendiente', 'preparando', 'listo', 'entregado', 'cancelado')
);

drop policy if exists "orders_delete_restaurant" on public.orders;
create policy "orders_delete_restaurant"
on public.orders for delete
to authenticated
using (
    restaurant_id = auth.uid()
    and status in ('entregado', 'cancelado')
);

-- Crea el perfil incluso cuando Supabase exige confirmar el correo y todavía no
-- existe una sesión en el navegador.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    requested_role text;
begin
    requested_role := case
        when new.raw_user_meta_data ->> 'role' = 'negocio' then 'negocio'
        else 'cliente'
    end;

    insert into public.profiles (
        id, full_name, email, phone, role, business_name, address,
        open_time, close_time, avatar_url, rating
    ) values (
        new.id,
        left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 120),
        new.email,
        left(coalesce(new.raw_user_meta_data ->> 'phone', ''), 30),
        requested_role,
        case when requested_role = 'negocio' then left(new.raw_user_meta_data ->> 'business_name', 120) end,
        case when requested_role = 'negocio' then left(new.raw_user_meta_data ->> 'address', 250) end,
        case when requested_role = 'negocio' then nullif(new.raw_user_meta_data ->> 'open_time', '')::time end,
        case when requested_role = 'negocio' then nullif(new.raw_user_meta_data ->> 'close_time', '')::time end,
        case when requested_role = 'negocio' then left(new.raw_user_meta_data ->> 'avatar_url', 500) end,
        5.0
    )
    on conflict (id) do nothing;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- Único punto permitido para crear pedidos. El servidor vuelve a consultar cada
-- producto y calcula el total; nunca confía en nombres o precios del navegador.
create or replace function public.create_order(
    p_restaurant_id uuid,
    p_items jsonb,
    p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_customer_id uuid := auth.uid();
    restaurant_name_value text;
    item jsonb;
    product_record public.products%rowtype;
    quantity integer;
    normalized_items jsonb := '[]'::jsonb;
    calculated_total numeric := 0;
    created_order public.orders%rowtype;
begin
    if v_customer_id is null then
        raise exception 'Debes iniciar sesión para crear un pedido';
    end if;

    select business_name
    into restaurant_name_value
    from public.profiles
    where id = p_restaurant_id and role = 'negocio';

    if restaurant_name_value is null then
        raise exception 'El restaurante no existe';
    end if;

    if jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) < 1
       or jsonb_array_length(p_items) > 50 then
        raise exception 'El pedido debe contener entre 1 y 50 productos';
    end if;

    for item in select value from jsonb_array_elements(p_items)
    loop
        if coalesce(item ->> 'qty', '') !~ '^[0-9]+$' then
            raise exception 'Cantidad inválida';
        end if;

        quantity := (item ->> 'qty')::integer;
        if quantity < 1 or quantity > 50 then
            raise exception 'Cada cantidad debe estar entre 1 y 50';
        end if;

        select *
        into product_record
        from public.products
        where id::text = item ->> 'id'
          and restaurant_id = p_restaurant_id
          and is_available = true;

        if not found then
            raise exception 'Uno de los productos no existe o está agotado';
        end if;

        normalized_items := normalized_items || jsonb_build_array(jsonb_build_object(
            'id', product_record.id,
            'nombre', product_record.name,
            'price', product_record.price,
            'qty', quantity
        ));
        calculated_total := calculated_total + (product_record.price * quantity);
    end loop;

    insert into public.orders (
        customer_id, restaurant_id, restaurant_name, items, total, notes, status
    ) values (
        v_customer_id,
        p_restaurant_id,
        restaurant_name_value,
        normalized_items,
        round(calculated_total, 2),
        nullif(left(trim(coalesce(p_notes, '')), 500), ''),
        'pendiente'
    )
    returning * into created_order;

    return to_jsonb(created_order);
end;
$$;

revoke all on function public.create_order(uuid, jsonb, text) from public, anon;
grant execute on function public.create_order(uuid, jsonb, text) to authenticated;

commit;
