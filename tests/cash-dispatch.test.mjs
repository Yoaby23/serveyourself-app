import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {createRequire} from 'node:module';
const runtime=createRequire(import.meta.url)('../runtime.js');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('cashier assigns from its team once while the driver view has no acceptance controls',async()=>{
 const row={id:7,delivery_status:'accepted',delivery_contact_name:'Ana <img>',payment_method:'cash',payment_status:'not_required'};
 let assignCalls=0,release;
 const gate=new Promise(resolve=>release=resolve);
 const list={innerHTML:'',addEventListener(_name,fn){this.click=fn;},querySelector:()=>({value:'driver'})},status={};
 const query={select(){return this;},eq(){return this;},neq(){return this;},in(){return this;},order(){return this;},range:async()=>({data:[row]})};
 const db={from:()=>query,channel:()=>({on(){return this;},subscribe(){}}),rpc:async(name,args)=>{
  if(name==='list_delivery_drivers')return{data:[{user_id:'driver',full_name:'Luis',is_available:true,active_orders:0}]};
  assert.equal(name,'assign_delivery_driver');assert.equal(args.p_driver_id,'driver');assignCalls++;await gate;
  row.assigned_driver_id='driver';row.assigned_driver_name='Luis';return{data:row};
 }};
 const window={serveYourself:{supabase:db,escapeHtml:text=>String(text).replaceAll('<','&lt;')},addEventListener(){}};
 vm.runInNewContext(fs.readFileSync(new URL('../cash-dispatch.js',import.meta.url),'utf8'),{window,SYRuntime:runtime,document:{hidden:false,getElementById:id=>id==='dispatch-orders'?list:status,addEventListener(){}},setInterval(){}});
 window.startCashDispatch({restaurant_id:'owner'});await tick();
 assert.match(list.innerHTML,/Ana &lt;img>/);assert.match(list.innerHTML,/ASIGNAR ENTREGA/);
 const button={dataset:{order:'7',action:'assign'}};
 const event={target:{closest:()=>button}};
 const first=list.click(event),second=list.click(event);release();await Promise.all([first,second]);
 assert.equal(assignCalls,1);assert.match(list.innerHTML,/Repartidor · Luis/);
 const driver=fs.readFileSync(new URL('../repartidor.html',import.meta.url),'utf8');
 assert.doesNotMatch(driver,/ACEPTAR PEDIDO|RECHAZAR POR AHORA|LIBERAR PEDIDO|claim_delivery_order/);
});
test('assigned route remains visible in the driver home',()=>{
 const source=fs.readFileSync(new URL('../repartidor.html',import.meta.url),'utf8');
 assert.doesNotMatch(source, /id="active-section" class="[^"]*hidden/);
 const nodes={'active-count':{},orders:{}};
 const start=source.indexOf('function render(){');
 const code=source.slice(start,source.indexOf('function emptyState(',start));
 vm.runInNewContext(code+'render()',{orders:[{id:4}],document:{getElementById:id=>nodes[id]},activeCard:order=>'Assigned '+order.id,updateMap(){}});
 assert.equal(nodes.orders.innerHTML,'Assigned 4');assert.equal(nodes['active-count'].textContent,1);
});
