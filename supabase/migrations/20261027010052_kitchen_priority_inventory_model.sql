begin;

-- Reject corrupt inputs instead of clipping quantities and losing the audit trail.
alter table public.ingredients add constraint ingredients_nonnegative_finite
check (stock>=0 and stock<>'NaN'::numeric and minimum_stock>=0 and minimum_stock<>'NaN'::numeric and unit_cost>=0 and unit_cost<>'NaN'::numeric);
alter table public.product_recipes add constraint recipe_quantity_finite check(quantity<>'NaN'::numeric);
alter table public.products add column inventory_available boolean not null default true;
alter table public.inventory_movements add column kitchen_ticket_id bigint references public.kitchen_tickets(id) on delete set null;
create unique index inventory_sale_ticket_ingredient on public.inventory_movements(kitchen_ticket_id,ingredient_id) where movement_type='sale' and kitchen_ticket_id is not null;
create index recipes_ingredient_idx on public.product_recipes(ingredient_id);
create index kitchen_active_restaurant_idx on public.kitchen_tickets(restaurant_id,created_at,id) where status in ('pendiente','preparando');

create or replace function public.protect_ingredient_unit()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.unit is distinct from old.unit and (old.stock<>0 or exists(select 1 from public.product_recipes where ingredient_id=old.id) or exists(select 1 from public.inventory_movements where ingredient_id=old.id)) then
  raise exception 'No cambies la unidad de un ingrediente con existencias, recetas o historial; crea otro ingrediente';
 end if;
 return new;
end;$$;
create trigger protect_ingredient_unit before update of unit on public.ingredients for each row execute function public.protect_ingredient_unit();

create or replace function public.validate_recipe_restaurant()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_product_restaurant uuid;v_ingredient_restaurant uuid;
begin
 select restaurant_id into v_product_restaurant from public.products where id=new.product_id;
 select restaurant_id into v_ingredient_restaurant from public.ingredients where id=new.ingredient_id;
 if v_product_restaurant is null or v_product_restaurant is distinct from v_ingredient_restaurant then raise exception 'El producto y el ingrediente deben pertenecer al mismo restaurante';end if;
 return new;
end;$$;
create trigger validate_recipe_restaurant before insert or update on public.product_recipes for each row execute function public.validate_recipe_restaurant();
drop policy if exists recipes_owner on public.product_recipes;
create policy recipes_owner on public.product_recipes for all to authenticated
using(exists(select 1 from public.products p where p.id=product_id and p.restaurant_id=(select auth.uid())))
with check(exists(select 1 from public.products p where p.id=product_id and p.restaurant_id=(select auth.uid())) and exists(select 1 from public.ingredients i where i.id=ingredient_id and i.restaurant_id=(select auth.uid())));

-- A private projection of current recipe demand, summed across all products in a round.
create or replace function public.kitchen_resource_requirements(p_restaurant_id uuid,p_items jsonb)
returns table(ingredient_id uuid,ingredient_name text,unit text,required numeric,available numeric)
language sql stable security definer set search_path='' as $$
 select i.id,i.name,i.unit,sum(r.quantity*(x.value->>'qty')::numeric),i.stock
 from jsonb_array_elements(p_items) x
 join public.products p on p.id::text=x.value->>'id' and p.restaurant_id=p_restaurant_id
 join public.product_recipes r on r.product_id=p.id
 join public.ingredients i on i.id=r.ingredient_id and i.restaurant_id=p_restaurant_id
 group by i.id,i.name,i.unit,i.stock;
$$;
create or replace function public.kitchen_resource_status(p_restaurant_id uuid,p_items jsonb)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'has_shortage',exists(select 1 from public.kitchen_resource_requirements(p_restaurant_id,p_items) where available<required),
  'missing',coalesce((select jsonb_agg(jsonb_build_object('ingredient_id',ingredient_id,'name',ingredient_name,'unit',unit,'required',required,'available',available,'shortage',required-available) order by ingredient_name) from public.kitchen_resource_requirements(p_restaurant_id,p_items) where available<required),'[]'::jsonb),
  'untracked_products',(select count(distinct x.value->>'id') from jsonb_array_elements(p_items) x where not exists(select 1 from public.product_recipes r where r.product_id::text=x.value->>'id'))
 );
