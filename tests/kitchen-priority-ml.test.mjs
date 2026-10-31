import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = file => readFileSync(join(root, file), 'utf8');
const migration = read('supabase/migrations/024_ml_kitchen_priority.sql');
const kitchen = read('cocina.html');
const customer = read('restaurante.html');
const driver = read('repartidor.html');
const admin = read('admin.html');
const worker = read('sw.js');

assert.match(migration, /create table if not exists public\.kitchen_prep_samples/, 'Debe guardar ejemplos de entrenamiento reales');
assert.match(migration, /regr_intercept\(prep_minutes::double precision,work_units::double precision\)/, 'Debe entrenar una regresión supervisada');
assert.match(migration, /create trigger learn_from_kitchen_ticket/, 'Debe aprender automáticamente al terminar una comanda');
assert.match(migration, /coalesce\(v_model\.sample_count,0\)<5/, 'Debe usar una fase segura de calibración');
assert.match(migration, /driver_location_at>now\(\)-interval '3 minutes'/, 'Solo debe usar ubicación reciente del repartidor');
assert.match(migration, /priority_override\*1000/, 'La decisión manual de cocina debe prevalecer');
assert.match(migration, /create_scheduled_pickup_order/, 'Pickup programado debe crearse de forma transaccional');
assert.match(migration, /delivery_status in\('accepted','preparing','ready_for_dispatch','picked_up','on_the_way','arrived'\)/, 'El ETA debe recibir ubicación antes de la recogida');

assert.match(kitchen, /rpc\('list_kitchen_priority_queue'/, 'Cocina debe usar la cola inteligente');
assert.match(kitchen, /set_kitchen_ticket_priority/, 'Cocina debe poder corregir la prioridad');
assert.match(kitchen, /table: 'orders'/, 'Los cambios del repartidor deben refrescar cocina en tiempo real');
assert.match(kitchen, /Calibrando tiempos/, 'La interfaz debe explicar la fase de calibración');
assert.match(customer, /pickup-scheduled-for/, 'El cliente debe poder programar pickup');
assert.match(customer, /createOrderOnce/, 'El horario debe guardarse junto al pedido');
assert.match(driver, /\['accepted','preparing','ready_for_dispatch','picked_up','on_the_way','arrived'\]/, 'El repartidor debe compartir ubicación durante toda la asignación');
assert.match(admin, /cfg-pickup-prep/, 'El restaurante debe configurar el tiempo inicial de pickup');
assert.match(admin, /cfg-dine-in-prep/, 'El restaurante debe configurar el tiempo inicial de mesa');
assert.match(worker, /serveyourself-shell-v29/, 'La PWA debe invalidar la caché anterior');

console.log('OK: priorización ML, ETA y pickup programado validados.');
