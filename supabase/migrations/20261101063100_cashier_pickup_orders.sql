-- Reuse the existing POS flow. Cashiers can create pickup orders only;
-- salon/table management still requires the independent create_orders permission.
do $$
declare signature text; definition text; original text; replacement text;
begin
 foreach signature in array array[
  'public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint,text)',
  'public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint)',
  'public.create_pos_order(uuid,jsonb,text,text,bigint,text)'
 ] loop
  definition:=pg_get_functiondef(signature::regprocedure);
  original:=case when signature='public.create_pos_order(uuid,jsonb,text,text,bigint,text)'
   then 'public.has_restaurant_permission(p_restaurant_id, ''create_orders'')'
   else 'public.has_restaurant_permission(p_restaurant_id,''create_orders'')' end;
  if position(original in definition)=0 then raise exception 'Unexpected permission guard in %',signature;end if;
  replacement:='(public.has_restaurant_permission(p_restaurant_id,''create_orders'') or (coalesce(p_service_type=''pickup'',false) and public.has_restaurant_permission(p_restaurant_id,''close_accounts'')))';
  execute replace(definition,original,replacement);
 end loop;
end;$$;
-- No new RPC surface: legacy signatures stay inaccessible to clients.
revoke all on function public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint),public.create_pos_order(uuid,jsonb,text,text,bigint,text) from public,anon,authenticated;
do $$
declare definition text; original text:='public.has_restaurant_permission(v_order.restaurant_id,''create_orders'')';
begin
 definition:=pg_get_functiondef('public.create_kitchen_ticket(bigint,jsonb,text)'::regprocedure);
 if position(original in definition)=0 then raise exception 'Unexpected kitchen ticket permission guard';end if;
 execute replace(definition,original,'(public.has_restaurant_permission(v_order.restaurant_id,''create_orders'') or (v_order.service_type=''pickup'' and v_order.order_source=''pos'' and public.has_restaurant_permission(v_order.restaurant_id,''close_accounts'')))');
end;$$;
revoke all on function public.create_kitchen_ticket(bigint,jsonb,text) from public,anon,authenticated;
