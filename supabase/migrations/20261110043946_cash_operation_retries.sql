create table public.cash_operation_requests(
 actor_id uuid not null references auth.users(id),request_id uuid not null,
 restaurant_id uuid not null references public.profiles(id),operation text not null,
 payload jsonb not null,result jsonb not null,created_at timestamptz not null default now(),
 primary key(actor_id,request_id)
);
alter table public.cash_operation_requests enable row level security;
revoke all on public.cash_operation_requests from public,anon,authenticated;
grant select on public.cash_operation_requests to service_role;
create function public.record_cash_operation_once(p_request_id uuid,p_operation text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior public.cash_operation_requests%rowtype; result jsonb; restaurant uuid;
begin
 if auth.uid() is null or p_request_id is null or p_operation is null or p_operation not in ('order_payment','credit_payment') or p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Operación inválida';end if;
 if p_operation='order_payment' then
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
 else
  result:=public.record_customer_credit_payment((p_payload->>'p_customer_id')::uuid,(p_payload->>'p_amount')::numeric,p_payload->>'p_payment_method',(p_payload->>'p_cash_received')::numeric,p_payload->>'p_notes');
 end if;
 insert into public.cash_operation_requests(actor_id,request_id,restaurant_id,operation,payload,result) values(auth.uid(),p_request_id,restaurant,p_operation,p_payload,result);
 return result;
end;$$;
revoke all on function public.record_cash_operation_once(uuid,text,jsonb) from public,anon;
grant execute on function public.record_cash_operation_once(uuid,text,jsonb) to authenticated;
