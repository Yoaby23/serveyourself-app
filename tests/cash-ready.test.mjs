import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
const source = fs.readFileSync(new URL('../cash-ready.js', import.meta.url),'utf8');
const tick = () => new Promise(resolve=>setImmediate(resolve));
function setup() {
 const state={rows:[{id:7,order_id:42,items:[{qty:1,nombre:'<script>'}],orders:{pickup_name:'Ana <img>'}}],error:null,calls:0,fail:false};
 const elements=Object.fromEntries(['ready-pickup-list','ready-pickup-count','ready-pickup-notice'].map(id=>[id,{innerHTML:'',textContent:'',addEventListener(name,fn){this[name]=fn;}}]));
 const handlers={};let interval;
 const q={select(){return this;},eq(){return this;},neq(){return this;},order:async()=>({data:state.rows,error:state.error})};
 const db={from:()=>q,rpc:async()=>{state.calls++;await tick();if(state.fail)return{error:Error('Offline')};state.rows=[];return{};},channel:()=>({on(event,filter,fn){handlers[filter.table]=fn;return this;},subscribe(){}})};
 const window={serveYourself:{supabase:db,escapeHtml:x=>String(x).replaceAll('<','&lt;')},confirm:()=>true,alert:()=>{},addEventListener(){}};
 vm.runInNewContext(source,{window,document:{getElementById:id=>elements[id],addEventListener(){},hidden:false},setInterval:fn=>interval=fn});window.startCashReady({restaurant_id:'owner'});
 return {state,elements,handlers,poll:()=>interval(),click:()=>elements['ready-pickup-list'].click({target:{closest:()=>({dataset:{deliver:'7'}})}})};
}
test('cashier restores ready pickups with escaped name/items and keeps list on network failure',async()=>{
 const s=setup();await tick();assert.equal(s.elements['ready-pickup-count'].textContent,'1');assert.match(s.elements['ready-pickup-list'].innerHTML,/Ana &lt;img>/);assert.doesNotMatch(s.elements['ready-pickup-list'].innerHTML,/<script>/);
 s.state.error=Error('Offline');s.poll();await tick();assert.equal(s.elements['ready-pickup-count'].textContent,'1');assert.match(s.elements['ready-pickup-notice'].textContent,/reintentará/);
 s.state.error=null;s.state.rows=[];await s.handlers.kitchen_tickets();assert.equal(s.elements['ready-pickup-count'].textContent,'0');
});
test('cashier double-click delivers once and successful delivery removes the card',async()=>{
 const s=setup();await tick();await Promise.all([s.click(),s.click()]);assert.equal(s.state.calls,1);assert.equal(s.elements['ready-pickup-count'].textContent,'0');
});
test('failed delivery preserves the card and permits retry',async()=>{
 const s=setup();await tick();s.state.fail=true;await s.click();assert.equal(s.elements['ready-pickup-count'].textContent,'1');assert.doesNotMatch(s.elements['ready-pickup-list'].innerHTML,/ disabled/);s.state.fail=false;await s.click();assert.equal(s.state.calls,2);
});
async function push({kind='ticket',status='listo',claim=true,paid=true,customer=null}={}){
 let handler;const sent=[],filters=[];
 const event={id:'56782541-f0c9-4efd-9832-49ac767ca321',order_id:42,ticket_id:7,kind,state:status};
 const order={id:42,restaurant_id:'owner',restaurant_name:'Restaurante',order_source:'pos',created_by:'cashier',customer_id:customer,pickup_name:'Ana',service_type:'pickup',payment_before_kitchen:true,payment_status:paid?'approved':'pending',status};
 const db={rpc:async()=>({data:claim?[event]:[]}),from(table){const q={select(){return this;},update(){return this;},eq(k,v){filters.push([table,k,v]);return this;},maybeSingle:async()=>({data:table==='orders'?order:{id:7,status}}),then(resolve){resolve({data:[{user_id:'cashier'}]});}};return q;}};
 const code=fs.readFileSync(new URL('../supabase/functions/send-order-notification/index.ts',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
 vm.runInNewContext(stripTypeScriptTypes(code),{Deno:{env:{get:()=> 'test'},serve:fn=>handler=fn},createClient:()=>db,corsHeaders:()=>({}),jsonResponse:(req,body,status=200)=>Response.json(body,{status}),Response,crypto,TextEncoder,fetch:async(url,options)=>{sent.push(JSON.parse(options.body));return new Response('{"id":"accepted"}');}});
 const response=await handler(new Request('https://edge.test',{method:'POST',body:JSON.stringify({dispatchId:event.id})}));return{response,sent,filters};
}
test('ready pickup alerts owner and active cashiers, with one handoff per recipient',async()=>{
 const {response,sent,filters}=await push();assert.equal(response.status,200);assert.equal(sent.length,2);assert.deepEqual(sent.map(x=>x.include_aliases.external_id[0]).sort(),['cashier','owner']);assert.ok(sent.every(x=>x.url.endsWith('/caja.html#ready-pickup')&&x.contents.es.includes('Ana')));assert.ok(filters.some(x=>x[1]==='can_close_accounts'&&x[2]===true));
});
test('only committed, paid pickup tickets notify kitchen; repeat dispatch keys are stable',async()=>{
 assert.equal((await push({status:'pendiente',paid:false})).sent.length,0);assert.equal((await push({claim:false})).sent.length,0);
 const first=await push({status:'pendiente'}),retry=await push({status:'pendiente'});assert.ok(first.sent.every(x=>x.url.endsWith('/cocina.html')));assert.equal(first.sent.length,2);assert.deepEqual(first.sent.map(x=>x.idempotency_key),retry.sent.map(x=>x.idempotency_key));
});
test('pay-first pickup alerts caja while pending, then customer on approved payment',async()=>{
 assert.ok((await push({kind:'cashier',status:'pending',paid:false})).sent.every(x=>x.url.endsWith('/caja.html#pickup')));
 const result=await push({kind:'payment',status:'approved',customer:'buyer'});assert.equal(result.sent.length,1);assert.equal(result.sent[0].include_aliases.external_id[0],'buyer');
});
