create extension if not exists pg_net;
create extension if not exists pg_cron;
revoke usage on schema net from public, anon, authenticated;

-- An event ID is a random, single-purpose delivery capability. Only the worker
-- and the database can read it; the browser never supplies recipients or text.
create table public.order_notification_events (
 id uuid primary key default gen_random_uuid(),
 order_id bigint not null, ticket_id bigint, kind text not null, state text not null,
 created_at timestamptz not null default now(), next_attempt timestamptz not null default now(),
 attempts int not null default 0, completed_at timestamptz
);
alter table public.order_notification_events enable row level security;
revoke all on public.order_notification_events from public,anon,authenticated;
grant select,update on public.order_notification_events to service_role;
create unique index order_notification_event_identity on public.order_notification_events(order_id,coalesce(ticket_id,0),kind,state);
create index order_notification_event_pending on public.order_notification_events(next_attempt) where completed_at is null and attempts<8;

create function public.dispatch_order_notification(event_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform net.http_post(url:='https://spbgledcjwtqmlqdlpyx.supabase.co/functions/v1/send-order-notification',body:=jsonb_build_object('dispatchId',event_id),timeout_milliseconds:=15000);
exception when others then
 -- The scheduled retry can recover a network queue failure without disrupting checkout.
 raise warning 'Order notification dispatch deferred';
end;$$;
revoke all on function public.dispatch_order_notification(uuid) from public,anon,authenticated;

create function public.enqueue_order_notification(oid bigint,tid bigint,event_kind text,event_state text) returns void language plpgsql security definer set search_path='' as $$
declare queued uuid;
begin
 insert into public.order_notification_events(order_id,ticket_id,kind,state,next_attempt) values(oid,tid,event_kind,event_state,now()+interval '1 minute') on conflict do nothing returning id into queued;
 if queued is not null then perform public.dispatch_order_notification(queued);end if;
end;$$;
revoke all on function public.enqueue_order_notification(bigint,bigint,text,text) from public,anon,authenticated;

create function public.notify_order_transition() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' and new.service_type='pickup' and new.payment_before_kitchen and new.payment_status='pending' and new.payment_method in ('cash','transfer') then
  perform public.enqueue_order_notification(new.id,null,'cashier','pending');
 end if;
 if tg_op='UPDATE' and new.payment_status is distinct from old.payment_status and new.payment_status in ('approved','refunded','rejected','expired') and new.customer_id is not null then
  perform public.enqueue_order_notification(new.id,null,'payment',new.payment_status);
 end if;
 if new.status='cancelado' and (tg_op='INSERT' or new.status is distinct from old.status) then
  perform public.enqueue_order_notification(new.id,null,'order','cancelado');
 elsif new.service_type='delivery' then
  if new.delivery_status is not null and (tg_op='INSERT' or new.delivery_status is distinct from old.delivery_status or (new.delivery_status='pending_acceptance' and new.payment_status='approved' and old.payment_status is distinct from new.payment_status)) and (new.payment_method<>'mercado_pago' or new.payment_status='approved') then
   perform public.enqueue_order_notification(new.id,null,'delivery',new.delivery_status);
  end if;
  if new.assigned_driver_id is not null and (tg_op='INSERT' or new.assigned_driver_id is distinct from old.assigned_driver_id) then
   perform public.enqueue_order_notification(new.id,null,'driver',new.assigned_driver_id::text);
  end if;
 end if;
 return new;
end;$$;
create trigger notify_order_transition after insert or update of payment_status,status,delivery_status,assigned_driver_id on public.orders for each row execute function public.notify_order_transition();
revoke all on function public.notify_order_transition() from public,anon,authenticated;

create function public.notify_ticket_transition() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' or old.status is distinct from new.status then
  if new.status in ('pendiente','preparando','listo','entregado') then perform public.enqueue_order_notification(new.order_id,new.id,'ticket',new.status);end if;
 end if;
 return new;
end;$$;
create trigger notify_ticket_transition after insert or update of status on public.kitchen_tickets for each row execute function public.notify_ticket_transition();
revoke all on function public.notify_ticket_transition() from public,anon,authenticated;

create function public.claim_order_notification(event_id uuid) returns setof public.order_notification_events language sql security invoker set search_path='' as $$
 update public.order_notification_events set attempts=attempts+1,next_attempt=now()+interval '2 minutes'
 where id=event_id and completed_at is null and attempts<8 and (attempts=0 or next_attempt<=now()) returning *;
$$;
revoke all on function public.claim_order_notification(uuid) from public,anon,authenticated;
grant execute on function public.claim_order_notification(uuid) to service_role;
select cron.schedule('retry-order-notifications','* * * * *',$job$
 select public.dispatch_order_notification(id) from public.order_notification_events where completed_at is null and attempts<8 and next_attempt<=now() and created_at>now()-interval '1 day' order by next_attempt limit 100;
 delete from public.order_notification_events where created_at<now()-interval '7 days';
$job$);
