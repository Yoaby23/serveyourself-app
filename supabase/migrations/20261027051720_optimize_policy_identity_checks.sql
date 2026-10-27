begin;
set local lock_timeout='5s';
-- Existing tables have only primary keys for these frequent access paths.
create index if not exists orders_restaurant_created_idx on public.orders(restaurant_id,created_at desc);
create index if not exists orders_customer_created_idx on public.orders(customer_id,created_at desc);
create index if not exists orders_driver_created_idx on public.orders(assigned_driver_id,created_at desc);
create index if not exists orders_open_table_idx on public.orders(restaurant_id,table_id,created_at,id) where order_source='pos' and payment_status='pending' and status<>'cancelado';
create index if not exists products_restaurant_idx on public.products(restaurant_id);
create index if not exists restaurant_staff_user_idx on public.restaurant_staff(user_id);
-- Cache the statement-constant identity instead of re-evaluating JWT per row.
-- Keep policy roles, operations and authorization predicates unchanged.
do $$
declare p record; q text; w text; command text;
begin
 for p in select * from pg_policies where schemaname='public' loop
  q:=p.qual; w:=p.with_check;
  if q is not null and strpos(lower(q),'select auth.uid()')=0 then q:=replace(q,'auth.uid()','(select auth.uid())'); end if;
  if w is not null and strpos(lower(w),'select auth.uid()')=0 then w:=replace(w,'auth.uid()','(select auth.uid())'); end if;
  if q is distinct from p.qual or w is distinct from p.with_check then
   command:=format('alter policy %I on %I.%I',p.policyname,p.schemaname,p.tablename);
   if q is not null then command:=command||' using ('||q||')'; end if;
   if w is not null then command:=command||' with check ('||w||')'; end if;
   execute command;
  end if;
 end loop;
end;$$;
commit;
