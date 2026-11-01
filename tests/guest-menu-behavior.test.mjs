import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const code=fs.readFileSync(new URL('../guest-menu.js',import.meta.url),'utf8');
const token='a'.repeat(64), older='b'.repeat(64);
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function screen({enabled=true,query='',stored={},storageFails=false,createFails=false,pauseCreate=false,paymentMethod='mercado_pago',cashEnabled=false,onlineEnabled=true,orderStatus='pendiente',paymentStatus='pending'}={}){
 const elements=new Map(),calls=[],redirects=[];const storage=new Map(Object.entries(stored));let release;
 const gate=new Promise(resolve=>release=resolve);
 const element=id=>{if(!elements.has(id))elements.set(id,{value:'Ana',textContent:'',innerHTML:'',hidden:false,disabled:false,listeners:{},addEventListener(name,fn){this.listeners[name]=fn;}});return elements.get(id);};
 const restaurant={id:'rest',business_name:'Test',guest_pickup_enabled:enabled,accepting_orders:true,payment_cash:cashEnabled,payment_online:onlineEnabled};
 const order={id:42,restaurant_id:'rest',pickup_name:'Ana',items:[{nombre:'Comida',price:25,qty:1}],total:25,status:orderStatus,payment_status:paymentStatus,payment_method:paymentMethod};
 const db={from(name){const q={select(){return this;},eq(){return this;},order(){return this;},single:async()=>({data:restaurant}),then(resolve){resolve({data:[{id:'p',name:'Comida',price:25,category:'Comida'}]});}};return q;},functions:{async invoke(name,{body}){
  calls.push({name,body});
  if(body.action==='create'){if(pauseCreate)await gate;if(createFails)return {error:{message:'offline'}};return {data:{order,expired:false}};}
  if(body.action==='status')return {data:{order,expired:false}};
  return {data:{checkoutUrl:'https://www.mercadopago.com.mx/checkout/test'}};
 }}};
 const location={search:'?id=rest'+query,hash:'',pathname:'/menu-publico.html',href:'https://app.test/menu-publico.html?id=rest'+query,assign:url=>redirects.push(url)};
 vm.runInNewContext(code,{window:{serveYourself:{supabase:db,escapeHtml:s=>String(s??''),safeImageUrl:s=>s}},document:{getElementById:element,hidden:false,addEventListener(){}},location,history:{replaceState(){}},navigator:{clipboard:{writeText:async()=>{}}},localStorage:{getItem:k=>storage.get(k),setItem(k,v){if(storageFails)throw Error('Blocked');storage.set(k,v);},removeItem:k=>storage.delete(k)},URL,URLSearchParams,crypto,Uint8Array,Map,Set,console,setTimeout:()=>1,clearTimeout(){},confirm:()=>true});
 await tick();
 return {elements,storage,calls,redirects,release,add:()=>element('menu-content').listeners.click({target:{closest:()=>({dataset:{add:'p'}})}}),pay:()=>element('guest-checkout').listeners.submit({preventDefault(){}}),resume:()=>element('resume-payment').listeners.click()};
}
test('disabled restaurants show a read-only public menu',async()=>{const ui=await screen({enabled:false});assert.equal(ui.elements.get('guest-cart').hidden,true);assert.ok(!ui.elements.get('menu-content').innerHTML.includes('data-add'));});
test('guest checkout persists its capability before any request and prevents duplicate clicks',async()=>{
 const ui=await screen({pauseCreate:true});ui.add();ui.pay();ui.pay();await tick();
 assert.equal(ui.calls.length,1);const record=JSON.parse(ui.storage.get('sy-guest-checkout:rest'));assert.equal(record.token.length,64);assert.equal(ui.calls[0].body.token,record.token);
 ui.release();await tick();await tick();assert.equal(ui.redirects.length,1);assert.ok(ui.storage.has('sy-guest-receipt:rest:42'));
});
test('blocked storage prevents creating an unrecoverable guest order',async()=>{const ui=await screen({storageFails:true});ui.add();ui.pay();await tick();assert.equal(ui.calls.length,0);assert.equal(ui.redirects.length,0);});
test('an ambiguous creation failure retries the same token and payload',async()=>{
 const ui=await screen({createFails:true});ui.add();ui.pay();await tick();ui.resume();await tick();
 assert.equal(ui.calls.length,2);assert.deepEqual(ui.calls[0].body,ui.calls[1].body);assert.equal(ui.redirects.length,0);
});
test('payment=success never marks an unconfirmed order as paid',async()=>{
 const ui=await screen({query:'&payment=success',stored:{'sy-guest-checkout:rest':JSON.stringify({token,orderId:42})}});
 assert.match(ui.elements.get('receipt-details').innerHTML,/Esperando confirmación de pago/);assert.ok(!ui.elements.get('receipt-details').innerHTML.includes('Pago confirmado'));
});
test('returning to an older payment uses that receipt instead of the latest cart',async()=>{
 const ui=await screen({query:'&order_id=42',stored:{'sy-guest-checkout:rest':JSON.stringify({token,orderId:43}),'sy-guest-receipt:rest:42':JSON.stringify({token:older,orderId:42})}});
 assert.equal(ui.calls[0].body.token,older);
});

// Disconnecting Mercado Pago must not leave a checked, disabled option blocking all settings saves.
test('guest setting reflects effective payment availability after disconnect',()=>{
 const html=fs.readFileSync(new URL('../admin.html',import.meta.url),'utf8');
 const method=html.slice(html.indexOf('        function cargarConfiguracion('),html.indexOf('        function usarUbicacionActual'));
 for(const [connected,online,cash,expected] of [[false,true,false,false],[true,false,false,false],[true,true,false,true],[false,false,true,true]]){
  const elements=new Map();const get=id=>{if(!elements.has(id))elements.set(id,{classList:{toggle(){}}});return elements.get(id);};
  vm.runInNewContext(method+'cargarConfiguracion(profile)',{BusinessSettings:{load(){}},document:{getElementById:get},profile:{guest_pickup_enabled:true,mercado_pago_connected:connected,payment_online:online,payment_cash:cash}});
  assert.equal(get('cfg-guest-pickup').checked,expected);assert.equal(get('cfg-guest-pickup').disabled,false);
 }
});

test('cash pickup saves a pending request without opening Mercado Pago',async()=>{
 const ui=await screen({paymentMethod:'cash',cashEnabled:true,onlineEnabled:false});ui.add();ui.pay();await tick();
 assert.equal(ui.calls.length,1);assert.equal(ui.calls[0].body.paymentMethod,'cash');assert.equal(ui.redirects.length,0);
 assert.match(ui.elements.get('receipt-details').innerHTML,/Pendiente de pago en caja/);assert.equal(ui.elements.get('resume-payment').hidden,true);
});
test('cash choice is only rendered when the restaurant accepts it',async()=>{
 const ui=await screen();assert.ok(!ui.elements.get('guest-payment-method').innerHTML.includes('value="cash"'));
});
test('cancelled cash request stops offering payment and displays cancellation',async()=>{
 const ui=await screen({paymentMethod:'cash',orderStatus:'cancelado',stored:{'sy-guest-checkout:rest':JSON.stringify({token,orderId:42})}});
 assert.match(ui.elements.get('receipt-details').innerHTML,/Pedido cancelado/);assert.equal(ui.elements.get('resume-payment').hidden,true);
});
