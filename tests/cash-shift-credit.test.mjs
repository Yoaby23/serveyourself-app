import assert from 'node:assert/strict';
import fs from 'node:fs';

const read = path => fs.readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const sql = read('supabase/migrations/018_real_cash_shift_and_customer_credit.sql');
const cash = read('caja.html');
const pos = read('pos.html');
const customers = read('clientes.html');
const reports = read('reportes.html');

assert.match(sql, /before insert or update of items,total,table_id on public\.orders/, 'Toda comanda POS debe quedar protegida por base de datos');
assert.match(sql, /Caja cerrada: abre un turno antes de enviar comandas/, 'Una comanda sin turno debe rechazarse claramente');
assert.match(sql, /payment_status='pending'[\s\S]*Cierra o pasa a credito antes del corte/, 'El corte debe bloquear cuentas abiertas');
assert.match(sql, /v_shift\.opening_cash\+v_cash\+v_credit_cash\+v_movements/, 'El efectivo esperado debe incluir fondo, ventas, cobranza y movimientos');
assert.match(sql, /credit_collections_transfer/, 'El corte debe conservar cobranza por transferencia');
assert.match(sql, /credit_collections_card/, 'El corte debe conservar cobranza por terminal');
assert.match(sql, /customer_credit_one_charge_per_order/, 'Una cuenta no debe cargarse dos veces a crédito');
assert.match(sql, /v_balance\+v_charge>v_customer\.credit_limit/, 'La base debe respetar el límite de crédito');
assert.match(sql, /p_amount>v_balance/, 'Un abono no debe superar la deuda del cliente');
assert.match(sql, /payment_status='on_credit'/, 'Una venta a crédito debe distinguirse de una venta pagada');
assert.match(sql, /v_balance-p_amount<=0[\s\S]*payment_status='approved'/, 'Al liquidar la cartera deben quedar saldadas sus ventas a crédito');

assert.match(pos, /get_pos_shift_status/, 'Meseros deben sincronizar el estado de Caja');
assert.match(pos, /if\(!await checkShiftStatus\(\)\)/, 'El turno debe comprobarse nuevamente antes de enviar');
assert.match(cash, /get_open_cash_shift_summary/, 'El resumen de corte debe calcularse en Supabase');
assert.match(cash, /No puedes cerrar el turno/, 'Caja debe explicar qué cuentas faltan por cerrar');
assert.match(cash, /record_customer_credit_payment/, 'Caja debe registrar la cobranza de clientes');
assert.match(customers, /set_customer_credit_settings/, 'El dueño debe autorizar el crédito y su límite');
assert.match(reports, /\['approved','on_credit'\]/, 'Los reportes deben reconocer ventas cerradas a crédito');
assert.match(reports, /VENTAS A CRÉDITO/, 'Los reportes deben separar las ventas a crédito');
assert.match(reports, /COBRANZA/, 'Los reportes deben mostrar los abonos recuperados');

console.log('Validación de turno real, corte y crédito de clientes: OK');
