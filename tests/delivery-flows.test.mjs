import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const migration = read('supabase/migrations/015_delivery_suite.sql');
const store = read('restaurante.html');
const dispatch = read('delivery.html');
const driver = read('repartidor.html');
const tracking = read('delivery-tracking.html');
const preference = read('supabase/functions/create-mercado-pago-preference/index.ts');

for (const page of ['delivery.html', 'repartidor.html', 'delivery-tracking.html', 'restaurante.html']) {
  const html = read(page);
  for (const [index, match] of [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)].entries()) {
    assert.doesNotThrow(() => new Function(match[1]), `${page}: script ${index + 1} debe compilar`);
  }
}

assert.match(migration, /p_payment_method not in\('cash','mercado_pago'\)/, 'Delivery solo acepta efectivo o Mercado Pago en el servidor');
assert.match(migration, /calculate_delivery_quote/, 'La tarifa y la cobertura deben calcularse en el servidor');
assert.match(migration, /6371\*2\*asin/, 'La cobertura debe usar distancia geográfica');
assert.match(migration, /delivery_code/, 'Cada entrega debe tener código de confirmación');
assert.match(migration, /assigned_driver_id is distinct from auth\.uid\(\)/, 'Solo el repartidor asignado puede avanzar o entregar');
assert.match(migration, /payment_method='cash'.*payment_status.*'approved'/s, 'El efectivo se aprueba al confirmar la entrega');
assert.match(migration, /new\.service_type='delivery'.*new\.delivery_status not in/s, 'Cocina debe esperar aceptación y pago antes de recibir delivery');
assert.match(store, /Efectivo al entregar/, 'El cliente debe reconocer el cobro en efectivo al recibir');
assert.match(store, /create_delivery_order/, 'El pedido delivery debe usar la ruta segura dedicada');
assert.match(store, /serviceType !== 'delivery' && res\.payment_transfer/, 'Transferencia debe quedar excluida del modo delivery');
assert.match(dispatch, /accept_delivery_order/, 'Despacho debe aceptar o rechazar pedidos');
assert.match(dispatch, /assign_delivery_driver/, 'Despacho debe asignar repartidores');
assert.match(driver, /advance_delivery_order/, 'El repartidor debe avanzar el trayecto');
assert.match(driver, /confirm_delivery/, 'La entrega debe cerrarse con código');
assert.match(tracking, /updateMap/, 'El cliente debe ver el seguimiento');
assert.match(preference, /delivery-fee/, 'Mercado Pago debe incluir la tarifa de envío');
assert.match(read('sw.js'), /delivery\.html.*repartidor\.html.*delivery-tracking\.html/, 'La PWA debe precargar las pantallas de delivery');

console.log('Validación de delivery, cobros, despacho y seguimiento: OK');
