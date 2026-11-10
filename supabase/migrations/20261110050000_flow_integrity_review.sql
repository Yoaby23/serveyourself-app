CREATE OR REPLACE FUNCTION public.cancel_pos_order(p_order_id bigint, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.orders%rowtype;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' then raise exception 'Cuenta no encontrada'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Solo caja o propietario pueden cancelar'; end if;
    if char_length(trim(coalesce(p_reason,'')))<4 then raise exception 'Indica el motivo de cancelacion'; end if;
    if v_order.payment_status in ('approved','on_credit','refunded') or exists(select 1 from public.customer_credit_transactions where order_id=p_order_id) then raise exception 'Una cuenta liquidada o a crédito requiere devolución administrativa';end if;
    if exists(select 1 from public.order_payments where order_id=p_order_id) then raise exception 'Una cuenta con pagos requiere devolucion administrativa'; end if;
    update public.orders set status='cancelado',cancellation_reason=left(trim(p_reason),300),cancelled_reason=left(trim(p_reason),300),closed_at=now() where id=p_order_id returning * into v_order;
    update public.kitchen_tickets set status='cancelado' where order_id=p_order_id and status not in ('cancelado','entregado');
    insert into public.order_audit_logs(order_id,restaurant_id,action,reason,actor_id) values(p_order_id,v_order.restaurant_id,'cancelled',v_order.cancelled_reason,auth.uid());
    return to_jsonb(v_order);
end; $function$;
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
    if v_order.payment_method='mercado_pago' then raise exception 'Verifica el pago de Mercado Pago; no registres otro cobro manual';end if;
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
CREATE OR REPLACE FUNCTION public.split_pos_order(p_order_id bigint, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.orders%rowtype; v_new public.orders%rowtype; v_item jsonb; v_requested integer; v_original integer; v_selected jsonb:='[]'::jsonb; v_remaining jsonb:='[]'::jsonb; v_split_total numeric:=0;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' or v_order.payment_status<>'pending' or v_order.status='cancelado' or v_order.service_type<>'dine_in' then raise exception 'Cuenta no disponible'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Solo caja puede dividir cuentas'; end if;
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
    insert into public.orders(customer_id,restaurant_id,restaurant_name,items,total,notes,status,payment_method,payment_status,order_source,service_type,table_id,created_by,waiter_name,inventory_deducted,pickup_name)
    values(v_order.customer_id,v_order.restaurant_id,v_order.restaurant_name,v_selected,v_split_total,v_order.notes,v_order.status,'cash','pending','pos',v_order.service_type,v_order.table_id,v_order.created_by,v_order.waiter_name,v_order.inventory_deducted,v_order.pickup_name)
    returning * into v_new;
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id) values(p_order_id,v_order.restaurant_id,'split',jsonb_build_object('new_order_id',v_new.id,'amount',v_split_total),auth.uid());
    return jsonb_build_object('original_order',to_jsonb(v_order),'new_order',to_jsonb(v_new));
end; $function$;
CREATE OR REPLACE FUNCTION public.transfer_pos_order(p_order_id bigint, p_table_id bigint, p_waiter_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.orders%rowtype; v_waiter_name text; v_restaurant_id uuid;
begin
    select restaurant_id into v_restaurant_id from public.orders where id=p_order_id;
    if p_table_id is not null and v_restaurant_id is not null then
        perform pg_advisory_xact_lock(hashtextextended(v_restaurant_id::text||':'||p_table_id::text,0));
    end if;
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' or v_order.payment_status<>'pending' or v_order.status='cancelado' or v_order.payment_method='mercado_pago' then raise exception 'Cuenta no disponible'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Solo caja puede transferir cuentas'; end if;
    if p_table_id is not null and not exists(select 1 from public.restaurant_tables where id=p_table_id and restaurant_id=v_order.restaurant_id and is_active) then raise exception 'Mesa invalida'; end if;
    if p_table_id is not null then
        if exists(select 1 from public.orders o where o.id<>p_order_id and o.restaurant_id=v_order.restaurant_id and o.table_id=p_table_id and o.order_source='pos' and o.payment_status='pending' and o.status<>'cancelado') then
            raise exception 'Esta mesa ya tiene una cuenta abierta. Elige una mesa disponible';
        end if;
    end if;
    if p_waiter_id is not null then select full_name into v_waiter_name from public.profiles where id=p_waiter_id; end if;
    if p_waiter_id is not null and not exists(select 1 from public.restaurant_staff where restaurant_id=v_order.restaurant_id and user_id=p_waiter_id and is_active and can_create_orders) then raise exception 'Mesero invalido'; end if;
    update public.orders set table_id=p_table_id,service_type=case when p_table_id is null then 'pickup' else 'dine_in' end,
        created_by=coalesce(p_waiter_id,created_by),waiter_name=coalesce(v_waiter_name,waiter_name)
    where id=p_order_id returning * into v_order;
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id) values(p_order_id,v_order.restaurant_id,'transferred',jsonb_build_object('table_id',p_table_id,'waiter_id',p_waiter_id),auth.uid());
    return to_jsonb(v_order);
end; $function$;
create function public.submit_pos_order_once(p_request_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior public.customer_order_requests%rowtype; result jsonb;
begin
 if auth.uid() is null or p_request_id is null or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Solicitud inválida';end if;
 if not public.has_restaurant_permission((p_payload->>'p_restaurant_id')::uuid,'create_orders') then raise exception 'Sin permiso para crear comandas';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,0));
 select * into prior from public.customer_order_requests where customer_id=auth.uid() and request_id=p_request_id;
 if found then
  if prior.payload<>p_payload then raise exception 'Esta solicitud ya se utilizó con otra comanda';end if;
  if not public.has_restaurant_permission((p_payload->>'p_restaurant_id')::uuid,'create_orders') then raise exception 'Sin permiso para crear comandas';end if;
  select to_jsonb(o) into result from public.orders o where o.id=prior.order_id;
  return result;
 end if;
 result:=public.create_pos_table_order((p_payload->>'p_restaurant_id')::uuid,p_payload->'p_items',p_payload->>'p_notes',p_payload->>'p_service_type',(p_payload->>'p_table_id')::bigint,p_payload->>'p_payment_method',(p_payload->>'p_existing_order_id')::bigint,p_payload->>'p_customer_name');
 insert into public.customer_order_requests(customer_id,request_id,payload,order_id) values(auth.uid(),p_request_id,p_payload,(result->>'id')::bigint);
 return result;
end;$$;
revoke all on function public.submit_pos_order_once(uuid,jsonb) from public,anon;
grant execute on function public.submit_pos_order_once(uuid,jsonb) to authenticated;
