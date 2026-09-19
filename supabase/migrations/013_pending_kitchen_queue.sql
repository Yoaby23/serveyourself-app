begin;

-- Recupera los productos de cuentas POS que todavia estan activas. La migracion
-- anterior conservaba solo la ultima ronda en kitchen_items.
update public.orders
set kitchen_items=items
where order_source='pos'
  and status in ('pendiente','preparando')
  and payment_status='pending'
  and ready_at is null
  and delivered_at is null
  and coalesce(jsonb_array_length(kitchen_items),0) < jsonb_array_length(items);

-- Cada ronda nueva se suma a la cola visible de cocina, sin reemplazar las
-- comandas que siguen pendientes en esa misma cuenta.
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
    update public.orders set
      items=items||v_added,
      kitchen_items=case when v_order.status in ('listo','entregado') then v_added else coalesce(kitchen_items,'[]'::jsonb)||v_added end,
      total=total+v_total,
      notes=coalesce(nullif(left(trim(coalesce(p_notes,'')),500),''),notes),
      status='pendiente',payment_status='pending',ready_at=null,delivered_at=null,closed_at=null
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

-- Al entregar toda la comanda se limpia la cola de cocina. El historial y el
-- total de la cuenta permanecen completos en orders.items.
create or replace function public.update_kitchen_station_status(p_order_id bigint, p_station_key text, p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_station public.order_station_statuses%rowtype; v_order_status text;
begin
    select * into v_station from public.order_station_statuses where order_id=p_order_id and station_key=p_station_key for update;
    if not found then raise exception 'Estacion de la comanda no encontrada'; end if;
    if not public.has_restaurant_permission(v_station.restaurant_id,'view_kitchen') then raise exception 'Sin permiso de cocina'; end if;
    if (v_station.status='pendiente' and p_status<>'preparando') or (v_station.status='preparando' and p_status<>'listo') or (v_station.status='listo' and p_status<>'entregado') then raise exception 'Cambio de estado invalido'; end if;
    update public.order_station_statuses set status=p_status,updated_at=now() where order_id=p_order_id and station_key=p_station_key returning * into v_station;
    select case
      when bool_and(status='entregado') then 'entregado'
      when bool_and(status in ('listo','entregado')) then 'listo'
      when bool_or(status in ('preparando','listo','entregado')) then 'preparando'
      else 'pendiente' end into v_order_status
    from public.order_station_statuses where order_id=p_order_id;
    update public.orders set status=v_order_status,
      ready_at=case when v_order_status='listo' then coalesce(ready_at,now()) else ready_at end,
      delivered_at=case when v_order_status='entregado' then coalesce(delivered_at,now()) else delivered_at end,
      closed_at=case when v_order_status='entregado' then coalesce(closed_at,now()) else closed_at end,
      kitchen_items=case when v_order_status='entregado' then '[]'::jsonb else kitchen_items end
    where id=p_order_id;
    return to_jsonb(v_station)||jsonb_build_object('order_status',v_order_status);
end; $$;

create or replace function public.update_kitchen_order_status(p_order_id bigint, p_status text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.orders%rowtype;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found then raise exception 'Pedido no encontrado'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'view_kitchen') then raise exception 'No tienes permiso para actualizar cocina'; end if;
    if p_status not in ('preparando','listo','entregado') then raise exception 'Estado invalido'; end if;
    if (v_order.status='pendiente' and p_status<>'preparando') or (v_order.status='preparando' and p_status<>'listo') or (v_order.status='listo' and p_status<>'entregado') then raise exception 'El cambio de estado no es valido'; end if;
    update public.order_station_statuses set status=p_status,updated_at=now() where order_id=p_order_id;
    update public.orders set status=p_status,
      ready_at=case when p_status='listo' then coalesce(ready_at,now()) else ready_at end,
      delivered_at=case when p_status='entregado' then coalesce(delivered_at,now()) else delivered_at end,
      closed_at=case when p_status='entregado' then coalesce(closed_at,now()) else closed_at end,
      kitchen_items=case when p_status='entregado' then '[]'::jsonb else kitchen_items end
    where id=p_order_id returning * into v_order;
    return to_jsonb(v_order);
end; $$;

revoke all on function public.append_pos_order_items(bigint,jsonb,text),
    public.update_kitchen_station_status(bigint,text,text),
    public.update_kitchen_order_status(bigint,text) from public,anon;
grant execute on function public.append_pos_order_items(bigint,jsonb,text),
    public.update_kitchen_station_status(bigint,text,text),
    public.update_kitchen_order_status(bigint,text) to authenticated;

commit;
