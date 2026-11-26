import test from 'node:test';
import assert from 'node:assert/strict';
import runtime from '../runtime.js';
import detail from '../cash-shift-detail.js';

test('reconnect refreshes the same screen and keeps the last successful timestamp while offline', () => {
    const handlers = new Map();
    const addEventListener = (event, fn) => handlers.set(event, fn);
    const browser = {navigator:{onLine:true}, document:{hidden:false,addEventListener}, addEventListener};
    const status = {dataset:{}};
    let refreshes = 0;
    const sync = runtime.orderSync(status, () => refreshes++, browser);
    sync.success();
    sync.channel('SUBSCRIBED');
    assert.equal(refreshes,1);
    assert.match(status.textContent,/Pedidos sincronizados/);
    browser.navigator.onLine = false;
    handlers.get('offline')();
    assert.match(status.textContent,/Sin conexión.*Última actualización/);
    sync.refresh();
    assert.equal(refreshes,1);
    browser.navigator.onLine = true;
    handlers.get('online')();
    assert.equal(refreshes,2);
    sync.channel('CHANNEL_ERROR');
    sync.success();
    assert.match(status.textContent,/sincronización por consulta/);
    assert.equal(status.dataset.stale,'false');
});

test('a lost response cannot assign a new ID or payload to the pending customer order', async () => {
    const entries=new Map();
    const storage={getItem:k=>entries.get(k),setItem:(k,v)=>entries.set(k,v),removeItem:k=>entries.delete(k)};
    const calls=[];
    const adapter={rpc:async(_method,args)=>{
        calls.push(args);
        if(calls.length===1)throw Error('network error');
        return {data:{id:91}};
    }};
    await assert.rejects(runtime.createOrderOnce(adapter,storage,'order',{qty:1},()=> 'first',true));
    const result=await runtime.createOrderOnce(adapter,storage,'order',{qty:2},()=> 'duplicate',true);
    assert.equal(result.id,91);
    assert.deepEqual(calls[0],calls[1]);
});

test('pickup status never promises a second time when the estimate has already passed', () => {
    const restaurant={pickup_prep_minutes:15};
    const pending={status:'pendiente',payment_status:'pending',created_at:'2026-11-26T10:00:00Z'};
    assert.deepEqual(runtime.pickupProgress(pending,restaurant),{label:'Por pagar'});
    const paid={...pending,payment_status:'approved',payment_updated_at:'2026-11-26T10:00:00Z'};
    assert.match(runtime.pickupProgress(paid,restaurant,Date.parse('2026-11-26T10:19:00Z')).timing,/tardando/);
    assert.deepEqual(runtime.pickupProgress({...paid,status:'listo'},restaurant),{label:'Listo para recoger'});
});

test('shift detail separates electronic transactions, tips, withdrawals and refunds', () => {
    const created_at='2026-11-26T10:00:00Z';
    const rows=detail.shiftRows([{order_id:5,payment_method:'cash',amount:55,tip_amount:5,created_at}],[],
        [{reason:'Retiro',movement_type:'expense',amount:20,created_at}],
        [{order_id:7,event_type:'refunded',amount:90,happened_at:created_at}]);
    assert.deepEqual(Object.fromEntries(rows.map(row=>[row.group,row.amount])),{
        Efectivo:60,'Movimientos de caja':-20,'Reembolsos en Mercado Pago':-90
    });
});
