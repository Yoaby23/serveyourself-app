do $$
declare signature text; denied boolean;
begin
 foreach signature in array array['create_order(uuid,jsonb,text)','create_order_v2(uuid,jsonb,text,text)','create_pos_order(uuid,jsonb,text,text,bigint,text)','append_pos_order_items(bigint,jsonb,text)','create_or_append_pos_order(uuid,jsonb,text,text,bigint,text)','update_kitchen_order_status(bigint,text)','update_kitchen_station_status(bigint,text,text)'] loop
  assert not has_function_privilege('authenticated','public.'||signature,'EXECUTE'), 'Legacy function still callable: '||signature;
  assert not has_function_privilege('anon','public.'||signature,'EXECUTE'), 'Anonymous execution: '||signature;
 end loop;
 assert has_function_privilege('authenticated','public.create_pos_table_order(uuid,jsonb,text,text,bigint,text,bigint)','EXECUTE');
 assert has_function_privilege('authenticated','public.create_customer_order_once(uuid,jsonb)','EXECUTE');
 assert not has_any_column_privilege('authenticated','public.orders','UPDATE'), 'Orders still directly writable';
 execute 'set local role authenticated';
 denied:=false;
 begin update public.orders set status='entregado' where false; exception when insufficient_privilege then denied:=true; end;
 assert denied,'Direct order update accepted';
 execute 'reset role';
end;$$;
