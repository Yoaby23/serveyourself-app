alter table public.profiles add column guest_pickup_enabled boolean not null default false;
grant update(guest_pickup_enabled) on public.profiles to authenticated;
create or replace view public.public_qr_restaurants as
select id,business_name,address,open_time,close_time,avatar_url,rating,timezone,accepting_orders,
 (guest_pickup_enabled and payment_online and mercado_pago_connected) as guest_pickup_enabled
from public.profiles where role='negocio';
-- CREATE OR REPLACE preserves the read-only grants installed by the security review.
revoke all on public.public_qr_restaurants from public,anon,authenticated;
grant select on public.public_qr_restaurants to anon,authenticated;

create table public.guest_checkout_requests(
 token_hash text primary key check(token_hash ~ '^[a-f0-9]{64}$'),
 restaurant_id uuid not null references public.profiles(id),
 client_hash text not null,
 payload jsonb not null,
 order_id bigint not null unique references public.orders(id),
 created_at timestamptz not null default now()
);
create index guest_checkout_rate_idx on public.guest_checkout_requests(client_hash,created_at);
create index guest_checkout_restaurant_idx on public.guest_checkout_requests(restaurant_id,created_at);
alter table public.guest_checkout_requests enable row level security;
revoke all on public.guest_checkout_requests from public,anon,authenticated;
grant all on public.guest_checkout_requests to service_role;

-- Only the trusted Edge Function may invoke this. The public never supplies prices,
-- payment state, source, customer identity or service type to an orders INSERT.
create function public.create_guest_pickup_order(p_token_hash text,p_client_hash text,p_restaurant_id uuid,p_items jsonb,p_name text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r public.profiles%rowtype; previous public.guest_checkout_requests%rowtype;
 p public.products%rowtype; item jsonb; qty integer; total numeric:=0;
 normalized jsonb:='[]'; payload jsonb; result public.orders%rowtype; local_time time;
begin
 if p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' or p_client_hash is null or p_client_hash !~ '^[a-f0-9]{64}$' then raise exception 'Solicitud inválida';end if;
 p_name:=btrim(p_name);
 if p_name is null or char_length(p_name) not between 1 and 80 then raise exception 'Indica un nombre de 1 a 80 caracteres';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Carrito inválido';end if;
 if jsonb_array_length(p_items) not between 1 and 50 then raise exception 'Elige entre 1 y 50 productos';end if;
 payload:=jsonb_build_object('restaurant_id',p_restaurant_id,'items',p_items,'name',p_name);
 perform pg_advisory_xact_lock(hashtextextended('guest-token:'||p_token_hash,0));
 select * into previous from public.guest_checkout_requests where token_hash=p_token_hash;
 if found then
  if previous.created_at<now()-interval '7 days' then raise exception 'El acceso al pedido venció';end if;
  if previous.payload<>payload then raise exception 'La solicitud ya pertenece a otro carrito';end if;
  select * into result from public.orders where id=previous.order_id;
  return to_jsonb(result);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('guest-client:'||p_client_hash,0));
 if (select count(*) from public.guest_checkout_requests where client_hash=p_client_hash and created_at>now()-interval '20 minutes')>=10 then raise exception 'Demasiados intentos. Espera antes de crear otro pedido';end if;
 select * into r from public.profiles where id=p_restaurant_id and role='negocio' for update;
 if not found or not r.guest_pickup_enabled or not r.payment_online or not r.mercado_pago_connected then raise exception 'Este restaurante no admite pedidos sin cuenta';end if;
 if not r.accepting_orders then raise exception 'El restaurante no está aceptando pedidos';end if;
 local_time:=(now() at time zone r.timezone)::time;
 if r.open_time is not null and r.close_time is not null and not
 (case when r.open_time<=r.close_time then local_time between r.open_time and r.close_time else local_time>=r.open_time or local_time<=r.close_time end) then raise exception 'El restaurante está cerrado';end if;
 if (select count(*) from public.guest_checkout_requests g join public.orders o on o.id=g.order_id where g.restaurant_id=p_restaurant_id and g.created_at>now()-interval '20 minutes' and o.payment_status='pending')>=100 then raise exception 'Hay muchos pagos pendientes. Intenta más tarde';end if;
 if (select count(distinct value->>'id') from jsonb_array_elements(p_items))<>jsonb_array_length(p_items) then raise exception 'Productos duplicados o inválidos';end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if coalesce(item->>'qty','') !~ '^[0-9]{1,2}$' then raise exception 'Cantidad inválida';end if;
  qty:=(item->>'qty')::integer;
  if qty not between 1 and 50 then raise exception 'Cantidad inválida';end if;
  select * into p from public.products where id::text=item->>'id' and restaurant_id=p_restaurant_id and is_available for share;
  if not found or p.price<=0 then raise exception 'Un producto no está disponible';end if;
  total:=total+p.price*qty;
  normalized:=normalized||jsonb_build_array(jsonb_build_object('id',p.id,'nombre',p.name,'price',p.price,'qty',qty));
 end loop;
 insert into public.orders(restaurant_id,restaurant_name,items,total,subtotal,pickup_name,order_source,service_type,payment_method,payment_status,status)
 values(r.id,r.business_name,normalized,round(total,2),round(total,2),p_name,'online','pickup','mercado_pago','pending','pendiente') returning * into result;
 insert into public.guest_checkout_requests(token_hash,restaurant_id,client_hash,payload,order_id) values(p_token_hash,p_restaurant_id,p_client_hash,payload,result.id);
 return to_jsonb(result);
end;$$;
revoke all on function public.create_guest_pickup_order(text,text,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.create_guest_pickup_order(text,text,uuid,jsonb,text) to service_role;
