create or replace function public.split_pos_order_many(p_order_id bigint,p_groups jsonb,p_expected_items jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare original public.orders%rowtype;g jsonb;piece jsonb;result jsonb;ids jsonb:='[]'; entry jsonb;
begin
 select * into original from public.orders where id=p_order_id for update;
 if not found or auth.uid() is null or not public.has_restaurant_permission(original.restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
 if p_groups is null or jsonb_typeof(p_groups)<>'array' then raise exception 'División inválida';end if;
 if jsonb_array_length(p_groups) not between 1 and 9 then raise exception 'Selecciona entre 2 y 10 cuentas';end if;
 if p_expected_items is distinct from original.items then raise exception 'La cuenta cambió. Actualízala antes de dividir';end if;
 if exists(select 1 from jsonb_array_elements(original.items) i group by i->>'id' having count(*)>1) then raise exception 'Revisa los productos duplicados antes de dividir';end if;
 for g in select value from jsonb_array_elements(p_groups) loop
  if jsonb_typeof(g)<>'array' then raise exception 'Productos inválidos';end if;
  if jsonb_array_length(g)=0 then raise exception 'Cada cuenta debe tener productos';end if;
  for entry in select value from jsonb_array_elements(g) loop
   if entry->>'id' is null or not exists(select 1 from jsonb_array_elements(original.items) i where i->>'id'=entry->>'id') or (entry->>'qty') is null or (entry->>'qty')::numeric<=0 or (entry->>'qty')::numeric<>trunc((entry->>'qty')::numeric) then raise exception 'Producto o cantidad inválida';end if;
  end loop;
  result:=public.split_pos_order(p_order_id,g);
  ids:=ids||jsonb_build_array(result->'new_order'->'id');
 end loop;
 return jsonb_build_object('original_order_id',p_order_id,'new_order_ids',ids,'account_count',jsonb_array_length(ids)+1);
end;$$;
revoke all on function public.split_pos_order_many(bigint,jsonb,jsonb) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION public.record_cash_operation_once(p_request_id uuid, p_operation text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare prior public.cash_operation_requests%rowtype; result jsonb; restaurant uuid;
begin
 if auth.uid() is null or p_request_id is null or p_operation is null or p_operation not in ('order_payment','credit_payment','split_order') or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Operación inválida';end if;
 if p_operation in ('order_payment','split_order') then
  select restaurant_id into restaurant from public.orders where id=(p_payload->>'p_order_id')::bigint;
 else
  select restaurant_id into restaurant from public.loyalty_customers where id=(p_payload->>'p_customer_id')::uuid;
 end if;
 if restaurant is null or not public.has_restaurant_permission(restaurant,'close_accounts') then raise exception 'Sin permiso de caja';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,0));
 select * into prior from public.cash_operation_requests where actor_id=auth.uid() and request_id=p_request_id;
 if found then
  if prior.operation<>p_operation or prior.payload<>p_payload then raise exception 'Esta solicitud ya se utilizó con otro cobro';end if;
  return prior.result;
 end if;
 if p_operation='order_payment' then
  result:=public.register_pos_payment_v2((p_payload->>'p_order_id')::bigint,p_payload->>'p_payment_method',(p_payload->>'p_amount')::numeric,(p_payload->>'p_tip')::numeric,(p_payload->>'p_cash_received')::numeric);
 elsif p_operation='split_order' then
  result:=public.split_pos_order_many((p_payload->>'p_order_id')::bigint,p_payload->'p_groups',p_payload->'p_expected_items');
 else
  result:=public.record_customer_credit_payment((p_payload->>'p_customer_id')::uuid,(p_payload->>'p_amount')::numeric,p_payload->>'p_payment_method',(p_payload->>'p_cash_received')::numeric,p_payload->>'p_notes');
 end if;
 insert into public.cash_operation_requests(actor_id,request_id,restaurant_id,operation,payload,result) values(auth.uid(),p_request_id,restaurant,p_operation,p_payload,result);
 return result;
end;$function$
;

create or replace function public.list_order_coupon_options(p_order_id bigint)
returns table(code text,discount_type text,discount_value numeric,discount_amount numeric)
language plpgsql stable security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=p_order_id;
 if auth.uid() is null or not found or not public.has_restaurant_permission(o.restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
 if o.order_source<>'pos' or o.payment_status<>'pending' or o.status='cancelado' or o.payment_method='mercado_pago' then raise exception 'Esta cuenta no admite cupones de caja';end if;
 if exists(select 1 from public.order_payments where order_id=p_order_id) then raise exception 'Aplica el cupón antes de registrar pagos';end if;
 return query select c.code,c.discount_type,c.discount_value,
 case when c.discount_type='percent' then round((o.total+o.discount_total)*least(c.discount_value,100)/100,2) else least(c.discount_value,o.total+o.discount_total) end
 from public.coupons c where c.restaurant_id=o.restaurant_id and c.is_active and (c.starts_at is null or c.starts_at<=now()) and (c.ends_at is null or c.ends_at>=now()) order by c.code;
end;$$;
revoke all on function public.list_order_coupon_options(bigint) from public,anon;
grant execute on function public.list_order_coupon_options(bigint) to authenticated;

CREATE OR REPLACE FUNCTION public.apply_order_coupon(p_order_id bigint, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.orders%rowtype; v_coupon public.coupons%rowtype; v_discount numeric;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Cuenta no disponible'; end if;
    if v_order.payment_status<>'pending' or v_order.status='cancelado' or v_order.payment_method='mercado_pago' then raise exception 'La cuenta no admite cupones'; end if;
    if exists(select 1 from public.order_payments where order_id=p_order_id) then raise exception 'Aplica el cupón antes de registrar pagos';end if;
    if v_order.order_source<>'pos' then raise exception 'Los cupones de caja se aplican a cuentas del punto de venta';end if;
    select * into v_coupon from public.coupons where restaurant_id=v_order.restaurant_id and upper(code)=upper(trim(p_code)) and is_active
      and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>=now());
    if not found then raise exception 'Cupon invalido o vencido'; end if;
    v_discount:=case when v_coupon.discount_type='percent' then round((v_order.total+v_order.discount_total)*least(v_coupon.discount_value,100)/100,2) else least(v_coupon.discount_value,v_order.total+v_order.discount_total) end;
    update public.orders set total=greatest(total+discount_total-v_discount,0),discount_total=v_discount where id=p_order_id returning * into v_order;
    if v_order.total=0 then
      if not exists(select 1 from public.cash_shifts where restaurant_id=v_order.restaurant_id and status='open') then raise exception 'Abre el turno para liquidar una cuenta cubierta por cupón';end if;
      update public.orders set payment_status='approved' where id=p_order_id returning * into v_order;
    end if;
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id) values(p_order_id,v_order.restaurant_id,'coupon',jsonb_build_object('code',v_coupon.code,'discount',v_discount),auth.uid());
    return to_jsonb(v_order);
end; $function$
;
CREATE OR REPLACE FUNCTION public.create_staff_invite(p_staff_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_code text;v_invite public.restaurant_staff_invites%rowtype;
begin
 if p_staff_role not in('waiter','kitchen','cashier','manager','driver') then raise exception 'Rol no válido';end if;
 if not exists(select 1 from public.profiles where id=auth.uid() and role='negocio') then raise exception 'Solo el propietario puede invitar personal';end if;
 if p_staff_role='driver' and not exists(select 1 from public.profiles where id=auth.uid() and delivery_enabled) then raise exception 'Activa el servicio a domicilio antes de invitar repartidores';end if;
 v_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
 insert into public.restaurant_staff_invites(restaurant_id,code,staff_role,created_by) values(auth.uid(),v_code,p_staff_role,auth.uid()) returning * into v_invite;
 return jsonb_build_object('code',v_invite.code,'role',v_invite.staff_role,'expires_at',v_invite.expires_at);
end; $function$
;
CREATE OR REPLACE FUNCTION public.set_marketplace_driver_availability(p_available boolean, p_latitude double precision DEFAULT NULL::double precision, p_longitude double precision DEFAULT NULL::double precision)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d public.delivery_drivers%rowtype;
begin
 if p_available and not public.is_team_driver(null) then raise exception 'Necesitas pertenecer al equipo de reparto'; end if;
 if p_available and not exists(select 1 from public.restaurant_staff s join public.profiles p on p.id=s.restaurant_id where s.user_id=auth.uid() and s.is_active and s.can_deliver_orders and p.delivery_enabled) then raise exception 'El restaurante no tiene habilitado el reparto';end if;
 if p_latitude is not null and (p_latitude not between -90 and 90 or p_longitude not between -180 and 180) then raise exception 'Ubicacion invalida';end if;
 update public.delivery_drivers set is_available=p_available,latitude=coalesce(p_latitude,latitude),longitude=coalesce(p_longitude,longitude),last_location_at=case when p_latitude is not null then now() else last_location_at end,updated_at=now()
 where user_id=auth.uid() and status='active' returning * into d;
 if not found then raise exception 'Primero registra tu cuenta de repartidor';end if;
 return to_jsonb(d);
end; $function$
;
