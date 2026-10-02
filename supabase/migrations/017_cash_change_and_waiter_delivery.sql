-- Cobro con efectivo recibido/cambio y entrega de comandas por el mesero.
-- Ejecutar despues de 016_driver_marketplace_and_table_accounts.sql.

begin;

alter table public.order_payments
    add column if not exists cash_received numeric(12,2),
    add column if not exists cash_change numeric(12,2);

update public.order_payments
set cash_received=amount+tip_amount,cash_change=0
where payment_method='cash' and cash_received is null;

alter table public.order_payments drop constraint if exists order_payments_cash_values_check;
alter table public.order_payments add constraint order_payments_cash_values_check check (
    (payment_method='cash' and cash_received is not null and cash_received>=amount+tip_amount and cash_change=cash_received-amount-tip_amount)
    or (payment_method<>'cash' and cash_received is null and cash_change is null)
);

create or replace function public.register_pos_payment_v2(
    p_order_id bigint,
    p_payment_method text,
    p_amount numeric,
    p_tip numeric default 0,
    p_cash_received numeric default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
    v_order public.orders%rowtype;
    v_shift_id uuid;
    v_paid numeric;
    v_methods integer;
    v_tip numeric:=coalesce(p_tip,0);
    v_change numeric;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' then raise exception 'Cuenta no encontrada';end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Solo caja puede cobrar';end if;
    if v_order.status='cancelado' or v_order.payment_status='approved' then raise exception 'La cuenta no admite pagos';end if;
    if p_payment_method not in('cash','transfer','card_terminal') or p_amount<=0 or v_tip<0 then raise exception 'Pago invalido';end if;
    select coalesce(sum(amount),0) into v_paid from public.order_payments where order_id=p_order_id;
    if p_amount>v_order.total-v_paid+0.01 then raise exception 'El abono supera el saldo pendiente';end if;
    if p_payment_method='cash' then
        if p_cash_received is null or p_cash_received<p_amount+v_tip then raise exception 'El efectivo recibido no alcanza para cubrir el cobro y la propina';end if;
        v_change:=round(p_cash_received-p_amount-v_tip,2);
    else
        p_cash_received:=null;
        v_change:=null;
    end if;
    select id into v_shift_id from public.cash_shifts where restaurant_id=v_order.restaurant_id and status='open';
    insert into public.order_payments(order_id,restaurant_id,shift_id,payment_method,amount,tip_amount,cash_received,cash_change,received_by)
    values(p_order_id,v_order.restaurant_id,v_shift_id,p_payment_method,p_amount,v_tip,p_cash_received,v_change,auth.uid());
    select coalesce(sum(amount),0),count(distinct payment_method) into v_paid,v_methods from public.order_payments where order_id=p_order_id;
    update public.orders set
        tip_total=(select coalesce(sum(tip_amount),0) from public.order_payments where order_id=p_order_id),
        payment_status=case when v_paid>=total then 'approved' else 'pending' end,
        payment_method=case when v_methods>1 then 'mixed' else p_payment_method end
    where id=p_order_id returning * into v_order;
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    values(p_order_id,v_order.restaurant_id,'payment',jsonb_build_object('method',p_payment_method,'amount',p_amount,'tip',v_tip,'cash_received',p_cash_received,'cash_change',v_change),auth.uid());
    return to_jsonb(v_order)||jsonb_build_object('paid_total',v_paid,'remaining',greatest(v_order.total-v_paid,0),'cash_received',p_cash_received,'cash_change',v_change);
end; $$;

-- Mantiene compatibles las versiones instaladas que aun llamen la funcion anterior.
create or replace function public.register_pos_payment(p_order_id bigint,p_payment_method text,p_amount numeric,p_tip numeric default 0)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
    return public.register_pos_payment_v2(
        p_order_id,p_payment_method,p_amount,p_tip,
        case when p_payment_method='cash' then p_amount+coalesce(p_tip,0) else null end
    );
end; $$;

create or replace function public.mark_kitchen_ticket_delivered(p_ticket_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ticket public.kitchen_tickets%rowtype;
begin
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id for update;
    if not found then raise exception 'Comanda no encontrada';end if;
    if v_ticket.status<>'listo' then raise exception 'La comanda ya no esta lista para entregar';end if;
    if not (
        v_ticket.created_by=auth.uid()
        or public.has_restaurant_permission(v_ticket.restaurant_id,'create_orders')
        or public.has_restaurant_permission(v_ticket.restaurant_id,'close_accounts')
        or public.has_restaurant_permission(v_ticket.restaurant_id,'view_kitchen')
    ) then raise exception 'No tienes permiso para entregar esta comanda';end if;
    update public.kitchen_ticket_station_statuses set status='entregado',updated_at=now() where ticket_id=p_ticket_id;
    update public.kitchen_tickets set status='entregado',delivered_at=coalesce(delivered_at,now()) where id=p_ticket_id returning * into v_ticket;
    perform public.refresh_order_kitchen_status(v_ticket.order_id);
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    values(v_ticket.order_id,v_ticket.restaurant_id,'kitchen_ticket_delivered',jsonb_build_object('ticket_id',v_ticket.id),auth.uid());
    return to_jsonb(v_ticket);
end; $$;

revoke all on function public.register_pos_payment_v2(bigint,text,numeric,numeric,numeric),public.mark_kitchen_ticket_delivered(bigint) from public,anon;
grant execute on function public.register_pos_payment_v2(bigint,text,numeric,numeric,numeric),public.mark_kitchen_ticket_delivered(bigint) to authenticated;

commit;
