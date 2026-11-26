-- Guest cash orders must be paid at the cashier before creating a kitchen ticket.
alter table public.orders add column payment_before_kitchen boolean not null default false;
create or replace view public.public_qr_restaurants as
select id,business_name,address,open_time,close_time,avatar_url,rating,timezone,accepting_orders,
 (guest_pickup_enabled and (payment_cash or (payment_online and mercado_pago_connected))) as guest_pickup_enabled,
 payment_cash, (payment_online and mercado_pago_connected) as payment_online
from public.profiles where role='negocio';
revoke all on public.public_qr_restaurants from public,anon,authenticated;
grant select on public.public_qr_restaurants to anon,authenticated;

create function public.create_guest_pickup_order(p_token_hash text,p_client_hash text,p_restaurant_id uuid,p_items jsonb,p_name text,p_payment_method text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r public.profiles%rowtype; previous public.guest_checkout_requests%rowtype;
 p public.products%rowtype; item jsonb; qty integer; total numeric:=0;
 normalized jsonb:='[]'; payload jsonb; result public.orders%rowtype; local_time time;
begin
 if p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' or p_client_hash is null or p_client_hash !~ '^[a-f0-9]{64}$' then raise exception 'Solicitud inválida';end if;
 if p_payment_method is null or p_payment_method not in ('cash','mercado_pago') then raise exception 'Método de pago inválido';end if;
 p_name:=btrim(p_name);
 if p_name is null or char_length(p_name) not between 1 and 80 then raise exception 'Indica un nombre de 1 a 80 caracteres';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Carrito inválido';end if;
 if jsonb_array_length(p_items) not between 1 and 50 then raise exception 'Elige entre 1 y 50 productos';end if;
 payload:=jsonb_build_object('restaurant_id',p_restaurant_id,'items',p_items,'name',p_name,'payment_method',p_payment_method);
 perform pg_advisory_xact_lock(hashtextextended('guest-token:'||p_token_hash,0));
 select * into previous from public.guest_checkout_requests where token_hash=p_token_hash;
 if found then
  if previous.created_at<now()-interval '7 days' then raise exception 'El acceso al pedido venció';end if;
  if (previous.payload||jsonb_build_object('payment_method',coalesce(previous.payload->>'payment_method','mercado_pago')))<>payload then raise exception 'La solicitud ya pertenece a otro carrito';end if;
  select * into result from public.orders where id=previous.order_id;
  return to_jsonb(result);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('guest-client:'||p_client_hash,0));
 if (select count(*) from public.guest_checkout_requests where client_hash=p_client_hash and created_at>now()-interval '20 minutes')>=10 then raise exception 'Demasiados intentos. Espera antes de crear otro pedido';end if;
 select * into r from public.profiles where id=p_restaurant_id and role='negocio' for update;
 if not found or not r.guest_pickup_enabled then raise exception 'Este restaurante no admite pedidos sin cuenta';end if;
 if p_payment_method='cash' and not r.payment_cash then raise exception 'El restaurante no acepta efectivo';end if;
 if p_payment_method='mercado_pago' and (not r.payment_online or not r.mercado_pago_connected) then raise exception 'El restaurante no admite pago en línea';end if;
 if not r.accepting_orders then raise exception 'El restaurante no está aceptando pedidos';end if;
 local_time:=(now() at time zone r.timezone)::time;
 if r.open_time is not null and r.close_time is not null and not
 (case when r.open_time<=r.close_time then local_time between r.open_time and r.close_time else local_time>=r.open_time or local_time<=r.close_time end) then raise exception 'El restaurante está cerrado';end if;
 if (select count(*) from public.guest_checkout_requests g join public.orders o on o.id=g.order_id where g.restaurant_id=p_restaurant_id and g.created_at>now()-interval '20 minutes' and o.payment_status='pending')>=100 then raise exception 'Hay muchos pagos pendientes. Intenta más tarde';end if;
 if (select count(distinct value->>'id') from jsonb_array_elements(p_items))<>jsonb_array_length(p_items) then raise exception 'Productos duplicados o inválidos';end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if coalesce(item->>'qty','') !~ '^[0-9]{1,2}$' then raise exception 'Cantidad inválida';end if;
  qty:=(item->>'qty')::integer;
  if qty not between 1 and 50 then raise exception 'Cantidad inválida';end if;
  select * into p from public.products where id::text=item->>'id' and restaurant_id=p_restaurant_id and is_available for share;
  if not found or p.price<=0 then raise exception 'Un producto no está disponible';end if;
  total:=total+p.price*qty;
  normalized:=normalized||jsonb_build_array(jsonb_build_object('id',p.id,'nombre',p.name,'price',p.price,'qty',qty));
 end loop;
 insert into public.orders(restaurant_id,restaurant_name,items,total,subtotal,pickup_name,order_source,service_type,payment_method,payment_status,status,payment_before_kitchen)
 values(r.id,r.business_name,normalized,round(total,2),round(total,2),p_name,'online','pickup',p_payment_method,'pending','pendiente',true) returning * into result;
 insert into public.guest_checkout_requests(token_hash,restaurant_id,client_hash,payload,order_id) values(p_token_hash,p_restaurant_id,p_client_hash,payload,result.id);
 return to_jsonb(result);
end;$$;

