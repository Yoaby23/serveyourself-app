-- Cancel unpaid pickup requests atomically with cash closing; retain the audit trail.
create or replace function public.close_cash_shift(p_restaurant_id uuid,p_counted_cash numeric,p_notes text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
    v_shift public.cash_shifts%rowtype;v_cash numeric:=0;v_transfer numeric:=0;v_card numeric:=0;
    v_credit numeric:=0;v_credit_cash numeric:=0;v_credit_transfer numeric:=0;v_credit_card numeric:=0;
    v_movements numeric:=0;v_expected numeric:=0;
    v_open_count integer:=0;v_open_labels text;v_cancelled bigint[];v_cutoff timestamptz:=clock_timestamp();
begin
    if not public.has_restaurant_permission(p_restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
    if p_counted_cash is null or p_counted_cash<0 or p_counted_cash::text in ('NaN','Infinity','-Infinity') then raise exception 'El efectivo contado no puede ser negativo';end if;
    p_counted_cash:=round(p_counted_cash,2);
    -- Lock pickup orders before the shift, matching the order -> shift payment lock order.
    -- Requests created after this cutoff belong to the next closing cycle.
    perform id from public.orders where restaurant_id=p_restaurant_id and service_type='pickup'
      and payment_status in ('pending','not_required') and status<>'cancelado' and created_at<=v_cutoff order by id for update;
    select * into v_shift from public.cash_shifts where restaurant_id=p_restaurant_id and status='open' for update;
    if not found then raise exception 'No hay turno abierto';end if;
    select coalesce(array_agg(o.id),'{}'::bigint[]) into v_cancelled from public.orders o
    where o.restaurant_id=p_restaurant_id and o.service_type='pickup' and o.created_at<=v_cutoff
      and o.payment_status in ('pending','not_required') and o.status<>'cancelado'
      and not exists(select 1 from public.order_payments p where p.order_id=o.id)
      and not exists(select 1 from public.customer_credit_transactions c where c.order_id=o.id);
    select count(*),string_agg('#'||o.id::text||case when t.name is not null then ' · '||t.name else ' · Para llevar' end,', ' order by o.id)
      into v_open_count,v_open_labels
    from public.orders o left join public.restaurant_tables t on t.id=o.table_id
    where o.restaurant_id=p_restaurant_id and o.order_source='pos' and o.payment_status='pending' and o.status<>'cancelado' and not(o.id=any(v_cancelled));
    if v_open_count>0 then raise exception 'Hay % cuenta(s) abierta(s): %. Cierra o pasa a credito antes del corte',v_open_count,v_open_labels;end if;
    update public.orders set status='cancelado',cancelled_by=auth.uid(),
      cancellation_reason='Pedido sin pagar cancelado al cerrar el turno de caja',
      payment_expires_at=case when payment_method='mercado_pago' then least(coalesce(payment_expires_at,v_cutoff),v_cutoff) else null end
    where id=any(v_cancelled);
    update public.kitchen_tickets set status='cancelado' where order_id=any(v_cancelled) and status<>'cancelado';
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    select id,p_restaurant_id,'cancelled_at_cash_close',jsonb_build_object('shift_id',v_shift.id,'cutoff',v_cutoff),auth.uid()
    from unnest(v_cancelled) id;
    select
      coalesce(sum(amount+tip_amount) filter(where payment_method='cash'),0),
      coalesce(sum(amount+tip_amount) filter(where payment_method='transfer'),0),
      coalesce(sum(amount+tip_amount) filter(where payment_method='card_terminal'),0)
      into v_cash,v_transfer,v_card from public.order_payments where shift_id=v_shift.id;
    select coalesce(sum(amount) filter(where entry_type='charge'),0),
      coalesce(sum(amount) filter(where entry_type='payment' and payment_method='cash'),0),
      coalesce(sum(amount) filter(where entry_type='payment' and payment_method='transfer'),0),
      coalesce(sum(amount) filter(where entry_type='payment' and payment_method='card_terminal'),0)
      into v_credit,v_credit_cash,v_credit_transfer,v_credit_card
    from public.customer_credit_transactions where shift_id=v_shift.id;
    select coalesce(sum(case when movement_type='income' then amount else -amount end),0)
      into v_movements from public.cash_movements where shift_id=v_shift.id;
    v_expected:=v_shift.opening_cash+v_cash+v_credit_cash+v_movements;
    update public.cash_shifts set status='closed',closed_by=auth.uid(),closed_at=now(),counted_cash=p_counted_cash,
      expected_cash=v_expected,difference=p_counted_cash-v_expected,notes=nullif(left(trim(coalesce(p_notes,'')),500),''),
      cash_sales=v_cash,transfer_sales=v_transfer,card_sales=v_card,credit_sales=v_credit,
      credit_collections_cash=v_credit_cash,credit_collections_transfer=v_credit_transfer,credit_collections_card=v_credit_card
    where id=v_shift.id returning * into v_shift;
    return to_jsonb(v_shift)||jsonb_build_object('open_accounts',0,'cancelled_pickup_count',cardinality(v_cancelled));
end; $$;


create or replace function public.reconcile_order_payment(p_order_id bigint,p_payment jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order public.orders%rowtype;v_status text;v_updated timestamptz;v_id text:=p_payment->>'id';v_refund public.payment_refund_operations%rowtype;
begin
 select * into v_order from public.orders where id=p_order_id for update;
 if not found or v_order.payment_method<>'mercado_pago' then raise exception 'Pedido no encontrado';end if;
 if coalesce(p_payment->>'external_reference','')<>p_order_id::text or p_payment->>'currency_id' is distinct from 'MXN'
 or (p_payment->>'transaction_amount')::numeric is null or abs((p_payment->>'transaction_amount')::numeric-v_order.total)>0.01 or nullif(v_id,'') is null then raise exception 'Pago no corresponde al pedido';end if;
 v_status:=case p_payment->>'status' when 'approved' then 'approved' when 'rejected' then 'rejected' when 'cancelled' then 'rejected' when 'refunded' then 'refunded' when 'charged_back' then 'refunded' else 'pending' end;
 v_updated:=coalesce((p_payment->>'date_last_updated')::timestamptz,(p_payment->>'date_created')::timestamptz);
 if v_updated is null then raise exception 'Fecha del pago requerida';end if;
 -- The row lock makes this decision authoritative even if a webhook read the order before the cut.
 if v_status='approved' and v_order.status='cancelado' and v_order.cancellation_reason='Pedido sin pagar cancelado al cerrar el turno de caja' then
  return jsonb_build_object('refund_required',true,'payment_status',v_order.payment_status);
 end if;

 select * into v_refund from public.payment_refund_operations where order_id=p_order_id;
 if v_order.payment_status='refunded' then return jsonb_build_object('ignored',true,'reason','terminal');end if;
 if v_order.payment_status='approved' and v_order.mercado_pago_payment_id is distinct from v_id then
   return jsonb_build_object('ignored',true,'reason','different_payment');end if;
 if v_order.mercado_pago_payment_id=v_id and v_order.payment_updated_at>v_updated then return jsonb_build_object('ignored',true,'reason','stale');end if;
 if v_order.payment_status='approved' and v_status not in('approved','refunded') then return jsonb_build_object('ignored',true,'reason','regression');end if;
 if v_refund.status='pending' and v_status<>'refunded' then return jsonb_build_object('refund_pending',true);end if;
 update public.orders set payment_status=v_status,mercado_pago_payment_id=v_id,payment_updated_at=v_updated,
   status=case when v_status in('rejected','refunded') then 'cancelado'
     when v_status='approved' and cancellation_reason in('Tiempo de pago agotado (20 minutos)','El pago en línea fue rechazado. Crea un pedido nuevo.') then 'pendiente' else status end,
   cancellation_reason=case when v_status='rejected' then 'El pago en línea fue rechazado. Crea un pedido nuevo.'
     when v_status='refunded' then coalesce(v_refund.reason,'Pago reembolsado o contracargo')
     when v_status='approved' and cancellation_reason in('Tiempo de pago agotado (20 minutos)','El pago en línea fue rechazado. Crea un pedido nuevo.') then null else cancellation_reason end,
   delivery_status=case when v_status='refunded' and service_type='delivery' then 'cancelled' else delivery_status end,
   assigned_driver_id=case when v_status='refunded' then null else assigned_driver_id end,
   assigned_driver_name=case when v_status='refunded' then null else assigned_driver_name end
 where id=p_order_id;
 if v_status='refunded' and v_refund.status='pending' then
   if v_order.service_type='delivery' then
     insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(p_order_id,v_order.restaurant_id,'cancelled','Pedido cancelado y reembolsado: '||v_refund.reason,v_refund.actor_id);
   end if;
   update public.payment_refund_operations set status='completed',completed_at=now() where order_id=p_order_id;
 end if;
 return jsonb_build_object('updated',true,'payment_status',v_status);
end;$$;
revoke all on function public.reconcile_order_payment(bigint,jsonb) from public,anon,authenticated;
grant execute on function public.reconcile_order_payment(bigint,jsonb) to service_role;

