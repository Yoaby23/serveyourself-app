begin;

-- Self-service business onboarding is a narrow operation, not a general role UPDATE.
create or replace function public.complete_business_registration(p_profile jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_profile public.profiles%rowtype;
begin
  if v_user is null then raise exception 'Inicia sesión para continuar';end if;
  if length(trim(coalesce(p_profile->>'business_name','')))<2 or length(trim(coalesce(p_profile->>'full_name','')))<2 or length(trim(coalesce(p_profile->>'address','')))<3 then
    raise exception 'Completa nombre, negocio y dirección';end if;
  select * into v_profile from public.profiles where id=v_user for update;
  if not found then raise exception 'Perfil no encontrado';end if;
  if v_profile.role not in ('cliente','negocio') then raise exception 'Tipo de cuenta incompatible';end if;
  update public.profiles set role='negocio',
    full_name=left(trim(p_profile->>'full_name'),120),business_name=left(trim(p_profile->>'business_name'),120),
    phone=left(trim(p_profile->>'phone'),30),address=left(trim(p_profile->>'address'),250),
    open_time=nullif(p_profile->>'open_time','')::time,close_time=nullif(p_profile->>'close_time','')::time,
    avatar_url=nullif(left(p_profile->>'avatar_url',500),'') where id=v_user returning * into v_profile;
  return jsonb_build_object('id',v_profile.id,'role',v_profile.role);
end;$$;
revoke all on function public.complete_business_registration(jsonb) from public,anon;
grant execute on function public.complete_business_registration(jsonb) to authenticated;

create table public.customer_order_requests(
 customer_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null,
 payload jsonb not null,
 order_id bigint not null references public.orders(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(customer_id,request_id)
);
alter table public.customer_order_requests enable row level security;
revoke all on public.customer_order_requests from public,anon,authenticated;
-- Kept private: accessed only inside the owner-checked function below.
create or replace function public.create_customer_order_once(p_request_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_request public.customer_order_requests%rowtype;v_created jsonb;v_order public.orders%rowtype;
begin
 if v_user is null then raise exception 'Inicia sesión para continuar';end if;
 if p_request_id is null or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Solicitud inválida';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_user::text||p_request_id::text,0));
 select * into v_request from public.customer_order_requests where customer_id=v_user and request_id=p_request_id;
 if found then
   if v_request.payload<>p_payload then raise exception 'Esta solicitud ya se utilizó con otro pedido';end if;
   select * into v_order from public.orders where id=v_request.order_id and customer_id=v_user;
   if not found then raise exception 'Pedido no disponible';end if;
   return to_jsonb(v_order);
 end if;
 if p_payload->>'service_type'='delivery' then
   v_created:=public.create_delivery_order((p_payload->>'restaurant_id')::uuid,p_payload->'items',p_payload->>'notes',p_payload->>'payment_method',p_payload->>'address',p_payload->>'reference',(p_payload->>'latitude')::double precision,(p_payload->>'longitude')::double precision,p_payload->>'contact_name',p_payload->>'contact_phone',null);
 elsif p_payload->>'service_type'='pickup' then
   v_created:=public.create_scheduled_pickup_order((p_payload->>'restaurant_id')::uuid,p_payload->'items',p_payload->>'notes',p_payload->>'payment_method',(p_payload->>'scheduled_for')::timestamptz);
 else raise exception 'Servicio inválido';end if;
 insert into public.customer_order_requests(customer_id,request_id,payload,order_id)
 values(v_user,p_request_id,p_payload,(v_created->>'id')::bigint);
 return v_created;
end;$$;
revoke all on function public.create_customer_order_once(uuid,jsonb) from public,anon;
grant execute on function public.create_customer_order_once(uuid,jsonb) to authenticated;

-- Compute inclusive calendar dates in the restaurant's timezone, exclusive upper bound.
create or replace function public.get_report_bounds(p_restaurant_id uuid,p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_timezone text;
begin
 if auth.uid() is null or p_restaurant_id<>auth.uid() then raise exception 'Sin permiso para ver reportes';end if;
 select timezone into v_timezone from public.profiles where id=p_restaurant_id and role='negocio';
 if not found then raise exception 'Restaurante no encontrado';end if;
 if p_from is null or p_to is null or p_from>p_to then raise exception 'Selecciona un periodo válido';end if;
 return jsonb_build_object('from',p_from::timestamp at time zone coalesce(v_timezone,'America/Mexico_City'),'to',(p_to+1)::timestamp at time zone coalesce(v_timezone,'America/Mexico_City'));
end;$$;
revoke all on function public.get_report_bounds(uuid,date,date) from public,anon;
grant execute on function public.get_report_bounds(uuid,date,date) to authenticated;

alter table public.orders add column if not exists payment_updated_at timestamptz;
create table public.payment_refund_operations(
 order_id bigint primary key references public.orders(id) on delete cascade,
 payment_id text not null,
 reason text not null,
 actor_id uuid,
 status text not null default 'pending' check(status in ('pending','completed')),
 refund_id text,
 created_at timestamptz not null default now(),
 completed_at timestamptz
);
alter table public.payment_refund_operations enable row level security;
revoke all on public.payment_refund_operations from public,anon,authenticated;
grant all on public.payment_refund_operations to service_role;

-- All payment writes are service-only and serialized on the order row.
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

create or replace function public.begin_order_refund(p_order_id bigint,p_payment_id text,p_reason text,p_actor_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order public.orders%rowtype;v_op public.payment_refund_operations%rowtype;
begin
 select * into v_order from public.orders where id=p_order_id for update;
 if not found or v_order.payment_method<>'mercado_pago' then raise exception 'Pedido no encontrado';end if;
 select * into v_op from public.payment_refund_operations where order_id=p_order_id;
 if found then
   if v_op.payment_id<>p_payment_id then raise exception 'Pago distinto al reembolso solicitado';end if;
   return to_jsonb(v_op);
 end if;
 if v_order.payment_status='refunded' then return jsonb_build_object('status','completed');end if;
 if v_order.delivery_status='delivered' then raise exception 'La entrega ya terminó';end if;
 if v_order.payment_status='approved' and v_order.mercado_pago_payment_id is distinct from p_payment_id then raise exception 'Pago distinto al aprobado';end if;
 if length(trim(coalesce(p_reason,'')))<4 then raise exception 'Motivo requerido';end if;
 insert into public.payment_refund_operations(order_id,payment_id,reason,actor_id) values(p_order_id,p_payment_id,left(trim(p_reason),300),p_actor_id) returning * into v_op;
 return to_jsonb(v_op);
end;$$;
revoke all on function public.begin_order_refund(bigint,text,text,uuid) from public,anon,authenticated;
grant execute on function public.begin_order_refund(bigint,text,text,uuid) to service_role;

create or replace function public.finish_order_refund(p_order_id bigint,p_refund_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_order public.orders%rowtype;v_op public.payment_refund_operations%rowtype;
begin
 select * into v_order from public.orders where id=p_order_id for update;
 select * into v_op from public.payment_refund_operations where order_id=p_order_id for update;
 if not found then raise exception 'Reembolso no solicitado';end if;
 if v_op.status='completed' then return jsonb_build_object('refunded',true,'refundId',v_op.refund_id);end if;
 update public.orders set payment_status='refunded',mercado_pago_payment_id=v_op.payment_id,payment_updated_at=now(),
   status='cancelado',delivery_status=case when service_type='delivery' then 'cancelled' else delivery_status end,
   cancellation_reason=v_op.reason,assigned_driver_id=null,assigned_driver_name=null where id=p_order_id;
 if v_order.service_type='delivery' then
   insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(p_order_id,v_order.restaurant_id,'cancelled','Pedido cancelado y reembolsado: '||v_op.reason,v_op.actor_id);
 end if;
 update public.payment_refund_operations set status='completed',refund_id=p_refund_id,completed_at=now() where order_id=p_order_id;
 return jsonb_build_object('refunded',true,'refundId',p_refund_id);
end;$$;
revoke all on function public.finish_order_refund(bigint,text) from public,anon,authenticated;
grant execute on function public.finish_order_refund(bigint,text) to service_role;

create or replace function public.protect_refund_in_progress()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.payment_status<>'refunded' and exists(select 1 from public.payment_refund_operations where order_id=old.id and status='pending')
 and (new.status is distinct from old.status or new.delivery_status is distinct from old.delivery_status or new.assigned_driver_id is distinct from old.assigned_driver_id) then
   raise exception 'Hay un reembolso pendiente. Reintenta el reembolso antes de continuar';end if;
 return new;
end;$$;
revoke all on function public.protect_refund_in_progress() from public,anon,authenticated;
create trigger protect_refund_in_progress before update on public.orders for each row execute function public.protect_refund_in_progress();

-- Remove direct anonymous/internal-trigger RPC access; do not change intentional public QR projections.
do $$ declare f record;begin
 for f in select p.oid::regprocedure as signature,p.prorettype from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.prosecdef and (p.prorettype in ('trigger'::regtype,'event_trigger'::regtype) or p.proname in ('get_my_restaurant_access','list_restaurant_staff','set_staff_permissions')) loop
   execute format('revoke all on function %s from public,anon',f.signature);
   if f.prorettype in ('trigger'::regtype,'event_trigger'::regtype) then execute format('revoke all on function %s from authenticated',f.signature);
   else execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;
end;$$;
commit;
