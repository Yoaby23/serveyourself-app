-- Permite imprimir la precuenta del POS antes de confirmar el cobro.
-- Ejecutar despues de 004_pos_kitchen_qr.sql.

begin;

create or replace function public.set_new_pos_order_pending()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.order_source = 'pos' then
        new.payment_status := 'pending';
    end if;
    return new;
end;
$$;

revoke all on function public.set_new_pos_order_pending() from public, anon, authenticated;

drop trigger if exists set_new_pos_order_pending on public.orders;
create trigger set_new_pos_order_pending
before insert on public.orders
for each row execute function public.set_new_pos_order_pending();

create or replace function public.mark_pos_order_paid(
    p_order_id bigint,
    p_payment_method text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_order public.orders%rowtype;
begin
    if p_payment_method not in ('cash', 'transfer', 'card_terminal') then
        raise exception 'Metodo de pago invalido';
    end if;

    select * into v_order
    from public.orders
    where id = p_order_id
    for update;

    if not found or v_order.order_source <> 'pos' then
        raise exception 'Pedido de punto de venta no encontrado';
    end if;
    if not public.has_restaurant_access(v_order.restaurant_id, array['waiter', 'manager']) then
        raise exception 'No tienes permiso para registrar este cobro';
    end if;
    if v_order.status = 'cancelado' then
        raise exception 'No se puede cobrar un pedido cancelado';
    end if;
    if v_order.payment_status = 'approved' then
        raise exception 'Este pedido ya fue pagado';
    end if;

    update public.orders
    set payment_method = p_payment_method,
        payment_status = 'approved'
    where id = p_order_id
    returning * into v_order;

    return to_jsonb(v_order);
end;
$$;

revoke all on function public.mark_pos_order_paid(bigint, text) from public, anon;
grant execute on function public.mark_pos_order_paid(bigint, text) to authenticated;

commit;
