-- ServeYourself v2: ubicación, pagos, cancelaciones, imágenes, métricas y reseñas.
-- Ejecutar después de 001_secure_core.sql.

begin;

alter table public.profiles
    add column if not exists latitude double precision,
    add column if not exists longitude double precision,
    add column if not exists timezone text not null default 'America/Mexico_City',
    add column if not exists accepting_orders boolean not null default true,
    add column if not exists payment_cash boolean not null default true,
    add column if not exists payment_transfer boolean not null default false,
    add column if not exists payment_online boolean not null default false,
    add column if not exists bank_name text,
    add column if not exists bank_account_holder text,
    add column if not exists bank_clabe text;

alter table public.orders
    add column if not exists payment_method text not null default 'cash',
    add column if not exists payment_status text not null default 'pending',
    add column if not exists cancellation_reason text,
    add column if not exists cancelled_by uuid references auth.users(id) on delete set null,
    add column if not exists ready_at timestamptz,
    add column if not exists delivered_at timestamptz,
    add column if not exists mercado_pago_preference_id text;

alter table public.orders drop constraint if exists orders_payment_method_check;
alter table public.orders add constraint orders_payment_method_check
    check (payment_method in ('cash', 'transfer', 'mercado_pago'));

alter table public.orders drop constraint if exists orders_payment_status_check;
alter table public.orders add constraint orders_payment_status_check
    check (payment_status in ('pending', 'approved', 'rejected', 'refunded', 'not_required'));

create table if not exists public.ratings (
    id uuid primary key default gen_random_uuid(),
    order_id bigint not null unique references public.orders(id) on delete cascade,
    customer_id uuid not null references auth.users(id) on delete cascade,
    restaurant_id uuid not null references public.profiles(id) on delete cascade,
    rating integer not null check (rating between 1 and 5),
    comment text check (char_length(comment) <= 500),
    created_at timestamptz not null default now()
);

alter table public.ratings enable row level security;

create or replace view public.public_restaurants as
select
    id, business_name, address, open_time, close_time, avatar_url, rating,
    latitude, longitude, timezone, accepting_orders,
    payment_cash, payment_transfer, payment_online,
    bank_name, bank_account_holder, bank_clabe
from public.profiles
where role = 'negocio';

grant select on public.public_restaurants to authenticated;
grant select on public.ratings to authenticated;
revoke insert, update, delete on public.ratings from anon, authenticated;

revoke update on public.profiles from authenticated;
grant update (
    phone, address, open_time, close_time, avatar_url,
    latitude, longitude, timezone, accepting_orders,
    payment_cash, payment_transfer, payment_online,
    bank_name, bank_account_holder, bank_clabe
) on public.profiles to authenticated;

revoke update on public.orders from authenticated;
grant update (status, ready_at, delivered_at, cancellation_reason, cancelled_by)
on public.orders to authenticated;

drop policy if exists "ratings_read" on public.ratings;
create policy "ratings_read"
on public.ratings for select
to authenticated
using (customer_id = auth.uid() or restaurant_id = auth.uid());

-- Imágenes de productos. Cada negocio solo puede escribir dentro de su carpeta.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'product-images',
    'product-images',
    true,
    5242880,
    array['image/jpeg', 'image/png', 'image/webp', 'image/avif']
)
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "product_images_insert_owner" on storage.objects;
create policy "product_images_insert_owner"
on storage.objects for insert
to authenticated
with check (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (
        select 1 from public.profiles
        where id = auth.uid() and role = 'negocio'
    )
);

drop policy if exists "product_images_update_owner" on storage.objects;
create policy "product_images_update_owner"
on storage.objects for update
to authenticated
using (bucket_id = 'product-images' and owner_id = auth.uid()::text)
with check (bucket_id = 'product-images' and owner_id = auth.uid()::text);

drop policy if exists "product_images_delete_owner" on storage.objects;
create policy "product_images_delete_owner"
on storage.objects for delete
to authenticated
using (bucket_id = 'product-images' and owner_id = auth.uid()::text);

