-- API roles never need schema-management or whole-table deletion privileges.
revoke truncate, references, trigger on all tables in schema public from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke truncate, references, trigger on tables from public, anon, authenticated;

-- Revoked staff must not retain ticket access solely because they created a round.
alter policy kitchen_tickets_staff_read on public.kitchen_tickets
using (public.has_restaurant_permission(restaurant_id,'view_kitchen')
 or (created_by=(select auth.uid()) and public.has_restaurant_permission(restaurant_id,'create_orders'))
 or public.has_restaurant_permission(restaurant_id,'close_accounts'));
alter policy kitchen_ticket_stations_staff_read on public.kitchen_ticket_station_statuses
using (public.has_restaurant_permission(restaurant_id,'view_kitchen')
 or (public.has_restaurant_permission(restaurant_id,'create_orders') and exists
 (select 1 from public.kitchen_tickets t where t.id=ticket_id and t.created_by=(select auth.uid()))));
