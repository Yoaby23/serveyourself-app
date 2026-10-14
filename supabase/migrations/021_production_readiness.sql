-- Correcciones de salida a produccion: caja, inventario por comanda,
-- seguridad de repartidores, recuperacion de entregas y liquidaciones.
-- Ejecutar despues de 020_driver_realtime_experience.sql.

begin;

-- La ruta antigua cerraba cuentas sin crear un pago ni asociarlo al turno.
revoke all on function public.mark_pos_order_paid(bigint,text) from public,anon,authenticated;

-- El consumo de inventario pertenece a cada comanda independiente, no a la
-- cuenta completa. Esto permite descontar correctamente rondas posteriores.
alter table public.kitchen_tickets
  add column if not exists inventory_deducted boolean not null default false;

update public.kitchen_tickets t
set inventory_deducted=true
from public.orders o
where o.id=t.order_id and o.inventory_deducted=true;

drop trigger if exists deduct_order_inventory on public.orders;

create or replace function public.deduct_kitchen_ticket_inventory()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_item jsonb;v_recipe record;v_qty numeric;
begin
  if new.status='preparando' and old.status is distinct from 'preparando' and not new.inventory_deducted then
    for v_item in select value from jsonb_array_elements(new.items) loop
      v_qty:=coalesce((v_item->>'qty')::numeric,0);
      for v_recipe in
        select r.ingredient_id,r.quantity
        from public.product_recipes r where r.product_id::text=v_item->>'id'
      loop
        update public.ingredients
        set stock=stock-(v_recipe.quantity*v_qty),updated_at=now()
        where id=v_recipe.ingredient_id and restaurant_id=new.restaurant_id;
        insert into public.inventory_movements(restaurant_id,ingredient_id,movement_type,quantity,reason,order_id)
        values(new.restaurant_id,v_recipe.ingredient_id,'sale',-(v_recipe.quantity*v_qty),'Consumo por comanda #'||new.id,new.order_id);
      end loop;
    end loop;
    new.inventory_deducted:=true;
  end if;
  return new;
end; $$;

drop trigger if exists deduct_kitchen_ticket_inventory on public.kitchen_tickets;
create trigger deduct_kitchen_ticket_inventory
before update of status on public.kitchen_tickets
for each row execute function public.deduct_kitchen_ticket_inventory();
revoke all on function public.deduct_kitchen_ticket_inventory() from public,anon,authenticated;

-- Repartidores: las altas nuevas requieren aprobacion de la plataforma.
alter table public.delivery_drivers drop constraint if exists delivery_drivers_status_check;
alter table public.delivery_drivers add constraint delivery_drivers_status_check
  check(status in('pending_review','active','suspended'));
alter table public.delivery_drivers alter column status set default 'pending_review';
update public.platform_delivery_settings set max_active_orders=1 where id=true;

