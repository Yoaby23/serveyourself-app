-- Retira el modulo de solicitudes fiscales si una version anterior de 008 ya fue aplicada.
drop table if exists public.invoice_requests cascade;
