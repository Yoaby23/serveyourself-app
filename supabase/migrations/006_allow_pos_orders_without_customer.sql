-- Los pedidos creados por meseros no pertenecen a una cuenta de cliente.
-- Ejecutar despues de 005_pos_payment_lifecycle.sql.

begin;

alter table public.orders
    alter column customer_id drop not null;

commit;
