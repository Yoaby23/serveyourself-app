do $$
declare owner_id uuid:=gen_random_uuid();other_id uuid:=gen_random_uuid();cashier uuid:=gen_random_uuid();client_id uuid:=gen_random_uuid();result jsonb;blocked boolean;product_id uuid;order_result jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(owner_id,owner_id||'@example.invalid','{"role":"negocio","business_name":"Credit QA"}'),(other_id,other_id||'@example.invalid','{"role":"negocio","business_name":"Other"}'),(cashier,cashier||'@example.invalid','{"full_name":"Cashier"}');
 insert into public.products(restaurant_id,name,price) values(owner_id,'QA',50) returning id into product_id;
 insert into public.restaurant_staff(restaurant_id,user_id,staff_role,is_active,can_close_accounts) values(owner_id,cashier,'cashier',true,true);
 perform set_config('request.jwt.claim.sub',cashier::text,true);execute 'set local role authenticated';
 blocked:=false;begin perform public.create_credit_customer_from_checkout(client_id,owner_id,'New customer','5512345678',500);exception when insufficient_privilege then blocked:=true;end;assert blocked,'Cashier enabled credit without approval';
 perform set_config('request.jwt.claim.sub',other_id::text,true);
 blocked:=false;begin perform public.create_credit_customer_from_checkout(client_id,owner_id,'New customer','5512345678',500);exception when insufficient_privilege then blocked:=true;end;assert blocked,'Another owner approved credit';
 perform set_config('request.jwt.claim.sub',owner_id::text,true);
 result:=public.create_credit_customer_from_checkout(client_id,owner_id,'New customer','55 1234 5678',500);
 assert (result->>'id')::uuid=client_id and (result->>'credit_enabled')::boolean and (result->>'credit_limit')::numeric=500;
 assert (public.create_credit_customer_from_checkout(client_id,owner_id,'New customer','+52 55 1234 5678',500)->>'id')::uuid=client_id,'Retry duplicated customer';
 blocked:=false;begin perform public.create_credit_customer_from_checkout(gen_random_uuid(),owner_id,'Duplicate','+52 55 1234 5678',500);exception when raise_exception then blocked:=true;end;assert blocked,'Phone duplicate accepted';
 blocked:=false;begin perform public.create_credit_customer_from_checkout(gen_random_uuid(),owner_id,'Invalid','5512345679','NaN');exception when raise_exception then blocked:=true;end;assert blocked,'Invalid credit limit accepted';
 perform set_config('request.jwt.claim.sub',cashier::text,true);
 assert exists(select from public.get_customer_credit_balances(owner_id) where customer_id=client_id and credit_enabled),'Approved customer not available to cashier';
 perform public.open_cash_shift(owner_id,0);
 order_result:=public.cashier_create_takeaway(gen_random_uuid(),owner_id,jsonb_build_array(jsonb_build_object('id',product_id,'qty',2)),'New customer',null,'credit',null);
 order_result:=public.charge_order_to_customer_credit((order_result->>'id')::bigint,client_id,null,null);
 assert order_result->>'payment_status'='on_credit','Cashier could not charge the approved client';
 execute 'reset role';
 assert exists(select from public.kitchen_tickets where order_id=(order_result->>'id')::bigint),'Approved credit order did not reach kitchen';
 assert (select count(*)=1 from public.loyalty_customers where restaurant_id=owner_id),'Failed approval created customer';
end;$$;
