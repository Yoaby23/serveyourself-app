-- Current availability contract. Run in BEGIN / ROLLBACK; no fixtures persist.
do $$
declare owner_id uuid:=gen_random_uuid();stranger_id uuid:=gen_random_uuid();product_id uuid;items jsonb;first_round jsonb;next_round jsonb;blocked boolean;queue jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values
 (owner_id,'qa-availability-'||owner_id||'@example.invalid','{"role":"negocio","business_name":"Manual availability QA","full_name":"Owner"}'),
 (stranger_id,'qa-availability-'||stranger_id||'@example.invalid','{"full_name":"Stranger"}');
 update public.profiles set open_time=null,close_time=null,accepting_orders=true where id=owner_id;
 insert into public.products(restaurant_id,name,price) values(owner_id,'Consumible',100) returning id into product_id;
 assert (select is_available from public.products where id=product_id),'New products must be available by default';
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 perform public.open_cash_shift(owner_id,0);
 items:=jsonb_build_array(jsonb_build_object('id',product_id,'qty',1));
 execute 'set local role authenticated';
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'   ');exception when others then blocked:=true;end;
 assert blocked,'Pickup accepted blank name';
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,repeat('x',81));exception when others then blocked:=true;end;
 assert blocked,'Pickup accepted oversized name';
 first_round:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'QA Cliente');
 assert first_round->>'pickup_name'='QA Cliente','Pickup name not returned';
 assert (select pickup_name='QA Cliente' from public.orders where id=(first_round->>'id')::bigint),'Pickup name not persisted';
 perform public.set_product_availability(product_id,false);
 assert not exists(select 1 from public.public_qr_products where id=product_id),'Out of stock product remains in public menu';
 blocked:=false;
 begin perform public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'QA Cliente');exception when others then blocked:=true;end;
 assert blocked,'POS accepted an out of stock product';
 blocked:=false;
 begin perform public.create_customer_order_once(gen_random_uuid(),jsonb_build_object('service_type','pickup','restaurant_id',owner_id,'items',items,'payment_method','cash'));exception when others then blocked:=true;end;
 assert blocked,'Customer accepted an out of stock product';
 -- Accepted tickets still progress when a product is subsequently marked unavailable.
 perform public.update_kitchen_ticket_status((first_round->>'kitchen_ticket_id')::bigint,'preparando');
 perform public.update_kitchen_ticket_status((first_round->>'kitchen_ticket_id')::bigint,'listo');
 perform public.set_product_availability(product_id,true);
 assert exists(select 1 from public.public_qr_products where id=product_id),'Reactivated product absent from public menu';
 next_round:=public.create_pos_table_order(owner_id,items,null,'pickup',null,'cash',null,'QA Cliente');
 perform public.set_kitchen_ticket_priority((next_round->>'kitchen_ticket_id')::bigint,2,'QA');
 queue:=public.list_kitchen_priority_queue(owner_id);
 assert queue->0->>'pickup_name'='QA Cliente','Kitchen missing pickup name';
 assert jsonb_array_length(queue)=1,'Queue lost pending ticket';
 assert (queue->0->>'priority_override')::integer=2,'Manual priority lost';
 assert not ((queue->0) ? 'missing_ingredients'),'Queue still exposes ingredients';
 next_round:=public.create_pos_table_order(owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',2)),null,'pickup',null,'cash',null,'Nombre dividido');
 queue:=public.split_pos_order((next_round->>'id')::bigint,items);
 assert queue->'new_order'->>'pickup_name'='Nombre dividido','Split lost pickup name';
 blocked:=false;
 begin perform public.transfer_pos_order((next_round->>'id')::bigint,null,null,'');exception when others then blocked:=true;end;
 assert blocked,'Transfer accepted empty pickup name';
 queue:=public.transfer_pos_order((next_round->>'id')::bigint,null,null,'Nombre actualizado');
 assert queue->>'pickup_name'='Nombre actualizado','Transfer lost pickup name';
 perform set_config('request.jwt.claim.sub',stranger_id::text,true);
 blocked:=false;
 begin perform public.set_product_availability(product_id,false);exception when others then blocked:=true;end;
 assert blocked,'Unrelated account can change availability';
 execute 'reset role';
 assert to_regclass('public.ingredients') is null;
 assert to_regclass('public.product_recipes') is null;
 assert to_regclass('public.inventory_movements') is null;
end;$$;
