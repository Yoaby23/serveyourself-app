-- A variation has its own sellable product ID. Existing order/ticket snapshots are retained.
alter table public.products
 add column parent_product_id uuid references public.products(id) on delete restrict,
 add column variation_name text,
 add column has_variations boolean not null default false,
 add column is_archived boolean not null default false,
 add constraint product_variation_shape check ((parent_product_id is null and variation_name is null) or (parent_product_id is not null and char_length(trim(variation_name)) between 1 and 80 and not has_variations and parent_product_id<>id));
create index products_parent_product_idx on public.products(parent_product_id) where parent_product_id is not null;
create unique index products_variation_name_unique on public.products(parent_product_id,lower(trim(variation_name))) where parent_product_id is not null and not is_archived;

create function public.normalize_product_variation() returns trigger language plpgsql security definer set search_path='' as $$
declare parent public.products%rowtype;
begin
 if new.parent_product_id is not null then
  select * into parent from public.products where id=new.parent_product_id for share;
  if not found or parent.parent_product_id is not null or parent.restaurant_id<>new.restaurant_id then raise exception 'La variación debe pertenecer a un producto del mismo negocio';end if;
  if tg_op='UPDATE' and (old.parent_product_id is distinct from new.parent_product_id or old.restaurant_id<>new.restaurant_id) then raise exception 'No se puede mover una variación a otro producto';end if;
  new.variation_name:=regexp_replace(trim(new.variation_name),'\s+',' ','g');new.name:=parent.name||' · '||new.variation_name;
  new.category:=parent.category;new.kitchen_station_id:=parent.kitchen_station_id;new.image_url:=parent.image_url;new.has_variations:=false;
 end if;
 return new;
end;$$;
revoke all on function public.normalize_product_variation() from public,anon,authenticated;
create trigger normalize_product_variation before insert or update on public.products for each row execute function public.normalize_product_variation();

create function public.sync_product_variations() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.parent_product_id is null and (new.name is distinct from old.name or new.category is distinct from old.category or new.kitchen_station_id is distinct from old.kitchen_station_id or new.image_url is distinct from old.image_url or new.is_archived is distinct from old.is_archived) then
  update public.products set name=new.name||' · '||variation_name,category=new.category,kitchen_station_id=new.kitchen_station_id,image_url=new.image_url,is_archived=case when new.is_archived then true else is_archived end where parent_product_id=new.id;
 end if;return new;
end;$$;
revoke all on function public.sync_product_variations() from public,anon,authenticated;
create trigger sync_product_variations after update on public.products for each row execute function public.sync_product_variations();

create function public.product_is_sellable(p_product_id uuid) returns boolean language sql stable security invoker set search_path='' as $$
 select exists(select 1 from public.products p where p.id=p_product_id and p.is_available and not p.is_archived and not p.has_variations and (p.parent_product_id is null or exists(select 1 from public.products parent where parent.id=p.parent_product_id and parent.is_available and not parent.is_archived and parent.has_variations)));
$$;
revoke all on function public.product_is_sellable(uuid) from public,anon;
grant execute on function public.product_is_sellable(uuid) to authenticated;

