begin;
alter table public.orders add column pickup_name text;
alter table public.orders add constraint pickup_name_length check(pickup_name is null or char_length(trim(pickup_name)) between 1 and 80);
create or replace function public.create_pos_table_order(p_restaurant_id uuid,p_items jsonb,p_notes text,p_service_type text,p_table_id bigint,p_payment_method text,p_existing_order_id bigint,p_customer_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; customer_name text:=nullif(trim(p_customer_name),'');
begin
 if auth.uid() is null or not public.has_restaurant_permission(p_restaurant_id,'create_orders') then raise exception 'Sin permiso para crear comandas';end if;
 if p_service_type='pickup' and (customer_name is null or char_length(customer_name)>80) then raise exception 'Escribe el nombre de quien recoge (máximo 80 caracteres)';end if;
 result:=public.create_pos_table_order(p_restaurant_id,p_items,p_notes,p_service_type,p_table_id,p_payment_method,p_existing_order_id);
 if p_service_type='pickup' then
  update public.orders set pickup_name=customer_name where id=(result->>'id')::bigint;
  result:=result||jsonb_build_object('pickup_name',customer_name);
 end if;
 return result;
end;$$;
revoke all on function public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint) from public,anon,authenticated;
revoke all on function public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint,text) from public,anon;
grant execute on function public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint,text) to authenticated;
do $$
declare definition text;
begin
 definition:=pg_get_functiondef('public.list_kitchen_priority_queue(uuid)'::regprocedure);
 definition:=replace(definition,'select t.*,o.scheduled_for','select t.*,o.pickup_name,o.scheduled_for');
 execute definition;
 definition:=pg_get_functiondef('public.split_pos_order(bigint,jsonb)'::regprocedure);
 definition:=replace(definition,'waiter_name,inventory_deducted)','waiter_name,inventory_deducted,pickup_name)');
 definition:=replace(definition,'v_order.waiter_name,v_order.inventory_deducted)','v_order.waiter_name,v_order.inventory_deducted,v_order.pickup_name)');
 execute definition;
end;$$;
commit;
