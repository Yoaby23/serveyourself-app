begin;

alter table public.orders add column if not exists kitchen_items jsonb;

update public.orders
set kitchen_items=items
where kitchen_items is null and order_source='pos' and status in ('pendiente','preparando','listo');

-- Una cuenta sigue abierta aunque tenga abonos, mientras no se haya liquidado.
create or replace function public.append_pos_order_items(p_order_id bigint, p_items jsonb, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.orders%rowtype; v_item jsonb; v_product public.products%rowtype; v_qty integer; v_added jsonb:='[]'::jsonb; v_total numeric:=0;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' or v_order.payment_status='approved' or v_order.status='cancelado' then raise exception 'La cuenta no esta abierta'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'create_orders') then raise exception 'Sin permiso para agregar productos'; end if;
    if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 then raise exception 'Agrega productos'; end if;
    for v_item in select value from jsonb_array_elements(p_items) loop
        v_qty := (v_item->>'qty')::integer;
        select * into v_product from public.products where id::text=v_item->>'id' and restaurant_id=v_order.restaurant_id and is_available;
        if not found or v_qty<1 or v_qty>50 then raise exception 'Producto o cantidad invalida'; end if;
        v_added:=v_added||jsonb_build_array(jsonb_build_object('id',v_product.id,'nombre',v_product.name,'price',v_product.price,'qty',v_qty,'station_id',v_product.kitchen_station_id));
        v_total:=v_total+v_product.price*v_qty;
    end loop;
    update public.orders set items=items||v_added,kitchen_items=case when v_order.status in ('listo','entregado') then v_added else coalesce(kitchen_items,'[]'::jsonb)||v_added end,total=total+v_total,notes=coalesce(nullif(left(trim(coalesce(p_notes,'')),500),''),notes),status='pendiente',payment_status='pending',ready_at=null,delivered_at=null,closed_at=null
    where id=p_order_id returning * into v_order;
    update public.order_station_statuses
    set status='pendiente',updated_at=now()
    where order_id=p_order_id and station_key in (
        select distinct coalesce(p.kitchen_station_id::text,'general')
        from jsonb_array_elements(v_order.kitchen_items) i
        join public.products p on p.id::text=i->>'id'
    );
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id) values(p_order_id,v_order.restaurant_id,'items_added',jsonb_build_object('items',v_added,'amount',v_total),auth.uid());
    return to_jsonb(v_order);
end; $$;

revoke all on function public.append_pos_order_items(bigint,jsonb,text) from public,anon;
grant execute on function public.append_pos_order_items(bigint,jsonb,text) to authenticated;

-- La decisión de crear o reutilizar cuenta ocurre dentro de una transacción.
-- El bloqueo evita dos cuentas si dos meseros envían la misma mesa a la vez.
create or replace function public.create_or_append_pos_order(
    p_restaurant_id uuid,
    p_items jsonb,
    p_notes text default null,
    p_service_type text default 'pickup',
    p_table_id bigint default null,
    p_payment_method text default 'cash'
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order_id bigint; v_result jsonb;
begin
    if p_service_type = 'dine_in' then
        if p_table_id is null then raise exception 'Selecciona una mesa activa'; end if;
        perform pg_advisory_xact_lock(hashtextextended(p_restaurant_id::text || ':' || p_table_id::text, 0));
        select id into v_order_id
        from public.orders
        where restaurant_id=p_restaurant_id and table_id=p_table_id and order_source='pos'
          and payment_status='pending' and status<>'cancelado'
        order by created_at
        limit 1;
    end if;

    if v_order_id is not null then
        v_result:=public.append_pos_order_items(v_order_id,p_items,p_notes);
        return v_result||jsonb_build_object('was_appended',true);
    end if;

    v_result:=public.create_pos_order(p_restaurant_id,p_items,p_notes,p_service_type,p_table_id,p_payment_method);
    update public.orders o set kitchen_items=p_items where o.id=(v_result->>'id')::bigint returning to_jsonb(o.*) into v_result;
    return v_result||jsonb_build_object('was_appended',false);
end; $$;

revoke all on function public.create_or_append_pos_order(uuid,jsonb,text,text,bigint,text) from public,anon;
grant execute on function public.create_or_append_pos_order(uuid,jsonb,text,text,bigint,text) to authenticated;

commit;
