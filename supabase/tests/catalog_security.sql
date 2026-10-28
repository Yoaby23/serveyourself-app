-- No user data is changed. Exercise SQL privileges as both API roles.
do $$
declare r text; v text; denied boolean;
begin
 assert not exists(select 1 from information_schema.role_table_grants where table_schema='public' and grantee in ('anon','authenticated','PUBLIC') and privilege_type in ('TRUNCATE','TRIGGER','REFERENCES')),'Unnecessary client administrative privileges';
 foreach r in array array['anon','authenticated'] loop
  foreach v in array array['public_restaurants','public_qr_restaurants','public_qr_products'] loop
   assert has_table_privilege(r,'public.'||v,'SELECT'), 'Catalog no longer readable';
   assert not has_any_column_privilege(r,'public.'||v,'UPDATE'), 'Writable catalog column';
   assert not has_any_column_privilege(r,'public.'||v,'INSERT'), 'Insertable catalog column';
   assert not has_table_privilege(r,'public.'||v,'DELETE'), 'Deletable catalog';
   execute format('set local role %I',r);
   execute format('select id from public.%I limit 0',v);
   denied:=false;
   begin execute format('update public.%I set id=id where false',v);
   exception when insufficient_privilege then denied:=true; end;
   assert denied, 'Catalog update accepted';
   denied:=false;
   begin execute format('delete from public.%I where false',v);
   exception when insufficient_privilege then denied:=true; end;
   assert denied, 'Catalog delete accepted';
   denied:=false;
   begin execute format('insert into public.%I (id) select null::uuid where false',v);
   exception when insufficient_privilege then denied:=true; end;
   assert denied, 'Catalog insert accepted';
   execute 'reset role';
  end loop;
 end loop;
 assert not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and relkind='r' and not relrowsecurity),'Public table without RLS';
 assert not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and has_function_privilege('anon',p.oid,'EXECUTE')),'Anonymous definer RPC';
end $$;
