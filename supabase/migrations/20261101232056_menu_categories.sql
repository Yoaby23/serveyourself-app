-- Categories are managed independently of products and kitchen stations.
-- Keep products.category for compatibility with existing menus and cached clients.
create table public.menu_categories (
 restaurant_id uuid not null references public.profiles(id) on delete cascade,
 name text not null check (name=btrim(name) and char_length(name) between 1 and 80),
 name_key text generated always as (lower(name)) stored,
 created_at timestamptz not null default now(),
 primary key(restaurant_id,name_key)
);
alter table public.menu_categories enable row level security;
revoke all on public.menu_categories from public,anon,authenticated;
grant select,insert on public.menu_categories to authenticated;
create policy menu_categories_owner_read on public.menu_categories for select to authenticated using (restaurant_id=(select auth.uid()));
create policy menu_categories_owner_create on public.menu_categories for insert to authenticated with check (
 restaurant_id=(select auth.uid()) and exists(select 1 from public.profiles where id=(select auth.uid()) and role='negocio')
);
insert into public.menu_categories(restaurant_id,name)
select restaurant_id,min(category) from public.products group by restaurant_id,lower(category);