revoke all on function public.create_guest_pickup_order(text,text,uuid,jsonb,text,text) from public,anon,authenticated;
grant execute on function public.create_guest_pickup_order(text,text,uuid,jsonb,text,text) to service_role;
-- Keep already cached clients working without duplicating the creation logic.
create or replace function public.create_guest_pickup_order(p_token_hash text,p_client_hash text,p_restaurant_id uuid,p_items jsonb,p_name text)
returns jsonb language sql security invoker set search_path='' as $$
 select public.create_guest_pickup_order(p_token_hash,p_client_hash,p_restaurant_id,p_items,p_name,'mercado_pago');
$$;
revoke all on function public.create_guest_pickup_order(text,text,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.create_guest_pickup_order(text,text,uuid,jsonb,text) to service_role;

create or replace function public.protect_unpaid_online_order()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if (old.payment_method='mercado_pago' or old.payment_before_kitchen)
 and old.payment_status<>'approved' and new.status in ('preparando','listo','entregado') then
  raise exception 'El pedido no puede enviarse a cocina hasta confirmar el pago';
 end if;
 return new;
end;$$;

create or replace function public.sync_online_order_kitchen_ticket()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_ticket_id bigint;v_items jsonb;
begin
 if new.order_source='pos' or new.status not in('pendiente','preparando','listo')
 or ((new.payment_method='mercado_pago' or new.payment_before_kitchen) and new.payment_status<>'approved')
 or (new.service_type='delivery' and new.delivery_status not in('accepted','preparing','ready_for_dispatch'))
 or exists(select 1 from public.kitchen_tickets t where t.order_id=new.id) then return new;end if;
 select coalesce(jsonb_agg(i.value||jsonb_build_object('station_id',p.kitchen_station_id)),'[]'::jsonb)
 into v_items from jsonb_array_elements(new.items)i join public.products p on p.id::text=i.value->>'id';
 insert into public.kitchen_tickets(order_id,restaurant_id,items,notes,status,service_type,table_id,created_by,waiter_name,created_at)
 values(new.id,new.restaurant_id,v_items,new.notes,new.status,new.service_type,new.table_id,new.created_by,new.waiter_name,new.created_at) returning id into v_ticket_id;
 insert into public.kitchen_ticket_station_statuses(ticket_id,restaurant_id,station_key,kitchen_station_id,status)
 select distinct v_ticket_id,new.restaurant_id,coalesce(p.kitchen_station_id::text,'general'),p.kitchen_station_id,new.status
 from jsonb_array_elements(v_items)i join public.products p on p.id::text=i->>'id' on conflict(ticket_id,station_key) do nothing;
 return new;
end;$$;

create or replace function public.register_pos_payment_v2(
    p_order_id bigint,
    p_payment_method text,
    p_amount numeric,
    p_tip numeric default 0,
    p_cash_received numeric default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
    v_order public.orders%rowtype;v_shift_id uuid;v_paid numeric;v_methods integer;
    v_tip numeric:=round(coalesce(p_tip,0),2);v_change numeric;v_guest_cash boolean;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found then raise exception 'Cuenta no encontrada';end if;
    v_guest_cash:=v_order.order_source='online' and v_order.service_type='pickup' and v_order.payment_method='cash'
      and v_order.payment_before_kitchen and exists(select 1 from public.guest_checkout_requests where order_id=p_order_id);
    if v_order.order_source<>'pos' and not v_guest_cash then raise exception 'Cuenta no encontrada';end if;
    if v_guest_cash and p_payment_method is distinct from 'cash' then raise exception 'Este pedido se paga en efectivo en caja';end if;
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
end; $$;


create or replace function public.cancel_order(p_order_id bigint,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_user_id uuid:=auth.uid();order_record public.orders%rowtype;cashier_pending_guest boolean;
begin
 if current_user_id is null then raise exception 'Debes iniciar sesión';end if;
 select * into order_record from public.orders where id=p_order_id for update;
 if not found then raise exception 'Pedido no encontrado';end if;
 cashier_pending_guest:=order_record.order_source='online' and order_record.service_type='pickup'
  and order_record.payment_method='cash' and order_record.payment_before_kitchen and order_record.payment_status='pending'
  and public.has_restaurant_permission(order_record.restaurant_id,'close_accounts');
 if order_record.customer_id is distinct from current_user_id and order_record.restaurant_id is distinct from current_user_id
 and not cashier_pending_guest then raise exception 'No tienes permiso para cancelar este pedido';end if;
 if order_record.status not in ('pendiente','preparando') then raise exception 'Este pedido ya no puede cancelarse';end if;
 if (order_record.payment_method='mercado_pago' or order_record.payment_before_kitchen) and order_record.payment_status='approved' then
  raise exception 'Un pago aprobado requiere un reembolso antes de cancelar';end if;
 if current_user_id=order_record.customer_id and order_record.status<>'pendiente' then raise exception 'El cliente solo puede cancelar pedidos pendientes';end if;
 if char_length(trim(coalesce(p_reason,'')))<3 then raise exception 'Indica el motivo de cancelación';end if;
 update public.orders set status='cancelado',cancellation_reason=left(trim(p_reason),300),cancelled_by=current_user_id
 where id=p_order_id returning * into order_record;
 return to_jsonb(order_record);
end;$$;