$$;

create or replace function public.refresh_product_inventory(p_product_id uuid)
returns void language sql security definer set search_path='' as $$
 update public.products p set inventory_available=not exists(
  select 1 from public.product_recipes r join public.ingredients i on i.id=r.ingredient_id
  where r.product_id=p.id and (i.restaurant_id<>p.restaurant_id or i.stock<r.quantity)
 ) where p.id=p_product_id;
$$;
create or replace function public.refresh_recipe_inventory()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op<>'DELETE' then perform public.refresh_product_inventory(new.product_id);end if;
 if tg_op<>'INSERT' then perform public.refresh_product_inventory(old.product_id);end if;
 return null;
end;$$;
create trigger refresh_recipe_inventory after insert or update or delete on public.product_recipes for each row execute function public.refresh_recipe_inventory();
create or replace function public.refresh_ingredient_inventory()
returns trigger language plpgsql security definer set search_path='' as $$
declare r record;
begin
 for r in select distinct product_id from public.product_recipes where ingredient_id=new.id order by product_id loop perform public.refresh_product_inventory(r.product_id);end loop;
 if tg_op='INSERT' and new.stock>0 then
  insert into public.inventory_movements(restaurant_id,ingredient_id,movement_type,quantity,reason,created_by) values(new.restaurant_id,new.id,'adjustment',new.stock,'Existencia inicial',auth.uid());
 end if;
 return null;
end;$$;
create trigger refresh_ingredient_inventory after insert or update of stock on public.ingredients for each row execute function public.refresh_ingredient_inventory();

create or replace function public.adjust_inventory(p_ingredient_id uuid,p_quantity numeric,p_type text,p_reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ingredient public.ingredients%rowtype;
begin
 select * into v_ingredient from public.ingredients where id=p_ingredient_id for update;
 if auth.uid() is null or not found or v_ingredient.restaurant_id<>auth.uid() then raise exception 'Ingrediente no encontrado';end if;
 if p_quantity is null or p_quantity='NaN'::numeric or p_quantity=0 or p_type is null or p_type not in ('purchase','adjustment','waste') or length(trim(coalesce(p_reason,'')))<2 then raise exception 'Cantidad, tipo o motivo inválido';end if;
 if (p_type='purchase' and p_quantity<0) or (p_type='waste' and p_quantity>0) then raise exception 'Una compra suma existencias y una merma las descuenta';end if;
 if v_ingredient.stock+p_quantity<0 then raise exception 'El ajuste supera la existencia disponible (% %)',v_ingredient.stock,v_ingredient.unit;end if;
 update public.ingredients set stock=stock+p_quantity,updated_at=now() where id=p_ingredient_id returning * into v_ingredient;
 insert into public.inventory_movements(restaurant_id,ingredient_id,movement_type,quantity,reason,created_by)
 values(v_ingredient.restaurant_id,p_ingredient_id,p_type,p_quantity,left(trim(p_reason),200),auth.uid());
 return to_jsonb(v_ingredient);
end;$$;
revoke update on public.ingredients from authenticated;
grant update(name,unit,minimum_stock,unit_cost) on public.ingredients to authenticated;
revoke update on public.products from authenticated;
grant update(name,description,price,image_url,category,is_available,kitchen_station_id) on public.products to authenticated;

create or replace function public.check_new_order_inventory()
returns trigger language plpgsql security definer set search_path='' as $$
declare r record;
begin
 if new.order_source='pos' then return new;end if;
 for r in select * from public.kitchen_resource_requirements(new.restaurant_id,new.items) where available<required loop
  raise exception 'Insumos insuficientes: % necesita % %, hay %',r.ingredient_name,r.required,r.unit,r.available;
 end loop;
 return new;
end;$$;
create trigger check_new_order_inventory before insert on public.orders for each row execute function public.check_new_order_inventory();
create or replace function public.check_new_ticket_inventory()
returns trigger language plpgsql security definer set search_path='' as $$
declare r record;
begin
 -- A paid online order must be recorded even if stock changed during checkout.
 -- Its pending ticket will clearly show the shortage; do not lose payment reconciliation.
 if exists(select 1 from public.orders where id=new.order_id and order_source='pos') then
  for r in select * from public.kitchen_resource_requirements(new.restaurant_id,new.items) where available<required loop
   raise exception 'Insumos insuficientes: % necesita % %, hay %',r.ingredient_name,r.required,r.unit,r.available;
  end loop;
 end if;
 return new;
end;$$;
create trigger check_new_ticket_inventory before insert on public.kitchen_tickets for each row execute function public.check_new_ticket_inventory();

create or replace function public.deduct_kitchen_ticket_inventory()
returns trigger language plpgsql security definer set search_path='' as $$
declare r record;
begin
 if new.status='preparando' and old.status is distinct from 'preparando' and not new.inventory_deducted then
  -- Lock every required ingredient in the same order BEFORE checking/deducting.
  perform 1 from public.ingredients i where i.id in(select ingredient_id from public.kitchen_resource_requirements(new.restaurant_id,new.items)) order by i.id for update;
  for r in select * from public.kitchen_resource_requirements(new.restaurant_id,new.items) order by ingredient_id loop
   if r.available<r.required then raise exception 'Insumos insuficientes: % necesita % %, hay %',r.ingredient_name,r.required,r.unit,r.available;end if;
   update public.ingredients set stock=stock-r.required,updated_at=now() where id=r.ingredient_id and restaurant_id=new.restaurant_id and stock>=r.required;
   if not found then raise exception 'Insumos insuficientes para %; actualiza la cola',r.ingredient_name;end if;
   insert into public.inventory_movements(restaurant_id,ingredient_id,movement_type,quantity,reason,order_id,kitchen_ticket_id,created_by)
   values(new.restaurant_id,r.ingredient_id,'sale',-r.required,'Consumo por comanda #'||new.id,new.order_id,new.id,auth.uid());
  end loop;
  new.inventory_deducted:=true;
 end if;
 return new;
end;$$;

-- Estimate quantity and peak effects jointly using within-group centered regression.
-- This removes the old double counting of the peak effect in the intercept.
create or replace function public.kitchen_work_units(p_items jsonb)
returns numeric language sql immutable set search_path='' as $$
 select greatest(1,coalesce(sum(greatest(coalesce((x->>'qty')::numeric,1),0)),0)+count(distinct x->>'id')*.35) from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) x;
