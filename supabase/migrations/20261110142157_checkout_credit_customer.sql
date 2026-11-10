create function public.create_credit_customer_from_checkout(p_customer_id uuid,p_restaurant_id uuid,p_name text,p_phone text,p_credit_limit numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare customer public.loyalty_customers%rowtype;clean_name text:=btrim(coalesce(p_name,''));clean_phone text:=regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');
begin
 if auth.uid() is distinct from p_restaurant_id or not exists(select 1 from public.profiles where id=auth.uid() and role='negocio') then
  raise exception using errcode='42501',message='Se necesita autorización del propietario de este restaurante';
 end if;
 if p_customer_id is null or char_length(clean_name) not between 2 and 120 then raise exception 'Indica un nombre de 2 a 120 caracteres';end if;
 if char_length(clean_phone) not between 7 and 15 then raise exception 'Indica un teléfono válido';end if;
 if char_length(clean_phone)=10 then clean_phone:='52'||clean_phone;end if;
 if p_credit_limit is null or p_credit_limit<=0 or p_credit_limit>9999999999.99 or p_credit_limit::text in ('NaN','Infinity','-Infinity') then raise exception 'Indica un límite de crédito mayor a cero';end if;
 p_credit_limit:=round(p_credit_limit,2);
 if p_credit_limit<=0 then raise exception 'El límite mínimo es 0.01';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_restaurant_id::text||':credit-customer:'||clean_phone,0));
 select * into customer from public.loyalty_customers where id=p_customer_id;
 if found then
  if customer.restaurant_id<>p_restaurant_id or customer.customer_name<>clean_name or customer.phone<>clean_phone or customer.credit_limit is distinct from p_credit_limit or not customer.credit_enabled then raise exception 'La solicitud ya se utilizó. Revisa los clientes registrados';end if;
  return to_jsonb(customer);
 end if;
 if exists(select 1 from public.loyalty_customers c where c.restaurant_id=p_restaurant_id and
  (case when char_length(regexp_replace(c.phone,'[^0-9]','','g'))=10 then '52'||regexp_replace(c.phone,'[^0-9]','','g') else regexp_replace(c.phone,'[^0-9]','','g') end)=clean_phone) then
  raise exception 'Ya hay un cliente con este teléfono. Selecciónalo en la lista de clientes';
 end if;
 insert into public.loyalty_customers(id,restaurant_id,customer_name,phone) values(p_customer_id,p_restaurant_id,clean_name,clean_phone);
 return public.set_customer_credit_settings(p_restaurant_id,p_customer_id,true,p_credit_limit);
end;$$;
revoke all on function public.create_credit_customer_from_checkout(uuid,uuid,text,text,numeric) from public,anon;
grant execute on function public.create_credit_customer_from_checkout(uuid,uuid,text,text,numeric) to authenticated;
