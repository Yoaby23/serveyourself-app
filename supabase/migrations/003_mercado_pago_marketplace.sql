-- Mercado Pago Marketplace: cada restaurante cobra con su propia cuenta OAuth.
-- Ejecutar después de 002_platform_features.sql.

begin;

alter table public.profiles
    add column if not exists mercado_pago_connected boolean not null default false;

alter table public.orders
    add column if not exists mercado_pago_payment_id text;

create table if not exists public.restaurant_payment_accounts (
    restaurant_id uuid primary key references public.profiles(id) on delete cascade,
    provider_user_id text not null,
    access_token text not null,
    refresh_token text,
    token_expires_at timestamptz,
    connected_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.mercado_pago_oauth_states (
    state uuid primary key default gen_random_uuid(),
    restaurant_id uuid not null references public.profiles(id) on delete cascade,
    code_verifier text not null,
    expires_at timestamptz not null default (now() + interval '10 minutes'),
    consumed_at timestamptz
);

alter table public.restaurant_payment_accounts enable row level security;
alter table public.mercado_pago_oauth_states enable row level security;
revoke all on public.restaurant_payment_accounts from anon, authenticated;
revoke all on public.mercado_pago_oauth_states from anon, authenticated;
grant all on public.restaurant_payment_accounts to service_role;
grant all on public.mercado_pago_oauth_states to service_role;

create or replace view public.public_restaurants as
select
    id, business_name, address, open_time, close_time, avatar_url, rating,
    latitude, longitude, timezone, accepting_orders,
    payment_cash, payment_transfer, payment_online,
    bank_name, bank_account_holder, bank_clabe,
    mercado_pago_connected
from public.profiles
where role = 'negocio';

grant select on public.public_restaurants to authenticated;

create or replace function public.protect_mercado_pago_connection_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.mercado_pago_connected is distinct from old.mercado_pago_connected
       and current_user not in ('service_role', 'postgres', 'supabase_admin') then
        raise exception 'El estado de Mercado Pago solo puede cambiarse desde la conexión segura';
    end if;
    return new;
end;
$$;

revoke all on function public.protect_mercado_pago_connection_status() from public, anon, authenticated;

drop trigger if exists protect_mercado_pago_connection_status on public.profiles;
create trigger protect_mercado_pago_connection_status
before update on public.profiles
for each row execute function public.protect_mercado_pago_connection_status();

create or replace function public.validate_mercado_pago_order()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.payment_method = 'mercado_pago' and not exists (
        select 1 from public.profiles
        where id = new.restaurant_id
          and payment_online = true
          and mercado_pago_connected = true
    ) then
        raise exception 'El restaurante no tiene Mercado Pago conectado';
    end if;
    return new;
end;
$$;

revoke all on function public.validate_mercado_pago_order() from public, anon, authenticated;

drop trigger if exists validate_mercado_pago_before_order on public.orders;
create trigger validate_mercado_pago_before_order
before insert on public.orders
for each row execute function public.validate_mercado_pago_order();

commit;
