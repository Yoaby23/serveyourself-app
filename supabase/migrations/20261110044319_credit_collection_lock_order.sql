CREATE OR REPLACE FUNCTION public.record_customer_credit_payment(p_customer_id uuid, p_amount numeric, p_payment_method text, p_cash_received numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_customer public.loyalty_customers%rowtype;
    v_shift public.cash_shifts%rowtype;
    v_balance numeric:=0;
    v_change numeric;
    v_transaction public.customer_credit_transactions%rowtype;
begin
    select * into v_customer from public.loyalty_customers where id=p_customer_id;
    if not found then raise exception 'Cliente no encontrado';end if;
    if not public.has_restaurant_permission(v_customer.restaurant_id,'close_accounts') then raise exception 'Sin permiso de caja';end if;
    select * into v_shift from public.cash_shifts where restaurant_id=v_customer.restaurant_id and status='open' for update;
    if not found then raise exception 'Primero abre un turno de caja';end if;
    select * into v_customer from public.loyalty_customers where id=p_customer_id and restaurant_id=v_shift.restaurant_id for update;
    if not found then raise exception 'Cliente no encontrado';end if;
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
end; $function$;
