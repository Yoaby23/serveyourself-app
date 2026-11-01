create or replace function public.mark_kitchen_ticket_delivered(p_ticket_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ticket public.kitchen_tickets%rowtype;
begin
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id;
    if found then perform 1 from public.orders where id=v_ticket.order_id for update;end if;
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id for update;
    if not found then raise exception 'Comanda no encontrada';end if;
    if v_ticket.status<>'listo' then raise exception 'La comanda ya no esta lista para entregar';end if;
    if auth.uid() is null or not (
        public.has_restaurant_permission(v_ticket.restaurant_id,'create_orders')
        or public.has_restaurant_permission(v_ticket.restaurant_id,'close_accounts')
        or public.has_restaurant_permission(v_ticket.restaurant_id,'view_kitchen')
    ) then raise exception 'No tienes permiso para entregar esta comanda';end if;
    if exists(select 1 from public.orders where id=v_ticket.order_id and status='cancelado') then
        raise exception 'El pedido está cancelado';
    end if;
    update public.kitchen_ticket_station_statuses set status='entregado',updated_at=now() where ticket_id=p_ticket_id;
    update public.kitchen_tickets set status='entregado',delivered_at=coalesce(delivered_at,now()) where id=p_ticket_id returning * into v_ticket;
    perform public.refresh_order_kitchen_status(v_ticket.order_id);
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    values(v_ticket.order_id,v_ticket.restaurant_id,'kitchen_ticket_delivered',jsonb_build_object('ticket_id',v_ticket.id),auth.uid());
    return to_jsonb(v_ticket);
end; $$;
