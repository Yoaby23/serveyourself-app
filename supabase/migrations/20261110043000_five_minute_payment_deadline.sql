create or replace function public.set_online_payment_expiration()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.payment_method='mercado_pago' or new.service_type='pickup' then
  if tg_op='INSERT' or new.payment_expires_at is null then new.payment_expires_at:=coalesce(new.created_at,now())+interval '5 minutes';end if;
 else new.payment_expires_at:=null;
 end if;
 return new;
end;$$;
create function public.cancel_expired_unpaid_orders() returns bigint language plpgsql security definer set search_path='' as $$
declare cancelled bigint[]; n bigint;
begin
 with due as (
  select o.id from public.orders o where (o.service_type='pickup' or o.payment_method='mercado_pago')
  and o.payment_status in ('pending','not_required') and o.status not in ('cancelado','entregado')
  and o.payment_expires_at<=clock_timestamp()
  and not exists(select 1 from public.order_payments p where p.order_id=o.id)
  and not exists(select 1 from public.customer_credit_transactions c where c.order_id=o.id)
  order by o.id for update skip locked limit 200
 ), updated as(
  update public.orders o set payment_status='expired',status='cancelado',cancellation_reason='Tiempo de pago agotado (5 minutos)'
  from due where o.id=due.id returning o.id
 ) select array_agg(id),count(*) into cancelled,n from updated;
 update public.kitchen_tickets set status='cancelado' where order_id=any(cancelled) and status not in ('entregado','cancelado');
 return n;
end;$$;
revoke all on function public.cancel_expired_unpaid_orders() from public,anon,authenticated;
grant execute on function public.cancel_expired_unpaid_orders() to service_role;
select cron.schedule('expire-unpaid-orders','10 seconds',$job$ select public.cancel_expired_unpaid_orders(); $job$);
update public.orders set payment_expires_at=least(coalesce(payment_expires_at,created_at+interval '5 minutes'),created_at+interval '5 minutes')
where (service_type='pickup' or payment_method='mercado_pago') and payment_status in ('pending','not_required') and status not in ('cancelado','entregado');
CREATE OR REPLACE FUNCTION public.cashier_create_takeaway(p_request_id uuid, p_restaurant_id uuid, p_items jsonb, p_name text, p_notes text, p_method text, p_received numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; previous public.orders%rowtype; v_payload jsonb;
begin
 if not public.has_restaurant_permission(p_restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
 if p_request_id is null or p_method not in ('cash','card_terminal','mercado_pago','credit') then raise exception 'Solicitud inválida';end if;
 v_payload:=jsonb_build_object('restaurant_id',p_restaurant_id,'items',p_items,'name',p_name,'notes',p_notes,'method',p_method,'received',p_received);
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,0));
 if exists(select 1 from public.customer_order_requests where customer_id=auth.uid() and request_id=p_request_id and customer_order_requests.payload<>v_payload) then raise exception 'La solicitud ya se utilizó';end if;
 select o.* into previous from public.customer_order_requests r join public.orders o on o.id=r.order_id where r.customer_id=auth.uid() and r.request_id=p_request_id;
 if found then return to_jsonb(previous)||jsonb_build_object('cash_change',(select sum(cash_change) from public.order_payments where order_id=previous.id));end if;
 result:=public.create_pos_table_order(p_restaurant_id,p_items,p_notes,'pickup',null,'cash',null,p_name);
 if p_method='mercado_pago' then
  update public.orders set payment_method='mercado_pago',payment_expires_at=now()+interval '5 minutes' where id=(result->>'id')::bigint returning to_jsonb(orders.*) into result;
 end if;
 if p_method in ('cash','card_terminal') then
  result:=public.register_pos_payment_v2((result->>'id')::bigint,p_method,(result->>'total')::numeric,0,p_received);
 end if;
 insert into public.customer_order_requests(customer_id,request_id,payload,order_id) values(auth.uid(),p_request_id,v_payload,(result->>'id')::bigint);
 return result;
