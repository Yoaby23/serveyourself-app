-- Caja operativa real, bloqueo de comandas sin turno y cartera de clientes.
-- Ejecutar despues de 017_cash_change_and_waiter_delivery.sql.

begin;

alter table public.cash_shifts
    add column if not exists cash_sales numeric(12,2),
    add column if not exists transfer_sales numeric(12,2),
    add column if not exists card_sales numeric(12,2),
    add column if not exists credit_sales numeric(12,2),
    add column if not exists credit_collections_cash numeric(12,2),
    add column if not exists credit_collections_transfer numeric(12,2),
    add column if not exists credit_collections_card numeric(12,2);

alter table public.loyalty_customers
    add column if not exists credit_enabled boolean not null default false,
    add column if not exists credit_limit numeric(12,2);

alter table public.loyalty_customers drop constraint if exists loyalty_customers_credit_limit_check;
alter table public.loyalty_customers add constraint loyalty_customers_credit_limit_check
    check (credit_limit is null or credit_limit >= 0);

alter table public.orders
    add column if not exists credit_customer_id uuid references public.loyalty_customers(id) on delete set null;

alter table public.orders drop constraint if exists orders_payment_method_check;
alter table public.orders add constraint orders_payment_method_check
    check (payment_method in ('cash','transfer','mercado_pago','card_terminal','mixed','credit'));

alter table public.orders drop constraint if exists orders_payment_status_check;
alter table public.orders add constraint orders_payment_status_check
    check (payment_status in ('pending','approved','rejected','refunded','not_required','expired','on_credit'));

create table if not exists public.customer_credit_transactions (
    id uuid primary key default gen_random_uuid(),
    restaurant_id uuid not null references public.profiles(id) on delete cascade,
    customer_id uuid not null references public.loyalty_customers(id) on delete restrict,
    order_id bigint references public.orders(id) on delete restrict,
    shift_id uuid not null references public.cash_shifts(id) on delete restrict,
    entry_type text not null check (entry_type in ('charge','payment')),
    amount numeric(12,2) not null check (amount > 0),
    payment_method text check (payment_method in ('cash','transfer','card_terminal')),
    cash_received numeric(12,2),
    cash_change numeric(12,2),
    due_date date,
    notes text,
    created_by uuid not null references auth.users(id) on delete restrict,
    created_at timestamptz not null default now(),
    check (
        (entry_type='charge' and payment_method is null and cash_received is null and cash_change is null)
        or
        (entry_type='payment' and payment_method is not null and (
            (payment_method='cash' and cash_received is not null and cash_received>=amount and cash_change=cash_received-amount)
            or (payment_method<>'cash' and cash_received is null and cash_change is null)
        ))
    )
);

create unique index if not exists customer_credit_one_charge_per_order
    on public.customer_credit_transactions(order_id) where entry_type='charge';
create index if not exists customer_credit_restaurant_customer_idx
    on public.customer_credit_transactions(restaurant_id,customer_id,created_at);

alter table public.customer_credit_transactions enable row level security;

drop policy if exists "customer_credit_cashier_read" on public.customer_credit_transactions;
create policy "customer_credit_cashier_read" on public.customer_credit_transactions for select to authenticated
using (public.has_restaurant_permission(restaurant_id,'close_accounts'));

drop policy if exists "loyalty_cashier_read" on public.loyalty_customers;
create policy "loyalty_cashier_read" on public.loyalty_customers for select to authenticated
using (public.has_restaurant_permission(restaurant_id,'close_accounts'));

grant select on public.customer_credit_transactions to authenticated;

create or replace function public.enforce_open_cash_shift_on_pos()
returns trigger language plpgsql security definer set search_path='' as $$
begin
    if new.order_source='pos' then
        if tg_op='INSERT' then
            if not exists (select 1 from public.cash_shifts where restaurant_id=new.restaurant_id and status='open') then
                raise exception 'Caja cerrada: abre un turno antes de enviar comandas';
            end if;
        elsif new.items is distinct from old.items or new.total is distinct from old.total or new.table_id is distinct from old.table_id then
            if not exists (select 1 from public.cash_shifts where restaurant_id=new.restaurant_id and status='open') then
                raise exception 'Caja cerrada: abre un turno antes de enviar comandas';
            end if;
        end if;
    end if;
    return new;
end; $$;

