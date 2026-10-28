-- Catalog projections are intentionally public READ APIs, never mutation APIs.
-- Owner-executed views must not inherit the project's default write grants.
revoke all privileges on public.public_restaurants, public.public_qr_restaurants, public.public_qr_products from public, anon, authenticated;
-- Remove possible explicit column grants as well as table grants.
do $$
declare v record; r text;
begin
 for v in select c.relname, string_agg(quote_ident(a.attname), ',') as cols
 from pg_class c join pg_namespace n on n.oid=c.relnamespace
 join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
 where n.nspname='public' and c.relname in ('public_restaurants','public_qr_restaurants','public_qr_products')
 group by c.relname loop
  foreach r in array array['public','anon','authenticated'] loop
   execute format('revoke insert (%s), update (%s), references (%s), select (%s) on public.%I from %I',v.cols,v.cols,v.cols,v.cols,v.relname,r);
  end loop;
 end loop;
end $$;
grant select on public.public_restaurants, public.public_qr_restaurants, public.public_qr_products to anon, authenticated;
