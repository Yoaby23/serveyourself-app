import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const migration = read('supabase/migrations/015_delivery_suite.sql');
const marketplace = read('supabase/migrations/016_driver_marketplace_and_table_accounts.sql');
const store = read('restaurante.html');
const dispatch = read('delivery.html');
const driver = read('repartidor.html');
const tracking = read('delivery-tracking.html');
const preference = read('supabase/functions/create-mercado-pago-preference/index.ts');
const driverRegistration = read('repartidor-registro.html');
const app = read('app.js');
const menu = read('menu.html');
const index = read('index.html');
const readiness = read('supabase/migrations/021_production_readiness.sql');
const refund = read('supabase/functions/refund-mercado-pago-payment/index.ts');

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
assert.match(store, /createOrderOnce/, 'El pedido delivery debe usar la ruta segura dedicada');
assert.match(store, /serviceType !== 'delivery' && res\.payment_transfer/, 'Transferencia debe quedar excluida del modo delivery');
assert.match(dispatch, /accept_delivery_order/, 'Despacho debe aceptar o rechazar pedidos');
const cashDispatch=read('cash-dispatch.js');
const assignedDelivery=read('supabase/migrations/20261110060000_cashier_assigned_delivery.sql');
assert.match(cashDispatch,/assign_delivery_driver/,'Caja debe asignar la entrega');
assert.match(cashDispatch,/list_delivery_drivers/,'Caja debe consultar su equipo de reparto');
assert.doesNotMatch(driver,/claim_delivery_order|dismiss_delivery_offer|release_delivery_order/,'El repartidor no debe aceptar, rechazar ni liberar asignaciones');
assert.match(assignedDelivery,/Solo caja puede asignar repartidores/,'La asignación debe validarse en el servidor');
assert.match(driver, /advance_delivery_order/, 'El repartidor debe avanzar el trayecto');
assert.match(driver, /confirm_delivery/, 'La entrega debe cerrarse con código');
assert.match(driver, /assigned_driver_id=eq/, 'El repartidor debe escuchar sus entregas asignadas');
assert.match(driver, /setInterval\(\(\)=>\{if\(!document\.hidden&&navigator\.onLine\)load\(true\)\},5000\)/, 'El repartidor debe conservar una sincronización de respaldo');
assert.match(driver, /driver-bottom-nav/, 'La experiencia de reparto debe tener navegación móvil propia');
assert.match(driver, /startTracking/, 'La ubicación debe continuar compartiéndose durante la ruta');
assert.match(driverRegistration, /data&&!editing[\s\S]*repartidor\.html/, 'Un repartidor ya registrado no debe capturar sus datos nuevamente');
assert.match(driverRegistration, /select\('full_name,phone'\)/, 'El primer registro debe aprovechar los datos de la cuenta');
assert.match(app + menu, /Modo repartidor/, 'Los accesos existentes deben abrir directamente el modo repartidor');
assert.doesNotMatch(index, /Quiero repartir/, 'El alta de repartidores se realiza desde Equipo');
assert.doesNotMatch(index, />Soy repartidor</, 'La portada no debe duplicar el acceso de repartidor fuera de Crear cuenta');
assert.match(readiness, /max_active_orders=1/, 'La plataforma debe limitar a una entrega activa');
assert.match(readiness, /delivery_code_attempts[\s\S]*interval '15 minutes'/, 'El código de entrega debe limitar intentos');
assert.match(readiness, /delivery_driver_ledger/, 'Las ganancias y el efectivo deben quedar en un libro contable');
assert.match(read('supabase/functions/_shared/refunds.ts'), /\/refunds/, 'Los pedidos pagados que se cancelan deben reembolsarse');
assert.match(tracking, /updateMap/, 'El cliente debe ver el seguimiento');
assert.match(preference, /delivery-fee/, 'Mercado Pago debe incluir la tarifa de envío');
assert.match(read('sw.js'), /delivery\.html.*repartidor\.html.*delivery-tracking\.html/, 'La PWA debe precargar las pantallas de delivery');

console.log('Validación de delivery, cobros, despacho y seguimiento: OK');