drop trigger if exists require_open_cash_shift_for_pos on public.orders;
create trigger require_open_cash_shift_for_pos
before insert or update of items,total,table_id on public.orders
for each row execute function public.enforce_open_cash_shift_on_pos();
revoke all on function public.enforce_open_cash_shift_on_pos() from public,anon,authenticated;

create or replace function public.get_pos_shift_status(p_restaurant_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_shift public.cash_shifts%rowtype;
begin
    if not public.has_restaurant_access(p_restaurant_id) then raise exception 'Sin acceso al restaurante';end if;
    select * into v_shift from public.cash_shifts
      where restaurant_id=p_restaurant_id and status='open' order by opened_at desc limit 1;
    if not found then return jsonb_build_object('is_open',false);end if;
    return jsonb_build_object('is_open',true,'id',v_shift.id,'opened_at',v_shift.opened_at,'opened_by',v_shift.opened_by);
end; $$;

create or replace function public.get_open_cash_shift_summary(p_restaurant_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
    v_shift public.cash_shifts%rowtype;v_cash numeric:=0;v_transfer numeric:=0;v_card numeric:=0;
    v_credit numeric:=0;v_credit_cash numeric:=0;v_credit_transfer numeric:=0;v_credit_card numeric:=0;
    v_movements numeric:=0;v_open_accounts jsonb:='[]'::jsonb;
begin
    if not public.has_restaurant_permission(p_restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
    select * into v_shift from public.cash_shifts where restaurant_id=p_restaurant_id and status='open' order by opened_at desc limit 1;
    if not found then return jsonb_build_object('is_open',false,'open_accounts','[]'::jsonb);end if;
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
    select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'location',q.location,'balance',q.balance) order by q.id),'[]'::jsonb)
      into v_open_accounts
    from (
      select o.id,case when t.name is not null then t.name else 'Para llevar' end location,
        greatest(o.total-coalesce(sum(p.amount),0),0) balance
      from public.orders o left join public.restaurant_tables t on t.id=o.table_id
      left join public.order_payments p on p.order_id=o.id
      where o.restaurant_id=p_restaurant_id and o.order_source='pos' and o.payment_status='pending' and o.status<>'cancelado'
      group by o.id,t.name,o.total
    ) q;
    return jsonb_build_object('is_open',true,'shift_id',v_shift.id,'opened_at',v_shift.opened_at,
      'opening_cash',v_shift.opening_cash,'cash_sales',v_cash,'transfer_sales',v_transfer,'card_sales',v_card,
      'credit_sales',v_credit,'credit_collections_cash',v_credit_cash,'credit_collections_transfer',v_credit_transfer,
      'credit_collections_card',v_credit_card,'movements',v_movements,
      'expected_cash',v_shift.opening_cash+v_cash+v_credit_cash+v_movements,'open_accounts',v_open_accounts);
end; $$;