$$;
create or replace function public.fit_kitchen_samples(p_samples jsonb)
returns jsonb language sql immutable set search_path='' as $$
 with d as (select (x->>'work_units')::numeric x,(x->>'prep_minutes')::numeric y,(x->>'is_peak')::boolean p from jsonb_array_elements(p_samples) x),
 g as (select p,avg(x) mx,avg(y) my from d group by p),
 slope as (select greatest(0,least(60,coalesce(sum((d.x-g.mx)*(d.y-g.my))/nullif(sum(power(d.x-g.mx,2)),0),0))) b from d join g using(p)),
 intercepts as (select b,avg(y-b*x) filter(where not p) off_peak,avg(y-b*x) filter(where p) peak from d cross join slope group by b)
 select jsonb_build_object('intercept',coalesce(off_peak,peak,0),'per_work_unit',b,'peak_adjustment',case when off_peak is not null and peak is not null then peak-off_peak else 0 end) from intercepts;
$$;
alter table public.kitchen_ml_models add column training_sample_count integer not null default 0,
 add column validation_sample_count integer not null default 0,add column peak_sample_count integer not null default 0,
 add column off_peak_sample_count integer not null default 0,add column model_ready boolean not null default false,
 add column off_peak_work_min numeric,add column off_peak_work_max numeric,
 add column peak_work_min numeric,add column peak_work_max numeric,
 add column trained_products jsonb not null default '[]'::jsonb;

