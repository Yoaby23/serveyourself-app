begin;

-- Google, Facebook y Apple entregan nombres e imágenes con claves distintas.
-- Normalizamos esos metadatos para que toda cuenta social tenga un perfil válido.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    requested_role text;
    display_name text;
    provider_avatar text;
begin
    requested_role := case
        when new.raw_user_meta_data ->> 'role' = 'negocio' then 'negocio'
        else 'cliente'
    end;

    display_name := left(coalesce(
        nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
        nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
        nullif(btrim(new.raw_user_meta_data ->> 'preferred_username'), ''),
        nullif(btrim(new.raw_user_meta_data ->> 'user_name'), ''),
        nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
        'Usuario'
    ), 120);

    provider_avatar := left(coalesce(
        nullif(new.raw_user_meta_data ->> 'avatar_url', ''),
        nullif(new.raw_user_meta_data ->> 'picture', '')
    ), 500);

    insert into public.profiles (
        id, full_name, email, phone, role, business_name, address,
        open_time, close_time, avatar_url, rating
    ) values (
        new.id,
        display_name,
        new.email,
        left(coalesce(new.raw_user_meta_data ->> 'phone', ''), 30),
        requested_role,
        case when requested_role = 'negocio' then left(new.raw_user_meta_data ->> 'business_name', 120) end,
        case when requested_role = 'negocio' then left(new.raw_user_meta_data ->> 'address', 250) end,
        case when requested_role = 'negocio' then nullif(new.raw_user_meta_data ->> 'open_time', '')::time end,
        case when requested_role = 'negocio' then nullif(new.raw_user_meta_data ->> 'close_time', '')::time end,
        provider_avatar,
        5.0
    )
    on conflict (id) do nothing;

    return new;
end;
$$;

commit;