create function public.save_menu_product(p_product_id uuid,p_product jsonb,p_variations jsonb default '[]') returns jsonb language plpgsql security definer set search_path='' as $$
declare current public.products%rowtype;v jsonb;v_id uuid;v_price numeric;label text;labels text[]:='{}';ids uuid[]:='{}';base numeric;parent_name text;
begin
 if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='negocio') then raise exception 'Solo el propietario puede editar productos';end if;
 if p_product_id is null or p_product is null or jsonb_typeof(p_product)<>'object' or p_variations is null or jsonb_typeof(p_variations)<>'array' then raise exception 'Producto inválido';end if;
 if jsonb_array_length(p_variations)>50 then raise exception 'Máximo 50 variaciones por producto';end if;
 parent_name:=trim(p_product->>'name');
 if parent_name is null or char_length(parent_name) not between 1 and 120 then raise exception 'Escribe el nombre del producto';end if;
 if p_product->>'category' is null or char_length(trim(p_product->>'category')) not between 1 and 80 or not exists(select 1 from public.menu_categories where restaurant_id=auth.uid() and name=trim(p_product->>'category')) then raise exception 'Selecciona una categoría del menú';end if;
 if nullif(p_product->>'kitchen_station_id','') is not null and not exists(select 1 from public.kitchen_stations where id=(p_product->>'kitchen_station_id')::bigint and restaurant_id=auth.uid() and is_active) then raise exception 'Selecciona una estación del negocio';end if;
 select * into current from public.products where id=p_product_id for update;
 if found and (current.restaurant_id<>auth.uid() or current.parent_product_id is not null or current.is_archived) then raise exception 'Producto no disponible para editar';end if;
 for v in select value from jsonb_array_elements(p_variations) loop
  label:=regexp_replace(trim(v->>'name'),'\s+',' ','g');v_price:=round((v->>'price')::numeric,2);v_id:=(v->>'id')::uuid;
  if label is null or char_length(label) not between 1 and 80 or lower(label)=any(labels) or v_id is null or v_id=any(ids) or v_id=p_product_id or v_price is null or v_price::text in ('NaN','Infinity','-Infinity') or v_price<=0 or v_price>999999 then raise exception 'Cada variación requiere un nombre único y precio válido';end if;
  if exists(select 1 from public.products where id=v_id and (parent_product_id is distinct from p_product_id or restaurant_id<>auth.uid())) then raise exception 'La variación pertenece a otro producto';end if;
  labels:=array_append(labels,lower(label));ids:=array_append(ids,v_id);base:=least(base,v_price);
 end loop;
 if jsonb_array_length(p_variations)=0 then base:=round((p_product->>'price')::numeric,2);end if;
 if base is null or base::text in ('NaN','Infinity','-Infinity') or base<=0 or base>999999 then raise exception 'Indica un precio válido';end if;
 insert into public.products(id,restaurant_id,name,price,category,kitchen_station_id,image_url,is_available,has_variations)
 values(p_product_id,auth.uid(),parent_name,base,nullif(trim(p_product->>'category'),''),nullif(p_product->>'kitchen_station_id','')::bigint,nullif(p_product->>'image_url',''),true,jsonb_array_length(p_variations)>0)
 on conflict(id) do update set name=excluded.name,price=excluded.price,category=excluded.category,kitchen_station_id=excluded.kitchen_station_id,image_url=case when p_product ? 'image_url' then excluded.image_url else public.products.image_url end,has_variations=excluded.has_variations where public.products.restaurant_id=auth.uid() and public.products.parent_product_id is null;
 if not found then raise exception 'Producto no disponible';end if;
 -- Retire removed options without deleting IDs needed by pending orders or kitchen.
 update public.products set is_archived=true,is_available=false where parent_product_id=p_product_id;
 for v in select value from jsonb_array_elements(p_variations) loop
  insert into public.products(id,restaurant_id,parent_product_id,variation_name,name,price,is_available,is_archived)
  values((v->>'id')::uuid,auth.uid(),p_product_id,v->>'name',parent_name,round((v->>'price')::numeric,2),coalesce((v->>'is_available')::boolean,true),false)
  on conflict(id) do update set variation_name=excluded.variation_name,price=excluded.price,is_available=excluded.is_available,is_archived=false where public.products.restaurant_id=auth.uid() and public.products.parent_product_id=p_product_id;
  if not found then raise exception 'Variación no disponible';end if;
 end loop;
 return jsonb_build_object('id',p_product_id,'variation_count',jsonb_array_length(p_variations));