create or replace function public.retrain_kitchen_model(p_restaurant_id uuid,p_service_type text)
returns void language plpgsql security definer set search_path='' as $$
declare samples jsonb;training jsonb;fitted jsonb;final_fit jsonb;n integer;v_holdout integer;v_mae numeric;v_mean numeric;v_peak integer;v_off integer;v_ready boolean;v_off_min numeric;v_off_max numeric;v_peak_min numeric;v_peak_max numeric;v_products jsonb;
begin
 -- Bounded recent history keeps learning cost predictable and adapts to recipe changes.
 select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at,s.id),'[]'::jsonb) into samples from
 (select id,ticket_id,work_units,prep_minutes,is_peak,created_at from public.kitchen_prep_samples where restaurant_id=p_restaurant_id and service_type=p_service_type order by created_at desc,id desc limit 500) s;
 n:=jsonb_array_length(samples);if n=0 then return;end if;
 v_holdout:=case when n>=10 then greatest(2,floor(n*.2)::integer) else 0 end;
 select coalesce(jsonb_agg(value order by ordinality),'[]'::jsonb) into training from jsonb_array_elements(samples) with ordinality where ordinality<=n-v_holdout;
 fitted:=public.fit_kitchen_samples(training);final_fit:=public.fit_kitchen_samples(samples);
 select count(*) filter(where (x->>'is_peak')::boolean),count(*) filter(where not (x->>'is_peak')::boolean),avg((x->>'prep_minutes')::numeric) into v_peak,v_off,v_mean from jsonb_array_elements(samples) x;
 if v_holdout>0 then
  select avg(abs((value->>'prep_minutes')::numeric - greatest(5,least(240,(fitted->>'intercept')::numeric+(fitted->>'per_work_unit')::numeric*(value->>'work_units')::numeric+case when (value->>'is_peak')::boolean then (fitted->>'peak_adjustment')::numeric else 0 end))))
  into v_mae from jsonb_array_elements(samples) with ordinality where ordinality>n-v_holdout;
 end if;
 select min((x->>'work_units')::numeric) filter(where not (x->>'is_peak')::boolean),max((x->>'work_units')::numeric) filter(where not (x->>'is_peak')::boolean),min((x->>'work_units')::numeric) filter(where (x->>'is_peak')::boolean),max((x->>'work_units')::numeric) filter(where (x->>'is_peak')::boolean)
 into v_off_min,v_off_max,v_peak_min,v_peak_max from jsonb_array_elements(samples) x;
 select coalesce(jsonb_agg(distinct item->>'id'),'[]'::jsonb) into v_products from public.kitchen_tickets t cross join lateral jsonb_array_elements(t.items) item where t.id in(select (x->>'ticket_id')::bigint from jsonb_array_elements(samples) x);
 v_ready:=n>=10 and v_mae is not null and v_mae<=greatest(5,v_mean*.35);
 insert into public.kitchen_ml_models(restaurant_id,service_type,sample_count,intercept,per_work_unit,peak_adjustment,mean_absolute_error,trained_at,training_sample_count,validation_sample_count,peak_sample_count,off_peak_sample_count,model_ready,off_peak_work_min,off_peak_work_max,peak_work_min,peak_work_max,trained_products)
 values(p_restaurant_id,p_service_type,n,(final_fit->>'intercept')::numeric,(final_fit->>'per_work_unit')::numeric,(final_fit->>'peak_adjustment')::numeric,v_mae,now(),n-v_holdout,v_holdout,v_peak,v_off,v_ready,v_off_min,v_off_max,v_peak_min,v_peak_max,v_products)
 on conflict(restaurant_id,service_type) do update set sample_count=excluded.sample_count,intercept=excluded.intercept,per_work_unit=excluded.per_work_unit,peak_adjustment=excluded.peak_adjustment,mean_absolute_error=excluded.mean_absolute_error,trained_at=excluded.trained_at,training_sample_count=excluded.training_sample_count,validation_sample_count=excluded.validation_sample_count,peak_sample_count=excluded.peak_sample_count,off_peak_sample_count=excluded.off_peak_sample_count,model_ready=excluded.model_ready,off_peak_work_min=excluded.off_peak_work_min,off_peak_work_max=excluded.off_peak_work_max,peak_work_min=excluded.peak_work_min,peak_work_max=excluded.peak_work_max,trained_products=excluded.trained_products;
end;$$;

