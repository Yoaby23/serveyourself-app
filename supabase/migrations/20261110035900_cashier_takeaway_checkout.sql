-- Immediate collection is takeaway. Scheduled collection is pickup.
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
    if v_guest_cash and p_amount<>round(v_order.total-v_paid,2) then raise exception 'Liquida el total para enviar el pedido a cocina';end if;
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
create or replace function public.enforce_pickup_payment_gate()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.service_type='pickup' then
  new.payment_before_kitchen:=new.scheduled_for is null;
  if new.payment_before_kitchen and new.payment_status='not_required' then new.payment_status:='pending';end if;
  if new.payment_before_kitchen and new.payment_status not in ('approved','on_credit') and new.status in ('preparando','listo','entregado') then
   raise exception 'Completa el pago o autoriza el crédito para continuar';end if;
 end if;
 return new;
end;$$;
create or replace function public.guard_pickup_kitchen_ticket()
returns trigger language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=new.order_id for update;
 if o.service_type='pickup' and o.scheduled_for is null and o.payment_status not in ('approved','on_credit') and new.status<>'cancelado' then
  raise exception 'Completa el pago o autoriza el crédito para continuar';end if;
 return new;
end;$$;
create or replace function public.protect_unpaid_online_order()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if (new.payment_method='mercado_pago' or new.payment_before_kitchen) and new.payment_status not in ('approved','on_credit') and new.status in ('preparando','listo','entregado') then
  raise exception 'Completa el pago para continuar';end if;
 return new;
end;$$;
CREATE OR REPLACE FUNCTION public.close_cash_shift(p_restaurant_id uuid, p_counted_cash numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    perform id from public.orders where restaurant_id=p_restaurant_id and service_type='pickup' and scheduled_for is null
      and payment_status in ('pending','not_required') and status<>'cancelado' and created_at<=v_cutoff order by id for update;
    select * into v_shift from public.cash_shifts where restaurant_id=p_restaurant_id and status='open' for update;
    if not found then raise exception 'No hay turno abierto';end if;
    select coalesce(array_agg(o.id),'{}'::bigint[]) into v_cancelled from public.orders o
    where o.restaurant_id=p_restaurant_id and o.service_type='pickup' and scheduled_for is null and o.created_at<=v_cutoff
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
end; $function$;
CREATE OR REPLACE FUNCTION public.create_kitchen_ticket(p_order_id bigint, p_items jsonb, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.orders%rowtype; v_item jsonb; v_product public.products%rowtype; v_qty integer; v_items jsonb:='[]'::jsonb; v_ticket_id bigint;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found then raise exception 'Cuenta no encontrada'; end if;
    if not (public.has_restaurant_permission(v_order.restaurant_id,'create_orders') or (v_order.service_type='pickup' and v_order.order_source='pos' and public.has_restaurant_permission(v_order.restaurant_id,'close_accounts'))) then raise exception 'Sin permiso para crear comandas'; end if;
    if v_order.service_type='pickup' and v_order.scheduled_for is null and v_order.payment_status not in ('approved','on_credit') then return null;end if;
    if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 then raise exception 'Agrega productos'; end if;
    for v_item in select value from jsonb_array_elements(p_items) loop
        v_qty:=coalesce((v_item->>'qty')::integer,0);
        select * into v_product from public.products where id::text=v_item->>'id' and restaurant_id=v_order.restaurant_id;
        if not found or v_qty<1 or v_qty>50 then raise exception 'Producto o cantidad invalida'; end if;
        v_items:=v_items||jsonb_build_array(jsonb_build_object('id',v_product.id,'nombre',v_product.name,'price',v_product.price,'qty',v_qty,'station_id',v_product.kitchen_station_id));
    end loop;
    insert into public.kitchen_tickets(order_id,restaurant_id,items,notes,service_type,table_id,created_by,waiter_name)
    values(v_order.id,v_order.restaurant_id,v_items,nullif(left(trim(coalesce(p_notes,'')),500),''),v_order.service_type,v_order.table_id,v_order.created_by,v_order.waiter_name)
    returning id into v_ticket_id;
    insert into public.kitchen_ticket_station_statuses(ticket_id,restaurant_id,station_key,kitchen_station_id)
    select distinct v_ticket_id,v_order.restaurant_id,coalesce(p.kitchen_station_id::text,'general'),p.kitchen_station_id
    from jsonb_array_elements(v_items) i join public.products p on p.id::text=i->>'id'
    on conflict(ticket_id,station_key) do nothing;
    return v_ticket_id;
end; $function$;
CREATE OR REPLACE FUNCTION public.sync_online_order_kitchen_ticket()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ticket_id bigint;v_items jsonb;
begin
 if (new.order_source='pos' and new.service_type<>'pickup') or new.status not in('pendiente','preparando','listo')
 or ((new.payment_method='mercado_pago' or new.payment_before_kitchen) and new.payment_status not in ('approved','on_credit'))
 or (new.service_type='delivery' and new.delivery_status not in('accepted','preparing','ready_for_dispatch'))
 or exists(select 1 from public.kitchen_tickets t where t.order_id=new.id and t.status<>'cancelado') then return new;end if;
 select coalesce(jsonb_agg(i.value||jsonb_build_object('station_id',p.kitchen_station_id)),'[]'::jsonb)
 into v_items from jsonb_array_elements(new.items)i join public.products p on p.id::text=i.value->>'id';
 insert into public.kitchen_tickets(order_id,restaurant_id,items,notes,status,service_type,table_id,created_by,waiter_name,created_at)
 values(new.id,new.restaurant_id,v_items,new.notes,new.status,new.service_type,new.table_id,new.created_by,new.waiter_name,new.created_at) returning id into v_ticket_id;
 insert into public.kitchen_ticket_station_statuses(ticket_id,restaurant_id,station_key,kitchen_station_id,status)
 select distinct v_ticket_id,new.restaurant_id,coalesce(p.kitchen_station_id::text,'general'),p.kitchen_station_id,new.status
 from jsonb_array_elements(v_items)i join public.products p on p.id::text=i->>'id' on conflict(ticket_id,station_key) do nothing;
 return new;
end;$function$;

create function public.cashier_create_takeaway(p_request_id uuid,p_restaurant_id uuid,p_items jsonb,p_name text,p_notes text,p_method text,p_received numeric default null)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  update public.orders set payment_method='mercado_pago',payment_expires_at=now()+interval '20 minutes' where id=(result->>'id')::bigint returning to_jsonb(orders.*) into result;
 end if;
 if p_method in ('cash','card_terminal') then
  result:=public.register_pos_payment_v2((result->>'id')::bigint,p_method,(result->>'total')::numeric,0,p_received);
 end if;
 insert into public.customer_order_requests(customer_id,request_id,payload,order_id) values(auth.uid(),p_request_id,v_payload,(result->>'id')::bigint);
 return result;
end;$$;
revoke all on function public.cashier_create_takeaway(uuid,uuid,jsonb,text,text,text,numeric) from public,anon;
grant execute on function public.cashier_create_takeaway(uuid,uuid,jsonb,text,text,text,numeric) to authenticated;
create trigger scheduled_pickup_kitchen after update of scheduled_for on public.orders
for each row when (new.service_type='pickup' and new.scheduled_for is not null)
execute function public.sync_online_order_kitchen_ticket();