end;$$;
revoke all on function public.save_menu_product(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.save_menu_product(uuid,jsonb,jsonb) to authenticated;

create function public.archive_menu_product(p_product_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Inicia sesión';end if;
 update public.products set is_archived=true,is_available=false where id=p_product_id and restaurant_id=auth.uid() and parent_product_id is null;
 if not found then raise exception 'Producto no disponible';end if;
end;$$;
revoke all on function public.archive_menu_product(uuid) from public,anon;
grant execute on function public.archive_menu_product(uuid) to authenticated;

-- Keep the curated public QR catalog; no private business/payment fields are added.
create or replace view public.public_qr_products as
 select p.id,p.restaurant_id,p.name,p.price,p.category,p.image_url,p.parent_product_id,p.variation_name,p.has_variations,p.is_available,p.is_archived
 from public.products p where p.is_available and not p.is_archived and (p.parent_product_id is null or exists(select 1 from public.products parent where parent.id=p.parent_product_id and parent.is_available and not parent.is_archived and parent.has_variations));
CREATE OR REPLACE FUNCTION public.create_order_v2(p_restaurant_id uuid, p_items jsonb, p_notes text DEFAULT NULL::text, p_payment_method text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_customer_id uuid := auth.uid();
    restaurant_record public.profiles%rowtype;
    item jsonb;
    product_record public.products%rowtype;
    quantity integer;
    normalized_items jsonb := '[]'::jsonb;
    calculated_total numeric := 0;
    created_order public.orders%rowtype;
    local_time time;
    restaurant_is_open boolean := true;
begin
    if v_customer_id is null then
        raise exception 'Debes iniciar sesión para crear un pedido';
    end if;

    select * into restaurant_record
    from public.profiles
    where id = p_restaurant_id and role = 'negocio';

    if not found then raise exception 'El restaurante no existe'; end if;
    if not restaurant_record.accepting_orders then
        raise exception 'El restaurante no está aceptando pedidos';
    end if;

    if restaurant_record.open_time is not null and restaurant_record.close_time is not null then
        local_time := (now() at time zone restaurant_record.timezone)::time;
        restaurant_is_open := case
            when restaurant_record.open_time <= restaurant_record.close_time
                then local_time between restaurant_record.open_time and restaurant_record.close_time
            else local_time >= restaurant_record.open_time or local_time <= restaurant_record.close_time
        end;
    end if;
    if not restaurant_is_open then raise exception 'El restaurante está cerrado'; end if;

    if p_payment_method not in ('cash', 'transfer', 'mercado_pago') then
        raise exception 'Método de pago inválido';
    end if;
    if p_payment_method = 'cash' and not restaurant_record.payment_cash then
        raise exception 'El restaurante no acepta efectivo';
    end if;
    if p_payment_method = 'transfer' and not restaurant_record.payment_transfer then
        raise exception 'El restaurante no acepta transferencia';
    end if;
    if p_payment_method = 'mercado_pago' and not restaurant_record.payment_online then
        raise exception 'El restaurante no acepta pago en línea';
    end if;

    if jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) < 1
       or jsonb_array_length(p_items) > 50 then
        raise exception 'El pedido debe contener entre 1 y 50 productos';
    end if;

    for item in select value from jsonb_array_elements(p_items)
    loop
        if coalesce(item ->> 'qty', '') !~ '^[0-9]+$' then raise exception 'Cantidad inválida'; end if;
        quantity := (item ->> 'qty')::integer;
        if quantity < 1 or quantity > 50 then raise exception 'Cada cantidad debe estar entre 1 y 50'; end if;

        select * into product_record
        from public.products
        where id::text = item ->> 'id'
          and restaurant_id = p_restaurant_id
          and is_available = true and public.product_is_sellable(id);
        if not found then raise exception 'Uno de los productos no existe o está agotado'; end if;

        normalized_items := normalized_items || jsonb_build_array(jsonb_build_object(
            'id', product_record.id,
            'nombre', product_record.name,
            'price', product_record.price,
            'qty', quantity
        ));
        calculated_total := calculated_total + (product_record.price * quantity);
    end loop;

    insert into public.orders (
        customer_id, restaurant_id, restaurant_name, items, total, notes,
        status, payment_method, payment_status
    ) values (
        v_customer_id, p_restaurant_id, restaurant_record.business_name,
        normalized_items, round(calculated_total, 2),
        nullif(left(trim(coalesce(p_notes, '')), 500), ''),
        'pendiente', p_payment_method,
        case when p_payment_method = 'mercado_pago' then 'pending' else 'not_required' end
    ) returning * into created_order;

    return to_jsonb(created_order);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_pos_order(p_restaurant_id uuid, p_items jsonb, p_notes text DEFAULT NULL::text, p_service_type text DEFAULT 'pickup'::text, p_table_id bigint DEFAULT NULL::bigint, p_payment_method text DEFAULT 'cash'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
    v_user_id uuid := auth.uid();
    v_restaurant public.profiles%rowtype;
    v_creator public.profiles%rowtype;
    v_item jsonb;
    v_product public.products%rowtype;
    v_quantity integer;
    v_items jsonb := '[]'::jsonb;
    v_total numeric := 0;
    v_order public.orders%rowtype;
begin
    if not (public.has_restaurant_permission(p_restaurant_id,'create_orders') or (coalesce(p_service_type='pickup',false) and public.has_restaurant_permission(p_restaurant_id,'close_accounts'))) then
        raise exception 'No tienes permiso para crear comandas';
    end if;
    if p_service_type not in ('pickup', 'dine_in') then raise exception 'Tipo de servicio invalido'; end if;
    if p_payment_method not in ('cash', 'transfer', 'card_terminal') then raise exception 'Metodo de pago invalido'; end if;
    if p_service_type = 'dine_in' then
        if p_table_id is null or not exists (
            select 1 from public.restaurant_tables where id = p_table_id and restaurant_id = p_restaurant_id and is_active
        ) then raise exception 'Selecciona una mesa activa'; end if;
    else p_table_id := null;
    end if;
    if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 50 then
        raise exception 'El pedido debe contener entre 1 y 50 productos';
    end if;
    select * into v_restaurant from public.profiles where id = p_restaurant_id and role = 'negocio';
    select * into v_creator from public.profiles where id = v_user_id;
    for v_item in select value from jsonb_array_elements(p_items) loop
        if coalesce(v_item ->> 'qty', '') !~ '^[0-9]+$' then raise exception 'Cantidad invalida'; end if;
        v_quantity := (v_item ->> 'qty')::integer;
        if v_quantity < 1 or v_quantity > 50 then raise exception 'Cantidad invalida'; end if;
        select * into v_product from public.products
        where id::text = v_item ->> 'id' and restaurant_id = p_restaurant_id and is_available and public.product_is_sellable(id);
        if not found then raise exception 'Un producto ya no esta disponible'; end if;
        v_items := v_items || jsonb_build_array(jsonb_build_object(
            'id', v_product.id, 'nombre', v_product.name, 'price', v_product.price, 'qty', v_quantity
        ));
        v_total := v_total + v_product.price * v_quantity;
    end loop;
    insert into public.orders (
        customer_id, restaurant_id, restaurant_name, items, total, notes, status,
        payment_method, payment_status, order_source, service_type, table_id, created_by, waiter_name
    ) values (
        null, p_restaurant_id, v_restaurant.business_name, v_items, round(v_total, 2),
        nullif(left(trim(coalesce(p_notes, '')), 500), ''), 'pendiente', p_payment_method,
        'pending', 'pos', p_service_type, p_table_id, v_user_id, v_creator.full_name
    ) returning * into v_order;
    return to_jsonb(v_order);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.append_pos_order_items(p_order_id bigint, p_items jsonb, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.orders%rowtype; v_item jsonb; v_product public.products%rowtype; v_qty integer; v_added jsonb:='[]'::jsonb; v_total numeric:=0; v_ticket_id bigint;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found or v_order.order_source<>'pos' or v_order.payment_status='approved' or v_order.status='cancelado' then raise exception 'La cuenta no esta abierta'; end if;
    if not public.has_restaurant_permission(v_order.restaurant_id,'create_orders') then raise exception 'Sin permiso para agregar productos'; end if;
    if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 then raise exception 'Agrega productos'; end if;
    for v_item in select value from jsonb_array_elements(p_items) loop
        v_qty:=(v_item->>'qty')::integer;
        select * into v_product from public.products where id::text=v_item->>'id' and restaurant_id=v_order.restaurant_id and is_available and public.product_is_sellable(id);
        if not found or v_qty<1 or v_qty>50 then raise exception 'Producto o cantidad invalida'; end if;
        v_added:=v_added||jsonb_build_array(jsonb_build_object('id',v_product.id,'nombre',v_product.name,'price',v_product.price,'qty',v_qty,'station_id',v_product.kitchen_station_id));
        v_total:=v_total+v_product.price*v_qty;
    end loop;
    update public.orders set items=items||v_added,total=total+v_total,
      notes=coalesce(nullif(left(trim(coalesce(p_notes,'')),500),''),notes),payment_status='pending'
    where id=p_order_id returning * into v_order;
    v_ticket_id:=public.create_kitchen_ticket(p_order_id,v_added,p_notes);
    perform public.refresh_order_kitchen_status(p_order_id);
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    values(p_order_id,v_order.restaurant_id,'items_added',jsonb_build_object('items',v_added,'amount',v_total,'kitchen_ticket_id',v_ticket_id),auth.uid());
    return to_jsonb(v_order)||jsonb_build_object('kitchen_ticket_id',v_ticket_id);
end; $function$
;

CREATE OR REPLACE FUNCTION public.create_delivery_order(p_restaurant_id uuid, p_items jsonb, p_notes text, p_payment_method text, p_address text, p_reference text, p_latitude double precision, p_longitude double precision, p_contact_name text, p_contact_phone text, p_scheduled_for timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.profiles%rowtype;i jsonb;p public.products%rowtype;q integer;items jsonb:='[]';sub numeric:=0;quote jsonb;o public.orders%rowtype;local_time time;is_open boolean:=true;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesion';end if;
 if p_payment_method not in('cash','mercado_pago') then raise exception 'Delivery solo acepta efectivo o Mercado Pago';end if;
 select * into r from public.profiles where id=p_restaurant_id and role='negocio';if not found or not r.delivery_enabled or not r.accepting_orders then raise exception 'Delivery no disponible';end if;
 if p_payment_method='cash' and not r.payment_cash then raise exception 'El restaurante no acepta efectivo';end if;
 if p_payment_method='mercado_pago' and (not r.payment_online or not r.mercado_pago_connected) then raise exception 'Mercado Pago no esta disponible';end if;
 if r.open_time is not null and r.close_time is not null then local_time:=(now() at time zone r.timezone)::time;is_open:=case when r.open_time<=r.close_time then local_time between r.open_time and r.close_time else local_time>=r.open_time or local_time<=r.close_time end;end if;
 if not is_open then raise exception 'El restaurante esta cerrado';end if;
 if char_length(trim(coalesce(p_address,'')))<5 or char_length(trim(coalesce(p_contact_name,'')))<2 or char_length(trim(coalesce(p_contact_phone,'')))<7 then raise exception 'Completa direccion, nombre y telefono';end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>50 then raise exception 'Pedido invalido';end if;
 for i in select value from jsonb_array_elements(p_items) loop
  q:=coalesce((i->>'qty')::integer,0);select * into p from public.products where id::text=i->>'id' and restaurant_id=p_restaurant_id and is_available and public.product_is_sellable(id);
  if not found or q<1 or q>50 then raise exception 'Producto o cantidad invalida';end if;
  items:=items||jsonb_build_array(jsonb_build_object('id',p.id,'nombre',p.name,'price',p.price,'qty',q,'station_id',p.kitchen_station_id));sub:=sub+p.price*q;
 end loop;
 quote:=public.calculate_delivery_quote(p_restaurant_id,p_latitude,p_longitude,sub);
 insert into public.orders(customer_id,restaurant_id,restaurant_name,items,subtotal,delivery_fee,total,notes,status,payment_method,payment_status,service_type,order_source,delivery_distance_km,delivery_address,delivery_reference,delivery_latitude,delivery_longitude,delivery_contact_name,delivery_contact_phone,scheduled_for,delivery_status,delivery_code)
 values(auth.uid(),p_restaurant_id,r.business_name,items,sub,(quote->>'delivery_fee')::numeric,(quote->>'total')::numeric,nullif(left(trim(coalesce(p_notes,'')),500),''),'pendiente',p_payment_method,case when p_payment_method='mercado_pago' then 'pending' else 'not_required' end,'delivery','online',(quote->>'distance_km')::numeric,left(trim(p_address),300),nullif(left(trim(coalesce(p_reference,'')),300),''),p_latitude,p_longitude,left(trim(p_contact_name),120),left(trim(p_contact_phone),30),p_scheduled_for,'pending_acceptance',lpad(floor(random()*10000)::integer::text,4,'0')) returning * into o;
 insert into public.delivery_events(order_id,restaurant_id,status,message,actor_id) values(o.id,o.restaurant_id,'pending_acceptance','Pedido delivery recibido',auth.uid());return to_jsonb(o)||jsonb_build_object('eta_minutes',quote->'eta_minutes');
end; $function$
;

CREATE OR REPLACE FUNCTION public.create_guest_pickup_order(p_token_hash text, p_client_hash text, p_restaurant_id uuid, p_items jsonb, p_name text, p_payment_method text, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare r public.profiles%rowtype; previous public.guest_checkout_requests%rowtype;
 p public.products%rowtype; item jsonb; qty integer; total numeric:=0;
 normalized jsonb:='[]'; payload jsonb; result public.orders%rowtype; local_time time;
begin
 if p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' or p_client_hash is null or p_client_hash !~ '^[a-f0-9]{64}$' then raise exception 'Solicitud inválida';end if;
 if p_payment_method is null or p_payment_method not in ('cash','mercado_pago') then raise exception 'Método de pago inválido';end if;
 if char_length(coalesce(p_notes,''))>500 then raise exception 'Las notas admiten hasta 500 caracteres';end if;
 p_notes:=btrim(coalesce(p_notes,''));
 p_name:=btrim(p_name);
 if p_name is null or char_length(p_name) not between 1 and 80 then raise exception 'Indica un nombre de 1 a 80 caracteres';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Carrito inválido';end if;
 if jsonb_array_length(p_items) not between 1 and 50 then raise exception 'Elige entre 1 y 50 productos';end if;
 payload:=jsonb_build_object('restaurant_id',p_restaurant_id,'items',p_items,'name',p_name,'payment_method',p_payment_method,'notes',p_notes);
 perform pg_advisory_xact_lock(hashtextextended('guest-token:'||p_token_hash,0));
 select * into previous from public.guest_checkout_requests where token_hash=p_token_hash;
 if found then
  if previous.created_at<now()-interval '7 days' then raise exception 'El acceso al pedido venció';end if;
  if (previous.payload||jsonb_build_object('notes',coalesce(previous.payload->>'notes',''),'payment_method',coalesce(previous.payload->>'payment_method','mercado_pago')))<>payload then raise exception 'La solicitud ya pertenece a otro carrito';end if;
  select * into result from public.orders where id=previous.order_id;
  return to_jsonb(result);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('guest-client:'||p_client_hash,0));
 if (select count(*) from public.guest_checkout_requests where client_hash=p_client_hash and created_at>now()-interval '20 minutes')>=10 then raise exception 'Demasiados intentos. Espera antes de crear otro pedido';end if;
 select * into r from public.profiles where id=p_restaurant_id and role='negocio' for update;
 if not found or not r.guest_pickup_enabled then raise exception 'Este restaurante no admite pedidos sin cuenta';end if;
 if p_payment_method='cash' and not r.payment_cash then raise exception 'El restaurante no acepta efectivo';end if;
 if p_payment_method='mercado_pago' and (not r.payment_online or not r.mercado_pago_connected) then raise exception 'El restaurante no admite pago en línea';end if;
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
  select * into p from public.products where id::text=item->>'id' and restaurant_id=p_restaurant_id and is_available and public.product_is_sellable(id) for share;
  if not found or p.price<=0 then raise exception 'Un producto no está disponible';end if;
  total:=total+p.price*qty;
  normalized:=normalized||jsonb_build_array(jsonb_build_object('id',p.id,'nombre',p.name,'price',p.price,'qty',qty));
 end loop;
 insert into public.orders(restaurant_id,restaurant_name,items,total,subtotal,pickup_name,order_source,service_type,payment_method,payment_status,status,payment_before_kitchen,notes)
 values(r.id,r.business_name,normalized,round(total,2),round(total,2),p_name,'online','pickup',p_payment_method,'pending','pendiente',true,p_notes) returning * into result;
 insert into public.guest_checkout_requests(token_hash,restaurant_id,client_hash,payload,order_id) values(p_token_hash,p_restaurant_id,p_client_hash,payload,result.id);
 return to_jsonb(result);
end;$function$
;
CREATE OR REPLACE FUNCTION public.create_kitchen_ticket(p_order_id bigint, p_items jsonb, p_notes text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_order public.orders%rowtype; v_item jsonb; v_product public.products%rowtype; v_qty integer; v_items jsonb:='[]'::jsonb; v_ticket_id bigint;
begin
    select * into v_order from public.orders where id=p_order_id for update;
    if not found then raise exception 'Cuenta no encontrada'; end if;
    if not (public.has_restaurant_permission(v_order.restaurant_id,'create_orders') or (v_order.service_type='pickup' and v_order.order_source='pos' and public.has_restaurant_permission(v_order.restaurant_id,'close_accounts'))) then raise exception 'Sin permiso para crear comandas'; end if;
    if v_order.service_type='pickup' and v_order.scheduled_for is null and v_order.payment_status not in ('approved','on_credit') then return null;end if;
    if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 then raise exception 'Agrega productos'; end if;
    for v_item in select value from jsonb_array_elements(p_items) loop
        v_qty:=coalesce((v_item->>'qty')::integer,0);
        select * into v_product from public.products where id::text=v_item->>'id' and restaurant_id=v_order.restaurant_id;
        if not found or v_qty<1 or v_qty>50 then raise exception 'Producto o cantidad invalida'; end if;
        v_items:=v_items||jsonb_build_array(jsonb_build_object('id',v_product.id,'nombre',coalesce(v_item->>'nombre',v_product.name),'price',coalesce((v_item->>'price')::numeric,v_product.price),'qty',v_qty,'station_id',v_product.kitchen_station_id));
    end loop;
    insert into public.kitchen_tickets(order_id,restaurant_id,items,notes,service_type,table_id,created_by,waiter_name)
    values(v_order.id,v_order.restaurant_id,v_items,nullif(left(trim(coalesce(p_notes,'')),500),''),v_order.service_type,v_order.table_id,v_order.created_by,v_order.waiter_name)
    returning id into v_ticket_id;
    insert into public.kitchen_ticket_station_statuses(ticket_id,restaurant_id,station_key,kitchen_station_id)
    select distinct v_ticket_id,v_order.restaurant_id,coalesce(p.kitchen_station_id::text,'general'),p.kitchen_station_id
    from jsonb_array_elements(v_items) i join public.products p on p.id::text=i->>'id'
    on conflict(ticket_id,station_key) do nothing;
    return v_ticket_id;
end; $function$;
