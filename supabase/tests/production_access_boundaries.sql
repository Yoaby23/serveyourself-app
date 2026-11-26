do $$
declare
    table_name text;
    role_name text;
    signature text;
begin
    -- Internal records are served through checked RPCs or Edge Functions.
    foreach table_name in array array[
        'cash_operation_requests', 'customer_order_requests', 'guest_checkout_requests',
        'mercado_pago_oauth_states', 'order_notification_events', 'payment_refund_operations',
        'platform_delivery_settings', 'restaurant_payment_accounts'
    ] loop
        assert (select relrowsecurity from pg_class where oid=format('public.%I',table_name)::regclass),
            format('%s must have row-level security',table_name);
        foreach role_name in array array['anon', 'authenticated'] loop
            assert not has_table_privilege(role_name,format('public.%I',table_name),'SELECT,INSERT,UPDATE,DELETE'),
                format('%s must not access %s directly',role_name,table_name);
        end loop;
    end loop;

    foreach signature in array array[
        'public.reconcile_order_payment(bigint,jsonb)',
        'public.create_guest_pickup_order(text,text,uuid,jsonb,text,text,text)',
        'sy_private.record_online_payment_event()'
    ] loop
        assert not has_function_privilege('anon',signature,'EXECUTE'),format('Anonymous execution of %s',signature);
        assert not has_function_privilege('authenticated',signature,'EXECUTE'),format('Client execution of %s',signature);
    end loop;

    assert has_function_privilege('service_role','public.reconcile_order_payment(bigint,jsonb)','EXECUTE');
    assert has_function_privilege('service_role','public.create_guest_pickup_order(text,text,uuid,jsonb,text,text,text)','EXECUTE');
    assert not has_table_privilege('anon','public.online_payment_events','SELECT');
    assert not has_column_privilege('authenticated','public.online_payment_events','provider_net','UPDATE');
    assert not exists (
        select from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.prosecdef
          and has_function_privilege('authenticated',p.oid,'EXECUTE')
          and not coalesce('search_path=""'=any(p.proconfig),false)
    ), 'An authenticated SECURITY DEFINER function has an unrestricted search_path';
end;
$$;
