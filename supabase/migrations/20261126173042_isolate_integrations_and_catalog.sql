begin;

create schema if not exists sy_private;
revoke all on schema sy_private from public, anon, authenticated;
grant usage on schema sy_private to anon, authenticated;

-- Keep the existing catalog shape for cached clients. Instructions are scoped to an order.
create function sy_private.get_order_transfer_details(p_order_id bigint)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'bank_name', p.bank_name,
        'bank_account_holder', p.bank_account_holder,
        'bank_clabe', p.bank_clabe,
        'phone', p.phone
    )
    from public.orders o
    join public.profiles p on p.id = o.restaurant_id
    where o.id = p_order_id
      and o.customer_id = (select auth.uid())
      and o.payment_method = 'transfer'
      and o.payment_status = 'pending'
      and o.status not in ('cancelado', 'entregado')
      and (o.payment_expires_at is null or o.payment_expires_at > now());
$$;

create function public.get_order_transfer_details(p_order_id bigint)
returns jsonb
language sql stable security invoker
set search_path = ''
as $$
    select sy_private.get_order_transfer_details(p_order_id);
$$;

revoke all on function sy_private.get_order_transfer_details(bigint),
    public.get_order_transfer_details(bigint) from public, anon, authenticated;
grant execute on function sy_private.get_order_transfer_details(bigint),
    public.get_order_transfer_details(bigint) to authenticated;

create table sy_private.integration_settings (
    id boolean primary key default true check (id),
    notification_url text not null check (
        notification_url ~ '^https://[a-z0-9]+[.]supabase[.]co/functions/v1/send-order-notification$'
        or notification_url = 'http://kong:8000/functions/v1/send-order-notification'
    )
);
alter table sy_private.integration_settings enable row level security;
revoke all on sy_private.integration_settings from public, anon, authenticated;

create or replace function public.dispatch_order_notification(event_id uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
    endpoint text;
begin
    select notification_url into endpoint from sy_private.integration_settings where id;
    if endpoint is null then
        return;
    end if;
    perform net.http_post(
        url := endpoint,
        body := jsonb_build_object('dispatchId', event_id),
        timeout_milliseconds := 15000
    );
exception when others then
    raise warning 'Order notification dispatch deferred';
end;
$$;
revoke all on function public.dispatch_order_notification(uuid) from public, anon, authenticated;

create or replace function public.validate_mercado_pago_order()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.payment_method = 'mercado_pago' then
        perform 1 from public.profiles
        where id = new.restaurant_id and payment_online and mercado_pago_connected
        for share;
        if not found then
            raise exception 'El restaurante no tiene habilitados los pagos con Mercado Pago';
        end if;
    end if;
    return new;
end;
$$;

commit;
