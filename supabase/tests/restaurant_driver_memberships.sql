do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); driver uuid := gen_random_uuid();
  product_a uuid; product_b uuid; own_order bigint; other_order bigint; invite text; blocked boolean := false;
begin
  insert into auth.users(id,email,raw_user_meta_data) values
    (a,a||'@example.invalid','{"role":"negocio","business_name":"QA A"}'),
    (b,b||'@example.invalid','{"role":"negocio","business_name":"QA B"}'),
    (driver,driver||'@example.invalid','{"role":"cliente"}');
  insert into public.products(restaurant_id,name,price) values(a,'QA A',10) returning id into product_a;
  insert into public.products(restaurant_id,name,price) values(b,'QA B',10) returning id into product_b;
  insert into public.orders(restaurant_id,items,total,service_type,delivery_status,payment_method)
    values(a,jsonb_build_array(jsonb_build_object('id',product_a,'name','QA','price',10,'quantity',1)),10,'delivery','accepted','cash') returning id into own_order;
  insert into public.orders(restaurant_id,items,total,service_type,delivery_status,payment_method)
    values(b,jsonb_build_array(jsonb_build_object('id',product_b,'name','QA','price',10,'quantity',1)),10,'delivery','accepted','cash') returning id into other_order;
  perform set_config('request.jwt.claim.sub',a::text,true);
  execute 'set local role authenticated';
  invite := public.create_staff_invite('driver')->>'code';
  perform set_config('request.jwt.claim.sub',driver::text,true);
  begin perform public.register_delivery_driver('QA Driver','1234567890','walking');
  exception when raise_exception then blocked := true; end;
  assert blocked,'Registration without membership succeeded';
  perform public.accept_staff_invite(invite);
  assert public.register_delivery_driver('QA Driver','1234567890','walking')->>'status'='active';
  perform public.set_marketplace_driver_availability(true);
  perform public.set_driver_availability(false);
  assert not (public.get_delivery_driver_profile()->>'is_available')::boolean,'Legacy availability did not use the current profile';
  perform public.set_driver_availability(true);
  assert not exists(select from public.list_delivery_offers());
  assert not exists(select from public.list_delivery_offers() where order_id=other_order);
  blocked := false;
  begin perform public.claim_delivery_order(other_order); exception when raise_exception then blocked := true; end;
  assert blocked,'Claimed another restaurant order';
  blocked:=false;begin perform public.claim_delivery_order(own_order);exception when raise_exception then blocked:=true;end;assert blocked,'Driver self-assigned an order';
  perform set_config('request.jwt.claim.sub',a::text,true);
  assert public.assign_delivery_driver(own_order,driver)->>'assigned_driver_id'=driver::text;
  perform set_config('request.jwt.claim.sub',driver::text,true);
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',a::text,true);
  assert exists(select from public.list_delivery_drivers(a) where user_id=driver);
  assert not exists(select from public.list_delivery_drivers(b) where user_id=driver);
  perform set_config('request.jwt.claim.sub',driver::text,true);
  update public.restaurant_staff set is_active=false where user_id=driver and restaurant_id=a;
  assert not public.is_team_driver(a);
  perform set_config('request.jwt.claim.sub',a::text,true);
  assert not exists(select from public.list_delivery_drivers(a) where user_id=driver);
end;
$$;