create table if not exists public.platform_admins(
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
-- En una instalación existente, el primer negocio creado corresponde al
-- operador inicial de la plataforma y permite revisar las nuevas altas.
insert into public.platform_admins(user_id)
select p.id from public.profiles p where p.role='negocio'
order by p.created_at limit 1
on conflict(user_id) do nothing;
alter table public.platform_admins enable row level security;
drop policy if exists "platform_admin_read_own" on public.platform_admins;
create policy "platform_admin_read_own" on public.platform_admins for select to authenticated
using(user_id=auth.uid());

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path='' as $$
select exists(select 1 from public.platform_admins where user_id=auth.uid());
$$;

create or replace function public.list_pending_delivery_drivers()
returns table(user_id uuid,full_name text,phone text,vehicle_type text,vehicle_plate text,status text,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
  if not public.is_platform_admin() then raise exception 'Acceso de plataforma requerido';end if;
  return query select d.user_id,d.full_name,d.phone,d.vehicle_type,d.vehicle_plate,d.status,d.created_at
  from public.delivery_drivers d where d.status='pending_review' order by d.created_at;
end; $$;

create or replace function public.review_delivery_driver(p_driver_id uuid,p_approve boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare d public.delivery_drivers%rowtype;
begin
  if not public.is_platform_admin() then raise exception 'Acceso de plataforma requerido';end if;
  update public.delivery_drivers set status=case when p_approve then 'active' else 'suspended' end,
    is_available=false,updated_at=now() where user_id=p_driver_id returning * into d;
  if not found then raise exception 'Repartidor no encontrado';end if;
  return to_jsonb(d);
end; $$;

-- Una oferta descartada deja de interrumpir, pero permanece en el centro.
create table if not exists public.delivery_offer_responses(
  driver_id uuid not null references public.delivery_drivers(user_id) on delete cascade,
  order_id bigint not null references public.orders(id) on delete cascade,
  response text not null check(response in('viewed','dismissed')),
  updated_at timestamptz not null default now(),
  primary key(driver_id,order_id)
);
alter table public.delivery_offer_responses enable row level security;
drop policy if exists "driver_offer_responses_own" on public.delivery_offer_responses;
create policy "driver_offer_responses_own" on public.delivery_offer_responses for select to authenticated
using(driver_id=auth.uid());

create or replace function public.dismiss_delivery_offer(p_order_id bigint)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.delivery_drivers where user_id=auth.uid() and status='active') then
    raise exception 'Cuenta de repartidor no activa';
  end if;
  if not exists(select 1 from public.orders where id=p_order_id and service_type='delivery' and assigned_driver_id is null
    and delivery_status in('accepted','preparing','ready_for_dispatch')) then raise exception 'La oferta ya no esta disponible';end if;
  insert into public.delivery_offer_responses(driver_id,order_id,response)
  values(auth.uid(),p_order_id,'dismissed')
  on conflict(driver_id,order_id) do update set response='dismissed',updated_at=now();
end; $$;

create or replace function public.list_delivery_offers()
returns table(order_id bigint,restaurant_name text,pickup_address text,delivery_distance_km numeric,
  driver_earning numeric,item_count integer,delivery_status text,created_at timestamptz,
  offer_response text,finishing_current_order boolean)
language sql stable security definer set search_path='' as $$
with driver as(
  select * from public.delivery_drivers where user_id=auth.uid() and status='active' and is_available
), active as(
  select o.*,
    case when o.driver_latitude is not null and o.driver_longitude is not null
      and o.delivery_latitude is not null and o.delivery_longitude is not null then
      6371*2*asin(sqrt(power(sin(radians(o.delivery_latitude-o.driver_latitude)/2),2)+
      cos(radians(o.driver_latitude))*cos(radians(o.delivery_latitude))*
      power(sin(radians(o.delivery_longitude-o.driver_longitude)/2),2))) else null end remaining_km
  from public.orders o where o.assigned_driver_id=auth.uid()
    and o.delivery_status not in('delivered','cancelled')
), eligibility as(
  select not exists(select 1 from active)
    or exists(select 1 from active where delivery_status='arrived'
      or(delivery_status='on_the_way' and remaining_km<=2.5)) finishing
)
select o.id,o.restaurant_name,p.address,o.delivery_distance_km,o.driver_earning,
  coalesce(jsonb_array_length(o.items),0),o.delivery_status,o.created_at,r.response,e.finishing
from public.orders o join public.profiles p on p.id=o.restaurant_id
cross join driver d cross join eligibility e
left join public.delivery_offer_responses r on r.driver_id=auth.uid() and r.order_id=o.id
where e.finishing and o.service_type='delivery' and o.assigned_driver_id is null
  and o.delivery_status in('accepted','preparing','ready_for_dispatch')
  and(o.payment_method='cash' or o.payment_status='approved')
order by case o.delivery_status when 'ready_for_dispatch' then 0 when 'preparing' then 1 else 2 end,o.created_at;
$$;

create or replace function public.claim_delivery_order(p_order_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;d public.delivery_drivers%rowtype;
begin
  select * into d from public.delivery_drivers where user_id=auth.uid() and status='active' and is_available for update;
  if not found then raise exception 'Tu cuenta debe estar aprobada y en linea';end if;
  if exists(select 1 from public.orders where assigned_driver_id=auth.uid() and delivery_status not in('delivered','cancelled')) then
    raise exception 'Termina tu entrega activa antes de aceptar otra';
  end if;
  select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
  if not found then raise exception 'Pedido no encontrado';end if;
  if o.assigned_driver_id is not null then raise exception 'Otro repartidor ya acepto este pedido';end if;
  if o.delivery_status not in('accepted','preparing','ready_for_dispatch')
    or(o.payment_method='mercado_pago' and o.payment_status<>'approved') then raise exception 'Este pedido aun no esta disponible';end if;
  update public.orders set assigned_driver_id=auth.uid(),assigned_driver_name=d.full_name,
    assigned_at=now(),driver_claimed_at=now() where id=o.id returning * into o;
  delete from public.delivery_offer_responses where order_id=o.id;
  insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id)
  values(o.id,o.restaurant_id,o.delivery_status,'Pedido aceptado por '||d.full_name,auth.uid());
  return to_jsonb(o);
end; $$;

-- Recuperacion de pedidos abandonados e incidencias operables.
create or replace function public.release_delivery_order(p_order_id bigint,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;next_status text;
begin
  select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
  if not found then raise exception 'Pedido no encontrado';end if;
  if not(o.assigned_driver_id=auth.uid() or public.has_restaurant_permission(o.restaurant_id,'manage_delivery')) then raise exception 'Sin permiso';end if;
  if o.delivery_status in('delivered','cancelled') then raise exception 'El pedido ya esta cerrado';end if;
  if char_length(trim(coalesce(p_reason,'')))<4 then raise exception 'Indica el motivo';end if;
  next_status:=case when o.status='listo' then 'ready_for_dispatch' when o.status='preparando' then 'preparing' else 'accepted' end;
  update public.orders set assigned_driver_id=null,assigned_driver_name=null,assigned_at=null,driver_claimed_at=null,
    delivery_status=next_status,driver_latitude=null,driver_longitude=null,driver_location_at=null
  where id=o.id returning * into o;
  insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id)
  values(o.id,o.restaurant_id,next_status,'Entrega liberada: '||left(trim(p_reason),240),auth.uid());
  return to_jsonb(o);
end; $$;

create or replace function public.resolve_delivery_incident(p_incident_id bigint,p_notes text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.delivery_incidents%rowtype;
begin
  select * into i from public.delivery_incidents where id=p_incident_id for update;
  if not found or not public.has_restaurant_permission(i.restaurant_id,'manage_delivery') then raise exception 'Incidencia no encontrada';end if;
  update public.delivery_incidents set status='resolved',resolved_at=now(),notes=left(notes||case when nullif(trim(coalesce(p_notes,'')),'') is null then '' else E'\nResolucion: '||trim(p_notes) end,500)
  where id=p_incident_id returning * into i;
  return to_jsonb(i);
end; $$;

create or replace function public.cancel_delivery_order(p_order_id bigint,p_reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
  select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
  if not found or not public.has_restaurant_permission(o.restaurant_id,'manage_delivery') then raise exception 'Pedido no encontrado';end if;
  if o.delivery_status in('delivered','cancelled') then raise exception 'El pedido ya esta cerrado';end if;
  if o.payment_method='mercado_pago' and o.payment_status='approved' then raise exception 'Este pedido requiere reembolso de Mercado Pago';end if;
  if char_length(trim(coalesce(p_reason,'')))<4 then raise exception 'Indica el motivo';end if;
  update public.orders set delivery_status='cancelled',status='cancelado',cancellation_reason=left(trim(p_reason),300)
  where id=o.id returning * into o;
  insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id)
  values(o.id,o.restaurant_id,'cancelled','Pedido cancelado: '||left(trim(p_reason),240),auth.uid());
  return to_jsonb(o);
end; $$;

-- Limite de intentos del codigo de entrega.
alter table public.orders add column if not exists delivery_code_attempts integer not null default 0;
alter table public.orders add column if not exists delivery_code_locked_until timestamptz;

-- Libro de liquidaciones manuales por restaurante y repartidor.
create table if not exists public.delivery_driver_ledger(
  id bigint generated by default as identity primary key,
  restaurant_id uuid not null references public.profiles(id) on delete restrict,
  driver_id uuid not null references public.delivery_drivers(user_id) on delete restrict,
  order_id bigint references public.orders(id) on delete restrict,
  entry_type text not null check(entry_type in('earning','cash_collected','earning_paid','cash_remitted','adjustment')),
  amount numeric(12,2) not null check(amount>0),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index if not exists delivery_driver_ledger_order_entry_unique
on public.delivery_driver_ledger(order_id,entry_type) where order_id is not null and entry_type in('earning','cash_collected');
create index if not exists delivery_driver_ledger_driver_idx on public.delivery_driver_ledger(driver_id,created_at desc);
alter table public.delivery_driver_ledger enable row level security;
drop policy if exists "driver_ledger_read" on public.delivery_driver_ledger;
create policy "driver_ledger_read" on public.delivery_driver_ledger for select to authenticated
using(driver_id=auth.uid() or public.has_restaurant_permission(restaurant_id,'manage_delivery'));

create or replace function public.get_driver_financial_summary()
returns jsonb language sql stable security definer set search_path='' as $$
select jsonb_build_object(
 'earnings',coalesce(sum(amount) filter(where entry_type='earning'),0),
 'earnings_paid',coalesce(sum(amount) filter(where entry_type='earning_paid'),0),
 'cash_collected',coalesce(sum(amount) filter(where entry_type='cash_collected'),0),
 'cash_remitted',coalesce(sum(amount) filter(where entry_type='cash_remitted'),0),
 'earnings_due',greatest(coalesce(sum(amount) filter(where entry_type='earning'),0)-coalesce(sum(amount) filter(where entry_type='earning_paid'),0),0),
 'cash_due',greatest(coalesce(sum(amount) filter(where entry_type='cash_collected'),0)-coalesce(sum(amount) filter(where entry_type='cash_remitted'),0),0)
) from public.delivery_driver_ledger where driver_id=auth.uid();
$$;

create or replace function public.list_delivery_settlement_balances(p_restaurant_id uuid)
returns table(driver_id uuid,full_name text,earnings numeric,earnings_paid numeric,cash_collected numeric,cash_remitted numeric)
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.has_restaurant_permission(p_restaurant_id,'manage_delivery') then raise exception 'Sin permiso de delivery';end if;
 return query select l.driver_id,d.full_name,
  coalesce(sum(l.amount) filter(where l.entry_type='earning'),0)::numeric,
  coalesce(sum(l.amount) filter(where l.entry_type='earning_paid'),0)::numeric,
  coalesce(sum(l.amount) filter(where l.entry_type='cash_collected'),0)::numeric,
  coalesce(sum(l.amount) filter(where l.entry_type='cash_remitted'),0)::numeric
 from public.delivery_driver_ledger l join public.delivery_drivers d on d.user_id=l.driver_id
 where l.restaurant_id=p_restaurant_id group by l.driver_id,d.full_name order by d.full_name;
end; $$;

create or replace function public.record_delivery_settlement(p_restaurant_id uuid,p_driver_id uuid,p_type text,p_amount numeric,p_notes text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare available numeric;entry public.delivery_driver_ledger%rowtype;v_shift_id uuid;
begin
 if not public.has_restaurant_permission(p_restaurant_id,'manage_delivery') then raise exception 'Sin permiso de delivery';end if;
 if p_type not in('earning_paid','cash_remitted') or p_amount is null or p_amount<=0 then raise exception 'Liquidacion invalida';end if;
 select id into v_shift_id from public.cash_shifts where restaurant_id=p_restaurant_id and status='open' for update;
 if v_shift_id is null then raise exception 'Abre un turno de caja antes de registrar una liquidacion';end if;
 select case when p_type='earning_paid' then
   coalesce(sum(amount) filter(where entry_type='earning'),0)-coalesce(sum(amount) filter(where entry_type='earning_paid'),0)
  else coalesce(sum(amount) filter(where entry_type='cash_collected'),0)-coalesce(sum(amount) filter(where entry_type='cash_remitted'),0) end
 into available from public.delivery_driver_ledger where restaurant_id=p_restaurant_id and driver_id=p_driver_id;
 if p_amount>coalesce(available,0) then raise exception 'El importe supera el saldo pendiente';end if;
 insert into public.delivery_driver_ledger(restaurant_id,driver_id,entry_type,amount,notes,created_by)
 values(p_restaurant_id,p_driver_id,p_type,round(p_amount,2),nullif(left(trim(coalesce(p_notes,'')),300),''),auth.uid()) returning * into entry;
 insert into public.cash_movements(shift_id,restaurant_id,movement_type,amount,reason,created_by)
 values(v_shift_id,p_restaurant_id,case when p_type='cash_remitted' then 'income' else 'expense' end,round(p_amount,2),
   case when p_type='cash_remitted' then 'Efectivo entregado por repartidor' else 'Pago de ganancias a repartidor' end,auth.uid());
 return to_jsonb(entry);
end; $$;

create or replace function public.confirm_delivery(p_order_id bigint,p_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;attempts integer;
begin
 select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
 if not found then raise exception 'Pedido no encontrado';end if;
 if o.assigned_driver_id is distinct from auth.uid() then raise exception 'Pedido no asignado';end if;
 if o.delivery_status not in('on_the_way','arrived') then raise exception 'Marca primero la llegada';end if;
 if o.delivery_code_locked_until is not null and o.delivery_code_locked_until>now() then
   return jsonb_build_object('ok',false,'code','locked','message','Demasiados intentos. Espera 15 minutos.');
 end if;
 if trim(coalesce(p_code,''))<>o.delivery_code then
   attempts:=o.delivery_code_attempts+1;
   update public.orders set delivery_code_attempts=case when attempts>=5 then 0 else attempts end,
     delivery_code_locked_until=case when attempts>=5 then now()+interval '15 minutes' else null end where id=o.id;
   return jsonb_build_object('ok',false,'code','invalid','remaining_attempts',greatest(5-attempts,0),
     'message',case when attempts>=5 then 'Demasiados intentos. Espera 15 minutos.' else 'Codigo de entrega incorrecto' end);
 end if;
 if o.payment_method='cash' and not exists(select 1 from public.order_payments where order_id=o.id) then
   insert into public.order_payments(order_id,restaurant_id,shift_id,payment_method,amount,tip_amount,cash_received,cash_change,received_by)
   values(o.id,o.restaurant_id,null,'cash',o.total,0,o.total,0,auth.uid());
 end if;
 update public.orders set delivery_status='delivered',status='entregado',delivered_at=now(),
   payment_status=case when payment_method='cash' then 'approved' else payment_status end,
   delivery_code_attempts=0,delivery_code_locked_until=null where id=o.id returning * into o;
 update public.delivery_drivers set completed_deliveries=completed_deliveries+1,
   total_earnings=total_earnings+o.driver_earning,updated_at=now() where user_id=auth.uid();
 insert into public.delivery_driver_ledger(restaurant_id,driver_id,order_id,entry_type,amount,created_by)
 values(o.restaurant_id,auth.uid(),o.id,'earning',o.driver_earning,auth.uid()) on conflict do nothing;
 if o.payment_method='cash' then
   insert into public.delivery_driver_ledger(restaurant_id,driver_id,order_id,entry_type,amount,created_by)
   values(o.restaurant_id,auth.uid(),o.id,'cash_collected',o.total,auth.uid()) on conflict do nothing;
 end if;
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id)
 values(o.id,o.restaurant_id,'delivered','Pedido entregado',auth.uid());
 return to_jsonb(o)||jsonb_build_object('ok',true);
end; $$;

revoke all on function public.is_platform_admin(),public.list_pending_delivery_drivers(),public.review_delivery_driver(uuid,boolean),
 public.dismiss_delivery_offer(bigint),public.list_delivery_offers(),public.claim_delivery_order(bigint),
 public.release_delivery_order(bigint,text),public.resolve_delivery_incident(bigint,text),public.cancel_delivery_order(bigint,text),
 public.get_driver_financial_summary(),public.list_delivery_settlement_balances(uuid),
 public.record_delivery_settlement(uuid,uuid,text,numeric,text),public.confirm_delivery(bigint,text) from public,anon;
grant execute on function public.is_platform_admin(),public.list_pending_delivery_drivers(),public.review_delivery_driver(uuid,boolean),
 public.dismiss_delivery_offer(bigint),public.list_delivery_offers(),public.claim_delivery_order(bigint),
 public.release_delivery_order(bigint,text),public.resolve_delivery_incident(bigint,text),public.cancel_delivery_order(bigint,text),
 public.get_driver_financial_summary(),public.list_delivery_settlement_balances(uuid),
 public.record_delivery_settlement(uuid,uuid,text,numeric,text),public.confirm_delivery(bigint,text) to authenticated;
grant select on public.delivery_driver_ledger to authenticated;

commit;
