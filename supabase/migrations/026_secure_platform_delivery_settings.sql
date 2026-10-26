-- Hardening: platform delivery settings must never be readable or writable by client roles.
-- Runtime code accesses these settings through SECURITY DEFINER functions owned by the
-- database owner; the browser does not need direct table or helper-function access.

begin;

alter table public.platform_delivery_settings enable row level security;

revoke all privileges on table public.platform_delivery_settings
  from public, anon, authenticated;

-- This helper is an internal implementation detail used by trusted database routines.
-- Prevent direct RPC calls from anonymous and authenticated clients.
revoke all privileges on function public.calculate_driver_earning(numeric)
  from public, anon, authenticated;

commit;
