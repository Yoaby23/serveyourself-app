alter table public.profiles add column business_hours jsonb;
create function public.valid_business_hours(h jsonb) returns boolean language plpgsql immutable set search_path='' as $$
declare d jsonb;
begin
 if h is null then return true;end if;
 if jsonb_typeof(h)<>'array' or jsonb_array_length(h)<>7 then return false;end if;
 for d in select value from jsonb_array_elements(h) loop
  if jsonb_typeof(d)<>'object' or jsonb_typeof(d->'closed') is distinct from 'boolean' then return false;end if;
  if d ? 'allDay' and jsonb_typeof(d->'allDay') is distinct from 'boolean' then return false;end if;
  if not (d->>'closed')::boolean and not coalesce((d->>'allDay')::boolean,false) then
   if coalesce(d->>'open','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(d->>'close','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or d->>'open'=d->>'close' then return false;end if;
  end if;
 end loop;
 return true;
exception when others then return false;
end;$$;
alter table public.profiles add constraint valid_business_hours check(public.valid_business_hours(business_hours));
create function public.business_open_at(h jsonb,local_at timestamp) returns boolean language plpgsql immutable set search_path='' as $$
declare n integer:=extract(isodow from local_at)::integer-1;d jsonb:=h->n;previous jsonb:=h->((n+6)%7);t text:=to_char(local_at,'HH24:MI');
begin
 if h is null then return true;end if;
 if not (d->>'closed')::boolean then
  if coalesce((d->>'allDay')::boolean,false) then return true;end if;
  if d->>'open'<d->>'close' and t>=d->>'open' and t<d->>'close' then return true;end if;
  if d->>'open'>d->>'close' and t>=d->>'open' then return true;end if;
 end if;
 return not (previous->>'closed')::boolean and not coalesce((previous->>'allDay')::boolean,false)
  and previous->>'open'>previous->>'close' and t<previous->>'close';
end;$$;
create function public.check_business_order_hours() returns trigger language plpgsql security definer set search_path='' as $$
declare p public.profiles%rowtype;
begin
 select * into p from public.profiles where id=new.restaurant_id;
 if new.order_source<>'pos' and p.business_hours is not null and not public.business_open_at(p.business_hours,now() at time zone p.timezone) then
  raise exception 'El restaurante está cerrado en este horario';
 end if;
 if new.scheduled_for is not null and p.business_hours is not null and not public.business_open_at(p.business_hours,new.scheduled_for at time zone p.timezone) then
  raise exception 'La hora de recogida está fuera del horario del restaurante';
 end if;
 return new;
end;$$;
create trigger check_business_order_hours before insert or update of scheduled_for on public.orders for each row execute function public.check_business_order_hours();
revoke all on function public.check_business_order_hours() from public,anon,authenticated;
-- Compatibility: views keep existing columns in order and append public business settings.
do $$
declare v text;definition text;
begin
 foreach v in array array['public_restaurants','public_qr_restaurants'] loop
  definition:=pg_get_viewdef(('public.'||v)::regclass,true);
  definition:=replace(definition,'FROM profiles',', business_hours, phone FROM profiles');
  execute 'create or replace view public.'||v||' as '||definition;
 end loop;
end;$$;
revoke all on public.public_restaurants,public.public_qr_restaurants from public,anon,authenticated;
grant select on public.public_restaurants,public.public_qr_restaurants to anon,authenticated;

-- Notes are part of guest checkout's idempotency payload and survive into kitchen tickets.
do $$
declare definition text;
begin
 definition:=pg_get_functiondef('public.create_guest_pickup_order(text,text,uuid,jsonb,text,text)'::regprocedure);
 definition:=replace(definition,'p_payment_method text)','p_payment_method text, p_notes text)');
 definition:=replace(definition,' p_name:=btrim(p_name);',' if char_length(coalesce(p_notes,''''))>500 then raise exception ''Las notas admiten hasta 500 caracteres'';end if;'||chr(10)||' p_notes:=btrim(coalesce(p_notes,''''));'||chr(10)||' p_name:=btrim(p_name);');
 definition:=replace(definition,'''payment_method'',p_payment_method);','''payment_method'',p_payment_method,''notes'',p_notes);');
 definition:=replace(definition,'previous.payload||jsonb_build_object(', 'previous.payload||jsonb_build_object(''notes'',coalesce(previous.payload->>''notes'',''''),');
 definition:=replace(definition,'status,payment_before_kitchen)','status,payment_before_kitchen,notes)');
 definition:=replace(definition,'''pendiente'',true) returning','''pendiente'',true,p_notes) returning');
 execute definition;
end;$$;
revoke all on function public.create_guest_pickup_order(text,text,uuid,jsonb,text,text,text) from public,anon,authenticated;
grant execute on function public.create_guest_pickup_order(text,text,uuid,jsonb,text,text,text) to service_role;
create or replace function public.create_guest_pickup_order(p_token_hash text,p_client_hash text,p_restaurant_id uuid,p_items jsonb,p_name text,p_payment_method text)
returns jsonb language sql security invoker set search_path='' as $$
 select public.create_guest_pickup_order(p_token_hash,p_client_hash,p_restaurant_id,p_items,p_name,p_payment_method,'');
$$;
