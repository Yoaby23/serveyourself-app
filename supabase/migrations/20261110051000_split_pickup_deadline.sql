CREATE OR REPLACE FUNCTION public.split_pos_order(p_order_id bigint, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.orders%rowtype; v_new public.orders%rowtype; v_item jsonb; v_requested integer; v_original integer; v_selected jsonb:='[]'::jsonb; v_remaining jsonb:='[]'::jsonb; v_split_total numeric:=0;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' or v_order.payment_status<>'pending' or v_order.status='cancelado' then raise exception 'Cuenta no disponible'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Solo caja puede dividir cuentas'; end if;
    if v_order.service_type='pickup' and exists(select 1 from public.kitchen_tickets where order_id=p_order_id and status<>'cancelado') then raise exception 'Divide el pedido antes de enviarlo a cocina';end if;
    if v_order.discount_total>0 then raise exception 'Divide la cuenta antes de aplicar un cupon'; end if;
    if exists(select 1 from public.order_payments where order_id=p_order_id) then raise exception 'Divide la cuenta antes de registrar abonos'; end if;
    if jsonb_typeof(p_items)<>'array' then raise exception 'Seleccion invalida'; end if;
    for v_item in select value from jsonb_array_elements(v_order.items) loop
        v_original:=coalesce((v_item->>'qty')::integer,0);
        select coalesce(sum((x->>'qty')::integer),0) into v_requested from jsonb_array_elements(p_items) x where x->>'id'=v_item->>'id';
        if v_requested<0 or v_requested>v_original then raise exception 'Cantidad invalida para %',v_item->>'nombre'; end if;
        if v_requested>0 then
            v_selected:=v_selected||jsonb_build_array(v_item||jsonb_build_object('qty',v_requested));
            v_split_total:=v_split_total+((v_item->>'price')::numeric*v_requested);
        end if;
        if v_original-v_requested>0 then v_remaining:=v_remaining||jsonb_build_array(v_item||jsonb_build_object('qty',v_original-v_requested)); end if;
    end loop;
    if jsonb_array_length(v_selected)=0 or jsonb_array_length(v_remaining)=0 then raise exception 'La division debe dejar productos en ambas cuentas'; end if;
    update public.orders set items=v_remaining,total=greatest(total-v_split_total,0) where id=p_order_id returning * into v_order;
    insert into public.orders(customer_id,restaurant_id,restaurant_name,items,total,notes,status,payment_method,payment_status,order_source,service_type,table_id,created_by,waiter_name,inventory_deducted,pickup_name,created_at,payment_expires_at)
    values(v_order.customer_id,v_order.restaurant_id,v_order.restaurant_name,v_selected,v_split_total,v_order.notes,v_order.status,'cash','pending','pos',v_order.service_type,v_order.table_id,v_order.created_by,v_order.waiter_name,v_order.inventory_deducted,v_order.pickup_name,v_order.created_at,v_order.payment_expires_at)
    returning * into v_new;
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id) values(p_order_id,v_order.restaurant_id,'split',jsonb_build_object('new_order_id',v_new.id,'amount',v_split_total),auth.uid());
    return jsonb_build_object('original_order',to_jsonb(v_order),'new_order',to_jsonb(v_new));
end; $function$;