create or replace function public.predict_kitchen_minutes(p_ticket_id bigint)
returns numeric language plpgsql stable security definer set search_path='' as $$
declare t public.kitchen_tickets%rowtype;p public.profiles%rowtype;m public.kitchen_ml_models%rowtype;v_default numeric;v_peak boolean;v_hour integer;v_work numeric;
begin
 select * into t from public.kitchen_tickets where id=p_ticket_id;if not found then raise exception 'Comanda no encontrada';end if;
 select * into p from public.profiles where id=t.restaurant_id;
 select * into m from public.kitchen_ml_models where restaurant_id=t.restaurant_id and service_type=t.service_type;
 v_default:=case t.service_type when 'delivery' then p.delivery_prep_minutes when 'dine_in' then p.dine_in_prep_minutes else p.pickup_prep_minutes end;
 v_hour:=extract(hour from coalesce(t.started_at,now()) at time zone coalesce(p.timezone,'UTC'))::integer;
 v_peak:=v_hour between 13 and 16 or v_hour between 19 and 22;
 v_work:=public.kitchen_work_units(t.items);
 if exists(select 1 from jsonb_array_elements(t.items) x where not (m.trained_products ? (x->>'id'))) or (v_peak and (v_work<m.peak_work_min or v_work>m.peak_work_max)) or (not v_peak and (v_work<m.off_peak_work_min or v_work>m.off_peak_work_max)) or not coalesce(m.model_ready,false) or (v_peak and m.peak_sample_count<3) or (not v_peak and m.off_peak_sample_count<3) then return greatest(5,least(240,coalesce(v_default,20)));end if;
 return round(greatest(5,least(240,m.intercept+m.per_work_unit*public.kitchen_work_units(t.items)+case when v_peak then m.peak_adjustment else 0 end)),2);
end;$$;


create or replace function public.kitchen_model_usable(p_ticket_id bigint)
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(m.model_ready,false)
 and not exists(select 1 from jsonb_array_elements(t.items) x where not (m.trained_products ? (x->>'id')))
 and case when extract(hour from coalesce(t.started_at,now()) at time zone coalesce(p.timezone,'UTC'))::integer between 13 and 16 or extract(hour from coalesce(t.started_at,now()) at time zone coalesce(p.timezone,'UTC'))::integer between 19 and 22
 then m.peak_sample_count>=3 and public.kitchen_work_units(t.items) between m.peak_work_min and m.peak_work_max
 else m.off_peak_sample_count>=3 and public.kitchen_work_units(t.items) between m.off_peak_work_min and m.off_peak_work_max end
 from public.kitchen_tickets t join public.profiles p on p.id=t.restaurant_id left join public.kitchen_ml_models m on m.restaurant_id=t.restaurant_id and m.service_type=t.service_type where t.id=p_ticket_id;
$$;
alter table public.kitchen_tickets add column prediction_source text check(prediction_source in ('configured_time','validated_model')),add column prediction_error_minutes numeric;
create or replace function public.prepare_kitchen_ticket_timing()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='preparando' and old.status is distinct from 'preparando' then
  new.started_at:=coalesce(new.started_at,now());
  if new.predicted_prep_minutes is null then
   new.predicted_prep_minutes:=public.predict_kitchen_minutes(new.id);
   new.prediction_source:=case when public.kitchen_model_usable(new.id) then 'validated_model' else 'configured_time' end;
   if new.prediction_source='validated_model' then select mean_absolute_error into new.prediction_error_minutes from public.kitchen_ml_models where restaurant_id=new.restaurant_id and service_type=new.service_type;end if;
  end if;
 elsif new.status='listo' and old.status is distinct from 'listo' then
  new.started_at:=coalesce(new.started_at,old.started_at,new.created_at);
  new.ready_at:=coalesce(new.ready_at,now());
  new.predicted_prep_minutes:=coalesce(new.predicted_prep_minutes,public.predict_kitchen_minutes(new.id));
  new.prediction_source:=coalesce(new.prediction_source,'configured_time');
 end if;
 return new;
end;$$;

