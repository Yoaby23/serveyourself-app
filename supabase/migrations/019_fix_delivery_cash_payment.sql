-- Corrige el cobro contra entrega después de agregar el control de efectivo
-- recibido y cambio en 017_cash_change_and_waiter_delivery.sql.

begin;

create or replace function public.confirm_delivery(p_order_id bigint,p_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;
begin
 select * into o from public.orders where id=p_order_id and service_type='delivery' for update;
 if not found then raise exception 'Pedido no encontrado';end if;
 if o.assigned_driver_id is distinct from auth.uid() then raise exception 'Pedido no asignado';end if;
 if o.delivery_status not in('on_the_way','arrived') then raise exception 'Marca primero la llegada';end if;
 if trim(p_code)<>o.delivery_code then raise exception 'Codigo de entrega incorrecto';end if;

 -- En pago contra entrega, el repartidor recibe exactamente el total del pedido.
 -- La restricción contable exige guardar también efectivo recibido y cambio.
 if o.payment_method='cash' and not exists(select 1 from public.order_payments where order_id=o.id) then
   insert into public.order_payments(
     order_id,restaurant_id,shift_id,payment_method,amount,tip_amount,
     cash_received,cash_change,received_by
   ) values(
     o.id,o.restaurant_id,null,'cash',o.total,0,
     o.total,0,auth.uid()
   );
 end if;

 update public.orders
 set delivery_status='delivered',status='entregado',delivered_at=now(),
     payment_status=case when payment_method='cash' then 'approved' else payment_status end
 where id=o.id returning * into o;
 update public.delivery_drivers
 set is_available=true,completed_deliveries=completed_deliveries+1,
     total_earnings=total_earnings+o.driver_earning,updated_at=now()
 where user_id=auth.uid();
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id)
 values(o.id,o.restaurant_id,'delivered','Pedido entregado',auth.uid());
 return to_jsonb(o);
end; $$;

revoke all on function public.confirm_delivery(bigint,text) from public,anon;
grant execute on function public.confirm_delivery(bigint,text) to authenticated;

commit;
