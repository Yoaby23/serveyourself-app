do $$
declare owner_id uuid:=gen_random_uuid();other_id uuid:=gen_random_uuid();product_id uuid;station_id bigint;blocked boolean;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(owner_id,'qa-'||owner_id||'@example.invalid','{"role":"negocio","business_name":"Category QA"}'),(other_id,'qa-'||other_id||'@example.invalid','{"role":"negocio","business_name":"Other QA"}');
 insert into public.products(restaurant_id,name,price,category,is_available) values(owner_id,'Sopa',50,'General',false) returning id into product_id;
 insert into public.kitchen_stations(restaurant_id,name) values(owner_id,'Cocina') returning id into station_id;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 execute 'set local role authenticated';
 insert into public.menu_categories(restaurant_id,name) values(owner_id,'Entradas'),(owner_id,'Bebidas');
 blocked:=false;begin insert into public.menu_categories(restaurant_id,name) values(owner_id,'entradas');exception when unique_violation then blocked:=true;end;assert blocked,'Duplicate category accepted';
 blocked:=false;begin insert into public.menu_categories(restaurant_id,name) values(other_id,'Wrong owner');exception when insufficient_privilege then blocked:=true;end;assert blocked,'Cross-restaurant category allowed';
 update public.products set category='Entradas',name='Sopa grande',price=75,kitchen_station_id=station_id where id=product_id and restaurant_id=owner_id;
 assert exists(select 1 from public.products where id=product_id and category='Entradas' and name='Sopa grande' and price=75 and kitchen_station_id=station_id and not is_available),'Owner editing failed';
 perform set_config('request.jwt.claim.sub',other_id::text,true);
 assert not exists(select 1 from public.menu_categories where restaurant_id=owner_id),'Other owner can read category registry';
 update public.products set category='Bebidas' where id=product_id;
 execute 'reset role';
 assert (select category='Entradas' from public.products where id=product_id),'Other owner edited product';
end;$$;
