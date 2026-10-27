begin;
-- Only canonical order entrypoints are public. Nested SECURITY DEFINER callers
-- retain owner privileges; legacy helpers remain available internally.
revoke execute on function public.create_order(uuid,jsonb,text) from public,anon,authenticated;
revoke execute on function public.create_order_v2(uuid,jsonb,text,text) from public,anon,authenticated;
revoke execute on function public.create_pos_order(uuid,jsonb,text,text,bigint,text) from public,anon,authenticated;
revoke execute on function public.append_pos_order_items(bigint,jsonb,text) from public,anon,authenticated;
revoke execute on function public.create_or_append_pos_order(uuid,jsonb,text,text,bigint,text) from public,anon,authenticated;
revoke execute on function public.update_kitchen_order_status(bigint,text) from public,anon,authenticated;
revoke execute on function public.update_kitchen_station_status(bigint,text,text) from public,anon,authenticated;
-- Column grants survive REVOKE UPDATE ON TABLE; remove both paths explicitly.
revoke update on public.orders from public,anon,authenticated;
revoke update(status,ready_at,delivered_at,cancellation_reason,cancelled_by) on public.orders from public,anon,authenticated;
commit;