create or replace function public.set_customer_credit_settings(
    p_restaurant_id uuid,
    p_customer_id uuid,
    p_enabled boolean,
    p_credit_limit numeric default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_customer public.loyalty_customers%rowtype;
begin
    if p_restaurant_id is distinct from auth.uid() then raise exception 'Solo el propietario puede autorizar credito';end if;
    if p_credit_limit is not null and p_credit_limit<0 then raise exception 'El limite no puede ser negativo';end if;
    p_credit_limit:=case when p_credit_limit is null then null else round(p_credit_limit,2) end;
    update public.loyalty_customers set credit_enabled=p_enabled,
      credit_limit=case when p_enabled then p_credit_limit else credit_limit end,updated_at=now()
    where id=p_customer_id and restaurant_id=p_restaurant_id returning * into v_customer;
    if not found then raise exception 'Cliente no encontrado';end if;
    return to_jsonb(v_customer);
end; $$;

create or replace function public.get_customer_credit_balances(p_restaurant_id uuid)
returns table(
    customer_id uuid,
    customer_name text,
    phone text,
    credit_enabled boolean,
    credit_limit numeric,
    balance numeric,
    overdue_balance numeric,
    next_due_date date,
    last_activity timestamptz
) language plpgsql stable security definer set search_path='' as $$
begin
    if not public.has_restaurant_permission(p_restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
    return query
    select c.id,c.customer_name,c.phone,c.credit_enabled,c.credit_limit,
      coalesce(sum(case when t.entry_type='charge' then t.amount else -t.amount end),0)::numeric,
      greatest(coalesce(sum(case when t.entry_type='charge' and t.due_date<current_date then t.amount when t.entry_type='payment' then -t.amount else 0 end),0),0)::numeric,
      min(t.due_date) filter(where t.entry_type='charge' and t.due_date>=current_date),
      max(t.created_at)
    from public.loyalty_customers c
    left join public.customer_credit_transactions t on t.customer_id=c.id
    where c.restaurant_id=p_restaurant_id
    group by c.id,c.customer_name,c.phone,c.credit_enabled,c.credit_limit
    order by coalesce(sum(case when t.entry_type='charge' then t.amount else -t.amount end),0) desc,c.customer_name;
end; $$;

create or replace function public.charge_order_to_customer_credit(
    p_order_id bigint,
    p_customer_id uuid,
    p_due_date date default null,
    p_notes text default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
    v_order public.orders%rowtype;
    v_customer public.loyalty_customers%rowtype;
    v_shift public.cash_shifts%rowtype;
    v_paid numeric:=0;
    v_balance numeric:=0;
    v_charge numeric:=0;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' then raise exception 'Cuenta no encontrada';end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Solo caja puede autorizar credito';end if;
    if v_order.status='cancelado' or v_order.payment_status<>'pending' then raise exception 'La cuenta ya no admite credito';end if;
    select * into v_shift from public.cash_shifts where restaurant_id=v_order.restaurant_id and status='open' for update;
    if not found then raise exception 'Primero abre un turno de caja';end if;
    select * into v_customer from public.loyalty_customers where id=p_customer_id and restaurant_id=v_order.restaurant_id for update;
    if not found or not v_customer.credit_enabled then raise exception 'El cliente no tiene credito autorizado';end if;
    if p_due_date is not null and p_due_date<current_date then raise exception 'La fecha de vencimiento no puede estar en el pasado';end if;
    select coalesce(sum(amount),0) into v_paid from public.order_payments where order_id=p_order_id;
    v_charge:=round(v_order.total-v_paid,2);
    if v_charge<=0 then raise exception 'La cuenta no tiene saldo pendiente';end if;
    select coalesce(sum(case when entry_type='charge' then amount else -amount end),0)
      into v_balance from public.customer_credit_transactions where customer_id=p_customer_id;
    if v_customer.credit_limit is not null and v_balance+v_charge>v_customer.credit_limit then
        raise exception 'El credito excede el limite disponible del cliente';
    end if;
    insert into public.customer_credit_transactions(restaurant_id,customer_id,order_id,shift_id,entry_type,amount,due_date,notes,created_by)
    values(v_order.restaurant_id,p_customer_id,p_order_id,v_shift.id,'charge',v_charge,p_due_date,nullif(left(trim(coalesce(p_notes,'')),300),''),auth.uid());
    update public.orders set payment_status='on_credit',credit_customer_id=p_customer_id,
      payment_method=case when v_paid>0 then 'mixed' else 'credit' end
    where id=p_order_id returning * into v_order;
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    values(p_order_id,v_order.restaurant_id,'credit_charge',jsonb_build_object('customer_id',p_customer_id,'amount',v_charge,'due_date',p_due_date),auth.uid());
    return to_jsonb(v_order)||jsonb_build_object('credit_amount',v_charge,'customer_name',v_customer.customer_name);
end; $$;

create or replace function public.record_customer_credit_payment(
    p_customer_id uuid,
    p_amount numeric,
    p_payment_method text,
    p_cash_received numeric default null,
    p_notes text default null
)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
    v_customer public.loyalty_customers%rowtype;
    v_shift public.cash_shifts%rowtype;
    v_balance numeric:=0;
    v_change numeric;
    v_transaction public.customer_credit_transactions%rowtype;
begin
    select * into v_customer from public.loyalty_customers where id=p_customer_id for update;
    if not found then raise exception 'Cliente no encontrado';end if;
    if not public.has_restaurant_permission(v_customer.restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
    select * into v_shift from public.cash_shifts where restaurant_id=v_customer.restaurant_id and status='open' for update;
    if not found then raise exception 'Primero abre un turno de caja';end if;
    if p_amount is null or p_amount<=0 or p_payment_method not in('cash','transfer','card_terminal') then raise exception 'Pago invalido';end if;
    p_amount:=round(p_amount,2);
    select coalesce(sum(case when entry_type='charge' then amount else -amount end),0)
      into v_balance from public.customer_credit_transactions where customer_id=p_customer_id;
    if p_amount>v_balance then raise exception 'El abono supera el saldo del cliente';end if;
    if p_payment_method='cash' then
        if p_cash_received is null or p_cash_received<p_amount then raise exception 'El efectivo recibido no alcanza';end if;
        p_cash_received:=round(p_cash_received,2);
        v_change:=round(p_cash_received-p_amount,2);
    else
        p_cash_received:=null;v_change:=null;
    end if;
    insert into public.customer_credit_transactions(restaurant_id,customer_id,shift_id,entry_type,amount,payment_method,cash_received,cash_change,notes,created_by)
    values(v_customer.restaurant_id,p_customer_id,v_shift.id,'payment',p_amount,p_payment_method,p_cash_received,v_change,nullif(left(trim(coalesce(p_notes,'')),300),''),auth.uid())
    returning * into v_transaction;
    if v_balance-p_amount<=0 then
        update public.orders set payment_status='approved'
        where credit_customer_id=p_customer_id and payment_status='on_credit';
    end if;
    return to_jsonb(v_transaction)||jsonb_build_object('remaining',greatest(v_balance-p_amount,0));
end; $$;

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
    v_tip numeric:=round(coalesce(p_tip,0),2);v_change numeric;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' then raise exception 'Cuenta no encontrada';end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'close_accounts') then raise exception 'Solo caja puede cobrar';end if;
    if v_order.status='cancelado' or v_order.payment_status<>'pending' then raise exception 'La cuenta no admite pagos';end if;
    if p_payment_method not in('cash','transfer','card_terminal') or p_amount is null or p_amount<=0 or v_tip<0 then raise exception 'Pago invalido';end if;
    p_amount:=round(p_amount,2);
    select id into v_shift_id from public.cash_shifts where restaurant_id=v_order.restaurant_id and status='open' for update;
    if v_shift_id is null then raise exception 'Primero abre un turno de caja';end if;
    select coalesce(sum(amount),0) into v_paid from public.order_payments where order_id=p_order_id;
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

create or replace function public.close_cash_shift(p_restaurant_id uuid,p_counted_cash numeric,p_notes text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
    v_shift public.cash_shifts%rowtype;v_cash numeric:=0;v_transfer numeric:=0;v_card numeric:=0;
    v_credit numeric:=0;v_credit_cash numeric:=0;v_credit_transfer numeric:=0;v_credit_card numeric:=0;
    v_movements numeric:=0;v_expected numeric:=0;
    v_open_count integer:=0;v_open_labels text;
begin
    if not public.has_restaurant_permission(p_restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
    if p_counted_cash is null or p_counted_cash<0 then raise exception 'El efectivo contado no puede ser negativo';end if;
    p_counted_cash:=round(p_counted_cash,2);
    select * into v_shift from public.cash_shifts where restaurant_id=p_restaurant_id and status='open' for update;
    if not found then raise exception 'No hay turno abierto';end if;
    select count(*),string_agg('#'||o.id::text||case when t.name is not null then ' · '||t.name else ' · Para llevar' end,', ' order by o.id)
      into v_open_count,v_open_labels
    from public.orders o left join public.restaurant_tables t on t.id=o.table_id
    where o.restaurant_id=p_restaurant_id and o.order_source='pos' and o.payment_status='pending' and o.status<>'cancelado';
    if v_open_count>0 then raise exception 'Hay % cuenta(s) abierta(s): %. Cierra o pasa a credito antes del corte',v_open_count,v_open_labels;end if;
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
    return to_jsonb(v_shift)||jsonb_build_object('open_accounts',0);
end; $$;

revoke all on function public.get_pos_shift_status(uuid),public.get_open_cash_shift_summary(uuid),public.set_customer_credit_settings(uuid,uuid,boolean,numeric),
  public.get_customer_credit_balances(uuid),public.charge_order_to_customer_credit(bigint,uuid,date,text),
  public.record_customer_credit_payment(uuid,numeric,text,numeric,text) from public,anon;
grant execute on function public.get_pos_shift_status(uuid),public.get_open_cash_shift_summary(uuid),public.set_customer_credit_settings(uuid,uuid,boolean,numeric),
  public.get_customer_credit_balances(uuid),public.charge_order_to_customer_credit(bigint,uuid,date,text),
  public.record_customer_credit_payment(uuid,numeric,text,numeric,text) to authenticated;

commit;