create or replace function public.list_kitchen_priority_queue(p_restaurant_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_result jsonb;
begin
    if not public.has_restaurant_permission(p_restaurant_id,'view_kitchen') then raise exception 'Sin permiso para ver cocina';end if;

    with base as (
        select t.*,o.scheduled_for,o.assigned_driver_id,o.driver_latitude,o.driver_longitude,o.driver_location_at,o.delivery_status,
               p.latitude as restaurant_latitude,p.longitude as restaurant_longitude,p.pickup_prep_minutes,p.dine_in_prep_minutes,p.delivery_prep_minutes,
               d.vehicle_type,m.sample_count,coalesce(t.prediction_error_minutes,m.mean_absolute_error) as mean_absolute_error,m.validation_sample_count,
               case when t.predicted_prep_minutes is not null then coalesce(t.prediction_source,'configured_time')='validated_model' else public.kitchen_model_usable(t.id) end as usable_model,
               case when t.inventory_deducted then false else (resources.state->>'has_shortage')::boolean end as has_shortage,
               case when t.inventory_deducted then '[]'::jsonb else resources.state->'missing' end as missing_ingredients,
               (resources.state->>'untracked_products')::integer as untracked_products,
               coalesce(t.predicted_prep_minutes,public.predict_kitchen_minutes(t.id)) as predicted_minutes,
               coalesce((select jsonb_agg(to_jsonb(s)) from public.kitchen_ticket_station_statuses s where s.ticket_id=t.id),'[]'::jsonb) as station_statuses
        from public.kitchen_tickets t
        join public.orders o on o.id=t.order_id
        join public.profiles p on p.id=t.restaurant_id
        left join public.delivery_drivers d on d.user_id=o.assigned_driver_id
        cross join lateral (select public.kitchen_resource_status(t.restaurant_id,t.items) as state) resources
        left join public.kitchen_ml_models m on m.restaurant_id=t.restaurant_id and m.service_type=t.service_type
        where t.restaurant_id=p_restaurant_id and t.status in('pendiente','preparando') and o.status<>'cancelado' and (o.payment_method<>'mercado_pago' or o.payment_status='approved')
    ), eta as (
        select b.*,
            case when b.service_type='delivery' and b.assigned_driver_id is not null
                       and b.driver_latitude is not null and b.driver_longitude is not null
                       and b.restaurant_latitude is not null and b.restaurant_longitude is not null
                       and b.driver_location_at>now()-interval '3 minutes'
                then greatest(1,ceil(
                    (6371*acos(greatest(-1,least(1,
                        cos(radians(b.driver_latitude))*cos(radians(b.restaurant_latitude))*cos(radians(b.restaurant_longitude)-radians(b.driver_longitude))+
                        sin(radians(b.driver_latitude))*sin(radians(b.restaurant_latitude))
                    )))) / case b.vehicle_type when 'walking' then 5 when 'bicycle' then 15 else 25 end * 60
                ))::integer
                else null end as driver_eta_minutes
        from base b
    ), targets as (
        select e.*,
            case
                when service_type='delivery' and driver_eta_minutes is not null then now()+make_interval(mins=>driver_eta_minutes)
                when scheduled_for is not null then scheduled_for
                when service_type='delivery' then created_at+make_interval(mins=>delivery_prep_minutes)
                when service_type='dine_in' then created_at+make_interval(mins=>dine_in_prep_minutes)
                else created_at+make_interval(mins=>pickup_prep_minutes)
            end as target_ready_at
        from eta e
    ), ranked as (
        select x.*,
            x.target_ready_at-make_interval(secs=>round(x.predicted_minutes*60)::integer) as recommended_start_at,
            extract(epoch from (now()-(x.target_ready_at-make_interval(secs=>round(x.predicted_minutes*60)::integer))))/60*10
                + extract(epoch from (now()-x.created_at))/60*0.5 as priority_score
        from targets x
    )
    select coalesce(jsonb_agg(
        to_jsonb(r)-'restaurant_latitude'-'restaurant_longitude'-'pickup_prep_minutes'-'dine_in_prep_minutes'-'delivery_prep_minutes'-'vehicle_type'-'driver_latitude'-'driver_longitude'-'driver_location_at'
        || jsonb_build_object(
            'kitchen_ticket_station_statuses',r.station_statuses,
            'predicted_prep_minutes',round(r.predicted_minutes),
            'priority_reason',case
                when r.has_shortage then 'Faltan insumos para comenzar'
                when r.priority_override=2 then 'Urgente por cocina'
                when r.priority_override=1 then 'Prioridad alta manual'
                when r.priority_override=-1 then 'Pospuesto por cocina'
                when r.service_type='delivery' and r.driver_eta_minutes is not null then 'Repartidor llega en '||r.driver_eta_minutes||' min'
                when r.service_type='pickup' and r.scheduled_for is not null then 'Recogida programada'
                when r.service_type='delivery' then 'Delivery en espera de repartidor'
                when r.service_type='dine_in' then 'Servicio en mesa'
                else 'Recogida lo antes posible'
            end,
            'model_ready',r.usable_model,
            'can_start',not r.has_shortage,
            'minimum_samples',10,
            'prediction_source',case when r.usable_model then 'validated_model' else 'configured_time' end
        ) order by case r.status when 'preparando' then 0 else 1 end,r.has_shortage,r.priority_override desc,r.recommended_start_at,r.created_at,r.id
    ),'[]'::jsonb) into v_result
    from ranked r;
    return v_result;
end;
$$;

create or replace function public.update_kitchen_ticket_status(p_ticket_id bigint,p_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ticket public.kitchen_tickets%rowtype;
begin
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id;
    if found then perform 1 from public.orders where id=v_ticket.order_id for update;end if;
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id for update;
    if not found then raise exception 'Comanda no encontrada'; end if;
    if not public.has_restaurant_permission(v_ticket.restaurant_id,'view_kitchen') then raise exception 'Sin permiso de cocina'; end if;
    if p_status is null or v_ticket.status not in ('pendiente','preparando','listo') then raise exception 'Comanda cerrada o estado inválido';end if;
    if (v_ticket.status='pendiente' and p_status<>'preparando') or (v_ticket.status='preparando' and p_status<>'listo') or (v_ticket.status='listo' and p_status<>'entregado') then raise exception 'Cambio de estado invalido'; end if;
    update public.kitchen_ticket_station_statuses set status=p_status,updated_at=now() where ticket_id=p_ticket_id;
    update public.kitchen_tickets set status=p_status,
      ready_at=case when p_status='listo' then coalesce(ready_at,now()) else ready_at end,
      delivered_at=case when p_status='entregado' then coalesce(delivered_at,now()) else delivered_at end
    where id=p_ticket_id returning * into v_ticket;
    perform public.refresh_order_kitchen_status(v_ticket.order_id);
    return to_jsonb(v_ticket);
end; $$;

create or replace function public.update_kitchen_ticket_station_status(p_ticket_id bigint,p_station_key text,p_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_station public.kitchen_ticket_station_statuses%rowtype; v_ticket public.kitchen_tickets%rowtype; v_status text;
begin
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id;
    if not found then raise exception 'Comanda no encontrada';end if;
    perform 1 from public.orders where id=v_ticket.order_id for update;
    perform 1 from public.kitchen_tickets where id=p_ticket_id for update;
    select * into v_station from public.kitchen_ticket_station_statuses where ticket_id=p_ticket_id and station_key=p_station_key for update;
    if not found then raise exception 'Estacion de la comanda no encontrada'; end if;
    if not public.has_restaurant_permission(v_station.restaurant_id,'view_kitchen') then raise exception 'Sin permiso de cocina'; end if;
    if p_status is null or v_station.status not in ('pendiente','preparando','listo') then raise exception 'Estación cerrada o estado inválido';end if;
    if (v_station.status='pendiente' and p_status<>'preparando') or (v_station.status='preparando' and p_status<>'listo') or (v_station.status='listo' and p_status<>'entregado') then raise exception 'Cambio de estado invalido'; end if;
    update public.kitchen_ticket_station_statuses set status=p_status,updated_at=now() where ticket_id=p_ticket_id and station_key=p_station_key returning * into v_station;
    select case when bool_and(status='entregado') then 'entregado' when bool_and(status in ('listo','entregado')) then 'listo' when bool_or(status in ('preparando','listo','entregado')) then 'preparando' else 'pendiente' end
    into v_status from public.kitchen_ticket_station_statuses where ticket_id=p_ticket_id;
    update public.kitchen_tickets set status=v_status,
      ready_at=case when v_status='listo' then coalesce(ready_at,now()) else ready_at end,
      delivered_at=case when v_status='entregado' then coalesce(delivered_at,now()) else delivered_at end
    where id=p_ticket_id returning * into v_ticket;
    perform public.refresh_order_kitchen_status(v_ticket.order_id);
    return to_jsonb(v_station)||jsonb_build_object('ticket_status',v_status);
end; $$;

create or replace function public.mark_kitchen_ticket_delivered(p_ticket_id bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ticket public.kitchen_tickets%rowtype;
begin
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id;
    if found then perform 1 from public.orders where id=v_ticket.order_id for update;end if;
    select * into v_ticket from public.kitchen_tickets where id=p_ticket_id for update;
    if not found then raise exception 'Comanda no encontrada';end if;
    if v_ticket.status<>'listo' then raise exception 'La comanda ya no esta lista para entregar';end if;
    if not (
        v_ticket.created_by=auth.uid()
        or public.has_restaurant_permission(v_ticket.restaurant_id,'create_orders')
        or public.has_restaurant_permission(v_ticket.restaurant_id,'close_accounts')
        or public.has_restaurant_permission(v_ticket.restaurant_id,'view_kitchen')
    ) then raise exception 'No tienes permiso para entregar esta comanda';end if;
    update public.kitchen_ticket_station_statuses set status='entregado',updated_at=now() where ticket_id=p_ticket_id;
    update public.kitchen_tickets set status='entregado',delivered_at=coalesce(delivered_at,now()) where id=p_ticket_id returning * into v_ticket;
    perform public.refresh_order_kitchen_status(v_ticket.order_id);
    insert into public.order_audit_logs(order_id,restaurant_id,action,details,actor_id)
    values(v_ticket.order_id,v_ticket.restaurant_id,'kitchen_ticket_delivered',jsonb_build_object('ticket_id',v_ticket.id),auth.uid());
    return to_jsonb(v_ticket);
end; $$;


create or replace view public.public_qr_products as
select id,restaurant_id,name,price,category,image_url from public.products where is_available and inventory_available;

-- Internal helpers never expose inventory or training data through public RPC calls.
revoke all on function public.protect_ingredient_unit(),public.validate_recipe_restaurant(),public.kitchen_resource_requirements(uuid,jsonb),public.kitchen_resource_status(uuid,jsonb),public.refresh_product_inventory(uuid),public.refresh_recipe_inventory(),public.refresh_ingredient_inventory(),public.check_new_order_inventory(),public.check_new_ticket_inventory(),public.fit_kitchen_samples(jsonb),public.kitchen_model_usable(bigint) from public,anon,authenticated;
revoke all on function public.deduct_kitchen_ticket_inventory(),public.retrain_kitchen_model(uuid,text),public.predict_kitchen_minutes(bigint) from public,anon,authenticated;
revoke all on function public.adjust_inventory(uuid,numeric,text,text),public.list_kitchen_priority_queue(uuid),public.update_kitchen_ticket_status(bigint,text),public.update_kitchen_ticket_station_status(bigint,text,text),public.mark_kitchen_ticket_delivered(bigint) from public,anon;
grant execute on function public.adjust_inventory(uuid,numeric,text,text),public.list_kitchen_priority_queue(uuid),public.update_kitchen_ticket_status(bigint,text),public.update_kitchen_ticket_station_status(bigint,text,text),public.mark_kitchen_ticket_delivered(bigint) to authenticated;
revoke delete on public.ingredients from authenticated;

-- Recompute derived state and retrain real historical observations only.
do $$ declare r record;begin
 for r in select id from public.products order by id loop perform public.refresh_product_inventory(r.id);end loop;
 for r in select distinct restaurant_id,service_type from public.kitchen_prep_samples loop perform public.retrain_kitchen_model(r.restaurant_id,r.service_type);end loop;
end;$$;
commit;
