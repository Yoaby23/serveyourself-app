-- Stock changes lock a child first; key-share avoids waiting on a parent's metadata update.
create or replace function public.normalize_product_variation() returns trigger language plpgsql security definer set search_path='' as $$
declare parent public.products%rowtype;
begin
 if new.parent_product_id is not null then
  select * into parent from public.products where id=new.parent_product_id for key share;
  if not found or parent.parent_product_id is not null or parent.restaurant_id<>new.restaurant_id then raise exception 'La variación debe pertenecer a un producto del mismo negocio';end if;
  if tg_op='UPDATE' and (old.parent_product_id is distinct from new.parent_product_id or old.restaurant_id<>new.restaurant_id) then raise exception 'No se puede mover una variación a otro producto';end if;
  new.variation_name:=regexp_replace(trim(new.variation_name),'\s+',' ','g');new.name:=parent.name||' · '||new.variation_name;
  new.category:=parent.category;new.kitchen_station_id:=parent.kitchen_station_id;new.image_url:=parent.image_url;new.has_variations:=false;
 end if;
 return new;
end;$$;
