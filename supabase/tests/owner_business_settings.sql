do $$
declare owner_id uuid:=gen_random_uuid();other_id uuid:=gen_random_uuid();changed int;blocked boolean;week jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(owner_id,owner_id||'@example.invalid','{"role":"negocio","business_name":"Owner QA"}'),(other_id,other_id||'@example.invalid','{"role":"negocio","business_name":"Other QA"}');
 week:=(select jsonb_agg(jsonb_build_object('closed',false,'allDay',true)) from generate_series(1,7));
 perform set_config('request.jwt.claim.sub',owner_id::text,true);execute 'set local role authenticated';
 update public.profiles set business_name='Updated business',phone='5512345678',business_hours=week,open_time=null,close_time=null,accepting_orders=true,latitude=19.4,longitude=-99.1,delivery_enabled=true,delivery_radius_km=5,delivery_minimum=0,delivery_base_fee=10,delivery_fee_per_km=2,delivery_free_over=null,delivery_prep_minutes=30,pickup_prep_minutes=20,dine_in_prep_minutes=15,payment_cash=true,payment_transfer=true,payment_online=false,guest_pickup_enabled=true,bank_name='QA',bank_account_holder='QA Owner',bank_clabe='012345678901234567' where id=owner_id;
 get diagnostics changed=row_count;assert changed=1,'Owner settings not saved';
 update public.profiles set avatar_url='https://example.invalid/owned-image.png',address='QA address' where id=owner_id;
 get diagnostics changed=row_count;assert changed=1,'Owner image/profile not saved';
 update public.profiles set business_name='Wrong owner' where id=other_id;
 get diagnostics changed=row_count;assert changed=0,'Owner changed another business';
 blocked:=false;begin update public.profiles set role='cliente' where id=owner_id;exception when insufficient_privilege then blocked:=true;end;assert blocked,'Profile role could be changed directly';
 blocked:=false;begin update public.profiles set mercado_pago_connected=true where id=owner_id;exception when insufficient_privilege then blocked:=true;end;assert blocked,'Payment connection could be forged';
 assert exists(select from public.profiles where id=owner_id and business_name='Updated business' and business_hours=week),'Saved values mismatch';
 execute 'reset role';
end;$$;
