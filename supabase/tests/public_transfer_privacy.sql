do $$
declare
    restaurant_id uuid := gen_random_uuid();
begin
    insert into auth.users(id, email, raw_user_meta_data)
    values (restaurant_id, restaurant_id || '@example.invalid',
        '{"role":"negocio","business_name":"Catálogo de prueba"}');
    update public.profiles
    set bank_name = 'Banco de prueba', bank_account_holder = 'Titular de prueba',
        bank_clabe = '001234567890123456'
    where id = restaurant_id;

    execute 'set local role anon';
    assert exists(select 1 from public.public_restaurants p
        where p.id = restaurant_id and p.bank_name is null and p.bank_account_holder is null and p.bank_clabe is null);
    execute 'reset role';
    execute 'set local role authenticated';
    assert exists(select 1 from public.public_restaurants p
        where p.id = restaurant_id and p.bank_name is null and p.bank_account_holder is null and p.bank_clabe is null);
    execute 'reset role';
end;
$$;
