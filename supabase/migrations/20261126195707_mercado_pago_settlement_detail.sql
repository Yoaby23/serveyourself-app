begin;

alter table public.online_payment_events
    add column provider_fee numeric(12,2) check (provider_fee >= 0),
    add column provider_vat numeric(12,2) check (provider_vat >= 0),
    add column provider_net numeric(12,2) check (provider_net >= 0),
    add column available_at timestamptz;

grant select on public.online_payment_events to service_role;
grant update (provider_fee, provider_vat, provider_net, available_at) on public.online_payment_events to service_role;

notify pgrst, 'reload schema';

commit;
