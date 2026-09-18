-- Retiene pedidos de Mercado Pago hasta confirmar el cobro y los vence en 20 minutos.
-- Ejecutar despues de 009_remove_invoicing.sql.

begin;

alter table public.orders
    add column if not exists payment_expires_at timestamptz;

alter table public.orders drop constraint if exists orders_payment_status_check;
alter table public.orders add constraint orders_payment_status_check
    check (payment_status in ('pending', 'approved', 'rejected', 'refunded', 'not_required', 'expired'));

update public.orders
set payment_expires_at = created_at + interval '20 minutes'
where payment_method = 'mercado_pago'
  and payment_expires_at is null;

create or replace function public.set_online_payment_expiration()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.payment_method = 'mercado_pago' then
        if new.payment_expires_at is null then
            new.payment_expires_at := coalesce(new.created_at, now()) + interval '20 minutes';
        end if;
    else
        new.payment_expires_at := null;
    end if;
    return new;
end;
$$;

revoke all on function public.set_online_payment_expiration() from public, anon, authenticated;

drop trigger if exists set_online_payment_expiration on public.orders;
create trigger set_online_payment_expiration
before insert or update on public.orders
for each row execute function public.set_online_payment_expiration();

create or replace function public.protect_unpaid_online_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if old.payment_method = 'mercado_pago'
       and old.payment_status <> 'approved'
       and new.status in ('preparando', 'listo', 'entregado') then
        raise exception 'El pedido no puede enviarse a cocina hasta confirmar el pago';
    end if;
    return new;
end;
$$;

revoke all on function public.protect_unpaid_online_order() from public, anon, authenticated;

drop trigger if exists protect_unpaid_online_order on public.orders;
create trigger protect_unpaid_online_order
before update of status on public.orders
for each row execute function public.protect_unpaid_online_order();

create or replace function public.expire_unpaid_online_orders(p_restaurant_id uuid default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := auth.uid();
    v_count bigint;
begin
    if v_user_id is null then raise exception 'Sesion requerida'; end if;

    if p_restaurant_id is not null
       and not public.has_restaurant_permission(p_restaurant_id, 'close_accounts') then
        raise exception 'Sin permiso para revisar pagos';
    end if;

    update public.orders
    set payment_status = 'expired',
        status = 'cancelado',
        cancellation_reason = 'Tiempo de pago agotado (20 minutos)',
        cancelled_by = null
    where payment_method = 'mercado_pago'
      and payment_status = 'pending'
      and mercado_pago_payment_id is null
      and coalesce(payment_expires_at, created_at + interval '20 minutes') <= now()
      and (
          (p_restaurant_id is null and customer_id = v_user_id)
          or (p_restaurant_id is not null and restaurant_id = p_restaurant_id)
      );

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

revoke all on function public.expire_unpaid_online_orders(uuid) from public, anon;
grant execute on function public.expire_unpaid_online_orders(uuid) to authenticated;

commit;
