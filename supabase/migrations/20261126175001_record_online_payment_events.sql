begin;

create table public.online_payment_events (
    id bigint generated always as identity primary key,
    restaurant_id uuid not null references public.profiles(id),
    order_id bigint not null references public.orders(id),
    provider_payment_id text not null,
    event_type text not null check (event_type in ('approved','refunded')),
    amount numeric(12,2) not null check (amount >= 0),
    happened_at timestamptz not null,
    unique (order_id,provider_payment_id,event_type)
);
create index online_payment_events_restaurant_time_idx
    on public.online_payment_events(restaurant_id,happened_at);
alter table public.online_payment_events enable row level security;
revoke all on public.online_payment_events from public,anon,authenticated;
grant select on public.online_payment_events to authenticated;
create policy online_payment_events_cashier_read on public.online_payment_events
    for select to authenticated
    using (public.has_restaurant_permission(restaurant_id,'close_accounts'));

create or replace function sy_private.record_online_payment_event()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
    if new.payment_method = 'mercado_pago'
       and new.payment_status in ('approved','refunded')
       and new.mercado_pago_payment_id is not null then
        insert into public.online_payment_events
            (restaurant_id,order_id,provider_payment_id,event_type,amount,happened_at)
        values (new.restaurant_id,new.id,new.mercado_pago_payment_id,new.payment_status,
            new.total,coalesce(new.payment_updated_at,now()))
        on conflict (order_id,provider_payment_id,event_type) do nothing;
    end if;
    return new;
end;
$$;
revoke all on function sy_private.record_online_payment_event() from public,anon,authenticated;

create trigger orders_record_online_payment_event
    after insert or update of payment_status, mercado_pago_payment_id on public.orders
    for each row execute function sy_private.record_online_payment_event();

-- Historical orders expose only their latest provider state. Keep that event when dated.
insert into public.online_payment_events
    (restaurant_id,order_id,provider_payment_id,event_type,amount,happened_at)
select restaurant_id,id,mercado_pago_payment_id,payment_status,total,payment_updated_at
from public.orders
where payment_method='mercado_pago' and payment_status in ('approved','refunded')
  and mercado_pago_payment_id is not null and payment_updated_at is not null
on conflict (order_id,provider_payment_id,event_type) do nothing;

commit;
