-- All pickup entry points share the same payment gate, including POS and signed-in customers.
create or replace function public.enforce_pickup_payment_gate()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='UPDATE' and old.service_type='pickup' and new.service_type is distinct from 'pickup'
 and old.payment_status<>'approved' and old.status not in ('cancelado','entregado') then
  raise exception 'Liquida el pedido para llevar antes de cambiar el tipo de servicio';
 end if;
 if new.service_type='pickup' then
  new.payment_before_kitchen:=true;
  if new.payment_status='not_required' then new.payment_status:='pending';end if;
  if new.payment_status='on_credit' then raise exception 'Los pedidos para llevar requieren pago completo; no admiten crédito';end if;
  if (tg_op='INSERT' or new.status is distinct from old.status)
   and new.payment_status is distinct from 'approved' and new.status in ('preparando','listo','entregado') then
   raise exception 'Liquida el pedido para llevar antes de enviarlo a cocina';
  end if;
  if tg_op='UPDATE' and old.service_type is distinct from 'pickup' and new.payment_status is distinct from 'approved'
   and exists(select 1 from public.kitchen_tickets where order_id=new.id and status<>'cancelado') then
   raise exception 'Liquida la cuenta antes de convertir una comanda de mesa en pedido para llevar';
  end if;
 end if;
 return new;
end;$$;
revoke all on function public.enforce_pickup_payment_gate() from public,anon,authenticated;
create trigger enforce_pickup_payment_gate before insert or update on public.orders
for each row execute function public.enforce_pickup_payment_gate();

-- Existing unpaid pickup tickets cannot remain visible in kitchen. Preserve audit history.
update public.kitchen_tickets t set status='cancelado'
from public.orders o where t.order_id=o.id and o.service_type='pickup'
and o.payment_status<>'approved' and o.status not in ('entregado','cancelado') and t.status not in ('entregado','cancelado');
update public.orders set payment_before_kitchen=true,status=case when payment_status<>'approved' then 'pendiente' else status end
where service_type='pickup' and status not in ('entregado','cancelado');

do $$
declare definition text;
begin
 definition:=pg_get_functiondef('public.create_kitchen_ticket(bigint,jsonb,text)'::regprocedure);
 definition:=replace(definition,'    if jsonb_typeof(p_items)',
  '    if v_order.service_type=''pickup'' and v_order.payment_status is distinct from ''approved'' then return null;end if;'||chr(10)||'    if jsonb_typeof(p_items)');
 execute definition;
 definition:=pg_get_functiondef('public.sync_online_order_kitchen_ticket()'::regprocedure);
 definition:=replace(definition,'new.order_source=''pos'' or','(new.order_source=''pos'' and new.service_type<>''pickup'') or');
 definition:=replace(definition,'where t.order_id=new.id)','where t.order_id=new.id and t.status<>''cancelado'')');
 execute definition;
 -- Online cash pickup with an account uses the same cashier payment operation as guest cash.
 definition:=pg_get_functiondef('public.register_pos_payment_v2(bigint,text,numeric,numeric,numeric)'::regprocedure);
 definition:=replace(definition,' and exists(select 1 from public.guest_checkout_requests where order_id=p_order_id)','');
 execute definition;
end;$$;

-- Enforce the invariant even if an internal helper or a stale client attempts ticket creation.
create or replace function public.guard_pickup_kitchen_ticket()
returns trigger language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=new.order_id for update;
 if o.service_type='pickup' and o.payment_status is distinct from 'approved' and new.status<>'cancelado' then
  raise exception 'El pedido para llevar debe estar pagado antes de entrar a cocina';
 end if;
 return new;
end;$$;
revoke all on function public.guard_pickup_kitchen_ticket() from public,anon,authenticated;
create trigger guard_pickup_kitchen_ticket before insert or update on public.kitchen_tickets
for each row execute function public.guard_pickup_kitchen_ticket();
