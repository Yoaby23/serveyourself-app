begin;
create or replace function public.transfer_pos_order(p_order_id bigint,p_table_id bigint,p_waiter_id uuid,p_customer_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; customer_name text:=nullif(trim(p_customer_name),'');
begin
 if p_table_id is null and (customer_name is null or char_length(customer_name)>80) then raise exception 'Escribe el nombre de quien recoge (máximo 80 caracteres)';end if;
 result:=public.transfer_pos_order(p_order_id,p_table_id,p_waiter_id);
 if p_table_id is null then
  update public.orders set pickup_name=customer_name where id=p_order_id;
  result:=result||jsonb_build_object('pickup_name',customer_name);
 end if;
 return result;
end;$$;
revoke all on function public.transfer_pos_order(bigint,bigint,uuid) from public,anon,authenticated;
revoke all on function public.transfer_pos_order(bigint,bigint,uuid,text) from public,anon;
grant execute on function public.transfer_pos_order(bigint,bigint,uuid,text) to authenticated;
commit;