end;$function$;
CREATE OR REPLACE FUNCTION public.expire_unpaid_online_orders(p_restaurant_id uuid DEFAULT NULL::uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_user_id uuid := auth.uid();
    v_count bigint;
begin
    if v_user_id is null then raise exception 'Sesion requerida'; end if;

    if p_restaurant_id is not null
       and not public.has_restaurant_permission(p_restaurant_id, 'close_accounts') then
        raise exception 'Sin permiso para revisar pagos';
    end if;

    update public.orders
    set payment_status = 'expired',
        status = 'cancelado',
        cancellation_reason = 'Tiempo de pago agotado (5 minutos)',
        cancelled_by = null
    where payment_method = 'mercado_pago'
      and payment_status = 'pending'
      and mercado_pago_payment_id is null
      and coalesce(payment_expires_at, created_at + interval '5 minutes') <= now()
      and (
          (p_restaurant_id is null and customer_id = v_user_id)
          or (p_restaurant_id is not null and restaurant_id = p_restaurant_id)
      );

    get diagnostics v_count = row_count;
    return v_count;
end;
$function$;
CREATE OR REPLACE FUNCTION public.reconcile_order_payment(p_order_id bigint, p_payment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 if v_status='approved' and v_order.status='cancelado' and (v_order.cancellation_reason='Pedido sin pagar cancelado al cerrar el turno de caja' or (v_order.cancellation_reason='Tiempo de pago agotado (5 minutos)' and coalesce((p_payment->>'date_approved')::timestamptz,(p_payment->>'date_created')::timestamptz)>v_order.payment_expires_at)) then
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
     when v_status='approved' and cancellation_reason in('Tiempo de pago agotado (20 minutos)','Tiempo de pago agotado (5 minutos)','El pago en línea fue rechazado. Crea un pedido nuevo.') then 'pendiente' else status end,
   cancellation_reason=case when v_status='rejected' then 'El pago en línea fue rechazado. Crea un pedido nuevo.'
     when v_status='refunded' then coalesce(v_refund.reason,'Pago reembolsado o contracargo')
     when v_status='approved' and cancellation_reason in('Tiempo de pago agotado (5 minutos)','El pago en línea fue rechazado. Crea un pedido nuevo.') then null else cancellation_reason end,
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
end;$function$;
CREATE OR REPLACE FUNCTION public.register_pos_payment_v2(p_order_id bigint, p_payment_method text, p_amount numeric, p_tip numeric DEFAULT 0, p_cash_received numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_order public.orders%rowtype;v_shift_id uuid;v_paid numeric;v_methods integer;
    v_tip numeric:=round(coalesce(p_tip,0),2);v_change numeric;v_guest_cash boolean;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found then raise exception 'Cuenta no encontrada';end if;
    if v_order.payment_expires_at<=clock_timestamp() and v_order.service_type='pickup' then raise exception 'El plazo de cinco minutos para pagar terminó';end if;
    v_guest_cash:=v_order.order_source='online' and v_order.service_type='pickup' and v_order.payment_method in ('cash','transfer')
;
    if v_order.order_source<>'pos' and not v_guest_cash then raise exception 'Cuenta no encontrada';end if;
    if v_guest_cash and p_payment_method is distinct from v_order.payment_method then raise exception 'Confirma el método de pago elegido por el cliente';end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Solo caja puede cobrar';end if;
    if v_order.status='cancelado' or v_order.payment_status<>'pending' then raise exception 'La cuenta no admite pagos';end if;
    if p_payment_method not in('cash','transfer','card_terminal') or p_amount is null or p_amount<=0 or v_tip<0 then raise exception 'Pago invalido';end if;
    if p_payment_method is null or p_amount::text in ('NaN','Infinity','-Infinity') or v_tip::text in ('NaN','Infinity','-Infinity')
      or p_cash_received::text in ('NaN','Infinity','-Infinity') then raise exception 'Pago inválido';end if;
    p_amount:=round(p_amount,2);
    if p_amount<=0 then raise exception 'Pago inválido';end if;
    select id into v_shift_id from public.cash_shifts where restaurant_id=v_order.restaurant_id and status='open' for update;
    if v_shift_id is null then raise exception 'Primero abre un turno de caja';end if;
    select coalesce(sum(amount),0) into v_paid from public.order_payments where order_id=p_order_id;
    if v_order.service_type='pickup' and p_amount<>round(v_order.total-v_paid,2) then raise exception 'Liquida el total para enviar el pedido a cocina';end if;
    if p_amount>round(v_order.total-v_paid,2) then raise exception 'El abono supera el saldo pendiente';end if;
    if p_payment_method='cash' then
        if p_cash_received is null or p_cash_received<p_amount+v_tip then raise exception 'El efectivo recibido no alcanza para cubrir el cobro y la propina';end if;
        p_cash_received:=round(p_cash_received,2);
        v_change:=round(p_cash_received-p_amount-v_tip,2);
    else p_cash_received:=null;v_change:=null;end if;
    insert into public.order_payments(order_id,restaurant_id,shift_id,payment_method,amount,tip_amount,cash_received,cash_change,received_by)
    values(p_order_id,v_order.restaurant_id,v_shift_id,p_payment_method,p_amount,v_tip,p_cash_received,v_change,auth.uid());
    select coalesce(sum(amount),0),count(distinct payment_method) into v_paid,v_methods from public.order_payments where order_id=p_order_id;
    update public.orders set tip_total=(select coalesce(sum(tip_amount),0) from public.order_payments where order_id=p_order_id),
      payment_status=case when v_paid>=total then 'approved' else 'pending' end,
      payment_method=case when v_methods>1 then 'mixed' else p_payment_method end
    where id=p_order_id returning * into v_order;
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    values(p_order_id,v_order.restaurant_id,'payment',jsonb_build_object('method',p_payment_method,'amount',p_amount,'tip',v_tip,'cash_received',p_cash_received,'cash_change',v_change,'shift_id',v_shift_id),auth.uid());
    return to_jsonb(v_order)||jsonb_build_object('paid_total',v_paid,'remaining',greatest(v_order.total-v_paid,0),'cash_received',p_cash_received,'cash_change',v_change);
end; $function$;
do $$
declare definition text;
begin
 definition:=pg_get_functiondef('public.charge_order_to_customer_credit(bigint,uuid,date,text)'::regprocedure);
 definition:=replace(definition,'    if v_order.status=''cancelado''',
  '    if v_order.service_type=''pickup'' and v_order.payment_expires_at<=clock_timestamp() then raise exception ''El plazo de cinco minutos para confirmar terminó'';end if;'||chr(10)||'    if v_order.status=''cancelado''');
 execute definition;
end;$$;

create or replace function public.notify_order_transition() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' and new.customer_id is not null and new.service_type='pickup' then
  perform public.enqueue_order_notification(new.id,null,'received','received');
 end if;
 if tg_op='INSERT' and new.service_type='pickup' and new.payment_before_kitchen and new.payment_status='pending' and new.payment_method in ('cash','transfer') then
  perform public.enqueue_order_notification(new.id,null,'cashier','pending');
 end if;
 if tg_op='UPDATE' and new.payment_status is distinct from old.payment_status and new.payment_status in ('approved','refunded','rejected','expired') and new.customer_id is not null then
  perform public.enqueue_order_notification(new.id,null,'payment',new.payment_status);
 end if;
 if new.status='cancelado' and (tg_op='INSERT' or new.status is distinct from old.status) then
  perform public.enqueue_order_notification(new.id,null,'order','cancelado');
 elsif new.service_type='delivery' then
  if new.delivery_status is not null and (tg_op='INSERT' or new.delivery_status is distinct from old.delivery_status or (new.delivery_status='pending_acceptance' and new.payment_status='approved' and old.payment_status is distinct from new.payment_status)) and (new.payment_method<>'mercado_pago' or new.payment_status='approved') then
   perform public.enqueue_order_notification(new.id,null,'delivery',new.delivery_status);
  end if;
  if new.assigned_driver_id is not null and (tg_op='INSERT' or new.assigned_driver_id is distinct from old.assigned_driver_id) then
   perform public.enqueue_order_notification(new.id,null,'driver',new.assigned_driver_id::text);
  end if;
 end if;
 return new;
end;$$;
