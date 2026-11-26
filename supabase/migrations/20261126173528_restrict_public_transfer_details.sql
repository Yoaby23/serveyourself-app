begin;

-- The private projections define the catalog independently of profile RLS.
-- Their grants expose only the projected columns, never the source tables.
create view sy_private.restaurant_catalog as
select id, business_name, address, open_time, close_time, avatar_url, rating,
       latitude, longitude, timezone, accepting_orders, payment_cash,
       payment_transfer, payment_online,
       null::text as bank_name, null::text as bank_account_holder, null::text as bank_clabe,
       mercado_pago_connected, delivery_enabled, delivery_radius_km, delivery_base_fee,
       delivery_fee_per_km, delivery_free_over, delivery_minimum, delivery_prep_minutes,
       pickup_prep_minutes, dine_in_prep_minutes, business_hours, phone
from public.profiles
where role = 'negocio';

create view sy_private.qr_restaurant_catalog as
select id, business_name, address, open_time, close_time, avatar_url, rating, timezone,
       accepting_orders,
       guest_pickup_enabled and (payment_cash or (payment_online and mercado_pago_connected)) as guest_pickup_enabled,
       payment_cash, payment_online and mercado_pago_connected as payment_online,
       business_hours, phone
from public.profiles
where role = 'negocio';

create view sy_private.qr_product_catalog as
select id, restaurant_id, name, price, category, image_url, parent_product_id,
       variation_name, has_variations, is_available, is_archived
from public.products p
where is_available and not is_archived and (
    parent_product_id is null or exists (
        select 1 from public.products parent
        where parent.id = p.parent_product_id and parent.is_available
          and not parent.is_archived and parent.has_variations
    )
);

revoke all on all tables in schema sy_private from public, anon, authenticated;
grant select on sy_private.restaurant_catalog, sy_private.qr_restaurant_catalog, sy_private.qr_product_catalog
to anon, authenticated;

create or replace view public.public_restaurants with (security_invoker = true) as
select * from sy_private.restaurant_catalog;
create or replace view public.public_qr_restaurants with (security_invoker = true) as
select * from sy_private.qr_restaurant_catalog;
create or replace view public.public_qr_products with (security_invoker = true) as
select * from sy_private.qr_product_catalog;

commit;
