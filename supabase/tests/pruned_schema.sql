do $$
declare signature text;
begin
 assert to_regclass('public.delivery_driver_status') is null;
 assert to_regclass('public.delivery_offer_responses') is null;
 foreach signature in array array['sync_order_station_statuses()','update_kitchen_order_status(bigint,text)','update_kitchen_station_status(bigint,text,text)','create_order(uuid,jsonb,text)','mark_pos_order_paid(bigint,text)','publish_delivery_marketplace_event()','team_drivers_for_push(uuid)'] loop
  assert to_regprocedure('public.'||signature) is null,'Retired function remains: '||signature;
 end loop;
 assert not exists(select from pg_trigger where tgrelid='public.orders'::regclass and tgname='sync_order_station_statuses');
 assert not exists(select from pg_attribute where attrelid='public.products'::regclass and attname='inventory_available' and not attisdropped);
 foreach signature in array array['record_cash_operation_once(uuid,text,jsonb)','assign_delivery_driver(bigint,uuid)','create_customer_order_once(uuid,jsonb)','submit_pos_order_once(uuid,jsonb)','calculate_driver_earning(numeric)','list_kitchen_priority_queue(uuid)','set_driver_availability(boolean,double precision,double precision)','list_delivery_offers()','claim_delivery_order(bigint)'] loop
  assert to_regprocedure('public.'||signature) is not null,'Operational or compatibility function missing: '||signature;
 end loop;
 assert exists(select from cron.job where jobname='expire-unpaid-orders' and active);
 assert exists(select from cron.job where jobname='retry-order-notifications' and active);
 assert to_regclass('public.order_station_statuses') is not null;
 assert to_regclass('public.delivery_marketplace_events') is not null;
 assert to_regclass('public.payment_refund_operations') is not null;
 assert to_regclass('public.kitchen_ml_models') is not null;
end;$$;
