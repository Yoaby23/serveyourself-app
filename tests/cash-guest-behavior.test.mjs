import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { corsHeaders } from '../supabase/functions/_shared/cors.ts';
const cash=fs.readFileSync(new URL('../caja.html',import.meta.url),'utf8');
const guest={id:42,order_source:'online',service_type:'pickup',payment_before_kitchen:true,payment_method:'cash',total:50,items:[{nombre:'Comida',price:25,qty:2}],pickup_name:'Ana'};
const helper=cash.slice(cash.indexOf('        function isGuestCashOrder('),cash.indexOf('        function shiftTotals('));
const card=cash.slice(cash.indexOf('        function accountCard('),cash.indexOf('        function renderAccounts('));
test('guest cashier card uses the existing full cash payment form without table/credit controls',()=>{
 const context={payments:[],tables:[],waiters:[],creditCustomers:[],shift:{id:'shift'},esc:x=>String(x??''),money:x=>String(x),guest};
 vm.createContext(context);vm.runInContext(helper+card+'result=accountCard(guest)',context);
 assert.match(context.result,/COBRAR Y ENVIAR A COCINA/);assert.match(context.result,/readonly/);assert.match(context.result,/CANCELAR SOLICITUD/);
 assert.doesNotMatch(context.result,/DIVIDIR|CUPÓN|CERRAR A CRÉDITO|value="transfer"/);
});
test('cut blockers retain tables and partial pickup payments, but exclude zero-payment pickup',()=>{
 const context={payments:[{order_id:3,amount:10}],accounts:[guest,{id:2,order_source:'pos',service_type:'pickup'},{id:3,order_source:'pos',service_type:'pickup'},{id:4,order_source:'pos',service_type:'dine_in'}]};
 vm.createContext(context);vm.runInContext(helper+'result=openPosAccounts().map(o=>o.id)',context);assert.deepEqual(Array.from(context.result),[3,4]);
});
test('cash payment retries do not double-submit and a failure restores the button',async()=>{
 let release,calls=0;const gate=new Promise(r=>release=r);const alerts=[];
 const elements={'method-42':{value:'cash'},'amount-42':{value:'50'},'tip-42':{value:'0'},'received-42':{value:'100'}};
 const context=vm.createContext({document:{getElementById:id=>elements[id]},alert:m=>alerts.push(m),db:{rpc:async()=>{calls++;await gate;return {error:Error('Offline')};}},loadAll:async()=>{},money:String});
 const code=cash.slice(cash.indexOf('        const paymentsInFlight='),cash.indexOf('        async function sendToCredit'));
 vm.runInContext(code,context);context.button={disabled:false,textContent:'Cobrar'};
 const first=vm.runInContext('pay(42,button)',context);const second=vm.runInContext('pay(42,button)',context);release();await Promise.all([first,second]);
 assert.equal(calls,1);assert.equal(context.button.disabled,false);assert.equal(context.button.textContent,'Cobrar');assert.equal(alerts[0],'Offline');
});
async function webhook({required=true,failRefund=false}={}){
 let handler,refunds=0;
 const order={id:42,restaurant_id:'owner',customer_id:null,total:50,payment_method:'mercado_pago',payment_status:'pending',status:'pendiente',created_at:new Date().toISOString(),payment_expires_at:new Date(Date.now()+1200000).toISOString()};
 const admin={from(name){const q={select(){return this;},eq(){return this;},single:async()=>({data:order}),maybeSingle:async()=>({data:null})};return q;},auth:{getUser:async()=>({data:{user:{id:'owner'}}})},rpc:async()=>({data:required?{refund_required:true}:{payment_status:'approved'}})};
 globalThis.Deno={env:{get:key=>key==='APP_URL'?'https://app.test':'test'}};
 const source=fs.readFileSync(new URL('../supabase/functions/mercado-pago-webhook/index.ts',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
 vm.runInNewContext(stripTypeScriptTypes(source),{Deno:{env:globalThis.Deno.env,serve:fn=>handler=fn},URL,Request,Response,console:{log(){},error(){}},crypto,TextEncoder,Date,corsHeaders,createClient:()=>admin,getValidMercadoPagoToken:async()=> 'test',fetch:async()=>Response.json({id:789,external_reference:'42',transaction_amount:50,currency_id:'MXN',status:'approved',date_created:new Date().toISOString()}),refundOrder:async()=>{refunds++;if(failRefund)throw Error('Provider unavailable');}});
 const response=await handler(new Request('https://edge.test/?order_id=42&payment_id=789',{headers:{Authorization:'Bearer test'}}));return {response,refunds};
}
test('webhook honors database cut cancellation even when its initial read was stale',async()=>{
 const result=await webhook();assert.equal(result.refunds,1);assert.equal(result.response.status,200);assert.match(await result.response.text(),/closed-shift payment refunded/);
});
test('failed post-cut refund returns a retryable failure instead of acknowledging success',async()=>{
 const result=await webhook({failRefund:true});assert.equal(result.refunds,1);assert.equal(result.response.status,500);
});
test('normal payment approval does not trigger a cut refund',async()=>{
 const result=await webhook({required:false});assert.equal(result.refunds,0);assert.equal(result.response.status,200);
});