-- Crea pedidos validando horario, métodos de pago, disponibilidad y precios.
create or replace function public.create_order_v2(
    p_restaurant_id uuid,
    p_items jsonb,
    p_notes text default null,
    p_payment_method text default 'cash'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_customer_id uuid := auth.uid();
    restaurant_record public.profiles%rowtype;
    item jsonb;
    product_record public.products%rowtype;
    quantity integer;
    normalized_items jsonb := '[]'::jsonb;
    calculated_total numeric := 0;
    created_order public.orders%rowtype;
    local_time time;
    restaurant_is_open boolean := true;
begin
    if v_customer_id is null then
        raise exception 'Debes iniciar sesión para crear un pedido';
    end if;

    select * into restaurant_record
    from public.profiles
    where id = p_restaurant_id and role = 'negocio';

    if not found then raise exception 'El restaurante no existe'; end if;
    if not restaurant_record.accepting_orders then
        raise exception 'El restaurante no está aceptando pedidos';
    end if;

    if restaurant_record.open_time is not null and restaurant_record.close_time is not null then
        local_time := (now() at time zone restaurant_record.timezone)::time;
        restaurant_is_open := case
            when restaurant_record.open_time <= restaurant_record.close_time
                then local_time between restaurant_record.open_time and restaurant_record.close_time
            else local_time >= restaurant_record.open_time or local_time <= restaurant_record.close_time
        end;
    end if;
    if not restaurant_is_open then raise exception 'El restaurante está cerrado'; end if;

    if p_payment_method not in ('cash', 'transfer', 'mercado_pago') then
        raise exception 'Método de pago inválido';
    end if;
    if p_payment_method = 'cash' and not restaurant_record.payment_cash then
        raise exception 'El restaurante no acepta efectivo';
    end if;
    if p_payment_method = 'transfer' and not restaurant_record.payment_transfer then
        raise exception 'El restaurante no acepta transferencia';
    end if;
    if p_payment_method = 'mercado_pago' and not restaurant_record.payment_online then
        raise exception 'El restaurante no acepta pago en línea';
    end if;

    if jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) < 1
       or jsonb_array_length(p_items) > 50 then
        raise exception 'El pedido debe contener entre 1 y 50 productos';
    end if;

    for item in select value from jsonb_array_elements(p_items)
    loop
        if coalesce(item ->> 'qty', '') !~ '^[0-9]+$' then raise exception 'Cantidad inválida'; end if;
        quantity := (item ->> 'qty')::integer;
        if quantity < 1 or quantity > 50 then raise exception 'Cada cantidad debe estar entre 1 y 50'; end if;

        select * into product_record
        from public.products
        where id::text = item ->> 'id'
          and restaurant_id = p_restaurant_id
          and is_available = true;
        if not found then raise exception 'Uno de los productos no existe o está agotado'; end if;

        normalized_items := normalized_items || jsonb_build_array(jsonb_build_object(
            'id', product_record.id,
            'nombre', product_record.name,
            'price', product_record.price,
            'qty', quantity
        ));
        calculated_total := calculated_total + (product_record.price * quantity);
    end loop;

    insert into public.orders (
        customer_id, restaurant_id, restaurant_name, items, total, notes,
        status, payment_method, payment_status
    ) values (
        v_customer_id, p_restaurant_id, restaurant_record.business_name,
        normalized_items, round(calculated_total, 2),
        nullif(left(trim(coalesce(p_notes, '')), 500), ''),
        'pendiente', p_payment_method,
        case when p_payment_method = 'mercado_pago' then 'pending' else 'not_required' end
    ) returning * into created_order;

    return to_jsonb(created_order);
end;
$$;

revoke all on function public.create_order_v2(uuid, jsonb, text, text) from public, anon;
grant execute on function public.create_order_v2(uuid, jsonb, text, text) to authenticated;

create or replace function public.cancel_order(p_order_id bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_user_id uuid := auth.uid();
    order_record public.orders%rowtype;
begin
    if current_user_id is null then raise exception 'Debes iniciar sesión'; end if;
    select * into order_record from public.orders where id = p_order_id for update;
    if not found then raise exception 'Pedido no encontrado'; end if;
    if current_user_id not in (order_record.customer_id, order_record.restaurant_id) then
        raise exception 'No tienes permiso para cancelar este pedido';
    end if;
    if order_record.status not in ('pendiente', 'preparando') then
        raise exception 'Este pedido ya no puede cancelarse';
    end if;
    if order_record.payment_method = 'mercado_pago' and order_record.payment_status = 'approved' then
        raise exception 'Un pago aprobado requiere un reembolso antes de cancelar';
    end if;
    if current_user_id = order_record.customer_id and order_record.status <> 'pendiente' then
        raise exception 'El cliente solo puede cancelar pedidos pendientes';
    end if;
    if char_length(trim(coalesce(p_reason, ''))) < 3 then
        raise exception 'Indica el motivo de cancelación';
    end if;

    update public.orders set
        status = 'cancelado',
        cancellation_reason = left(trim(p_reason), 300),
        cancelled_by = current_user_id
    where id = p_order_id
    returning * into order_record;
    return to_jsonb(order_record);
end;
$$;

revoke all on function public.cancel_order(bigint, text) from public, anon;
grant execute on function public.cancel_order(bigint, text) to authenticated;

create or replace function public.submit_rating(
    p_order_id bigint,
    p_rating integer,
    p_comment text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_user_id uuid := auth.uid();
    order_record public.orders%rowtype;
    created_rating public.ratings%rowtype;
begin
    if current_user_id is null then raise exception 'Debes iniciar sesión'; end if;
    if p_rating < 1 or p_rating > 5 then raise exception 'Calificación inválida'; end if;

    select * into order_record
    from public.orders
    where id = p_order_id and customer_id = current_user_id and status = 'entregado';
    if not found then raise exception 'Solo puedes calificar pedidos entregados'; end if;

    insert into public.ratings (order_id, customer_id, restaurant_id, rating, comment)
    values (
        p_order_id, current_user_id, order_record.restaurant_id, p_rating,
        nullif(left(trim(coalesce(p_comment, '')), 500), '')
    ) returning * into created_rating;

    update public.profiles set rating = (
        select round(avg(rating)::numeric, 2)
        from public.ratings where restaurant_id = order_record.restaurant_id
    ) where id = order_record.restaurant_id;

    return to_jsonb(created_rating);
end;
$$;

revoke all on function public.submit_rating(bigint, integer, text) from public, anon;
grant execute on function public.submit_rating(bigint, integer, text) to authenticated;

commit;
