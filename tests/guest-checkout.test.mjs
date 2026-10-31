import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { sha256, validGuestToken, guestOrderId } from '../supabase/functions/_shared/guest-access.ts';
import { corsHeaders, jsonResponse } from '../supabase/functions/_shared/cors.ts';
const token='a'.repeat(64);
const freshOrder=()=>({id:42,customer_id:null,restaurant_id:'restaurant',items:[{id:'p',nombre:'Comida',qty:2,price:25}],total:50,delivery_fee:0,service_type:'pickup',payment_method:'mercado_pago',payment_status:'pending',created_at:new Date().toISOString(),payment_expires_at:new Date(Date.now()+1200000).toISOString()});
globalThis.Deno={env:{get:key=>key==='APP_URL'?'https://app.test':'test-value'}};
async function setup({file='create-mercado-pago-preference',order=freshOrder(),found=true,saveError=false,user=null,age=0}={}){
 let handler;const calls=[],provider=[];
 const table=name=>{
  const q={filters:{},select(){return this;},eq(k,v){this.filters[k]=v;return this;},update(value){this.write=value;calls.push({name,write:value});return this;},
   async maybeSingle(){return {data:found&&this.filters.token_hash===await sha256(token)?{order_id:42,created_at:new Date(Date.now()-age).toISOString()}:null};},
   async single(){if(this.write)return saveError?{error:{message:'save failed'}}:{data:{id:42}};return {data:order};}
  };calls.push({name});return q;
 };
 const client={from:table,auth:{getUser:async()=>({data:{user},error:user?null:new Error('invalid')})},rpc:async(name,args)=>{calls.push({rpc:name,args});return {data:{id:42}};}};
 const source=fs.readFileSync(new URL(`../supabase/functions/${file}/index.ts`,import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
 const context={Deno:{serve:fn=>handler=fn,env:globalThis.Deno.env},Request,Response,URL,TextEncoder,crypto,console,Date,
  createClient:()=>client,guestOrderId,sha256,validGuestToken,corsHeaders,jsonResponse,
  getValidMercadoPagoToken:async()=> 'test-provider-token',
  fetch:async(url,opts)=>{provider.push({url,opts});return Response.json({id:'pref-42',init_point:'https://www.mercadopago.com.mx/checkout/test'});}
 };
 vm.runInNewContext(stripTypeScriptTypes(source),context);
 return {calls,provider,request:(body,headers={})=>handler(new Request('https://edge.test/',{method:'POST',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(body)}))};
}
test('guest capability validation accepts only 256-bit hex tokens',async()=>{
 assert.equal(validGuestToken(token),true);for(const bad of [null,'abc','g'.repeat(64),'a'.repeat(63),42])assert.equal(validGuestToken(bad),false);
 assert.equal((await sha256(token)).length,64);assert.notEqual(await sha256(token),token);
});
test('unknown guest token cannot inspect an order or start checkout',async()=>{
 const f=await setup({found:false});const response=await f.request({orderId:42,guestToken:token});assert.equal(response.status,404);assert.equal(f.provider.length,0);assert.ok(!f.calls.some(c=>c.name==='orders'));
});
test('valid guest token cannot be paired with another order id',async()=>{
 const f=await setup();assert.equal((await f.request({orderId:99,guestToken:token})).status,404);assert.equal(f.provider.length,0);
});
test('guest access expires after seven days',async()=>{
 const f=await setup({age:8*86400000});assert.equal((await f.request({orderId:42,guestToken:token})).status,404);
});
test('guest checkout uses server prices, omits account payer and returns to the public menu',async()=>{
 const f=await setup();const response=await f.request({orderId:42,guestToken:token,total:0.01});assert.equal(response.status,200);
 const body=JSON.parse(f.provider[0].opts.body);assert.equal(body.items[0].unit_price,25);assert.equal(body.items[0].quantity,2);assert.equal(body.payer,undefined);
 assert.match(body.back_urls.success,/menu-publico.html.*id=restaurant/);assert.ok(!JSON.stringify(body).includes(token));assert.equal(body.external_reference,'42');assert.equal(f.provider[0].opts.headers['X-Idempotency-Key'],'order-42');
});
test('authenticated checkout still requires the actual customer session',async()=>{
 const f=await setup({order:{...freshOrder(),customer_id:'owner'},user:{id:'stranger',email:'other@example.invalid'}});
 assert.equal((await f.request({orderId:42})).status,401);
 assert.equal((await f.request({orderId:42},{Authorization:'Bearer test'})).status,404);assert.equal(f.provider.length,0);
});
test('authenticated customer checkout retains delivery and payer flow',async()=>{
 const f=await setup({order:{...freshOrder(),customer_id:'owner',service_type:'delivery',delivery_fee:10,total:60},user:{id:'owner',email:'owner@example.invalid'}});
 assert.equal((await f.request({orderId:42},{Authorization:'Bearer test'})).status,200);
 const body=JSON.parse(f.provider[0].opts.body);assert.equal(body.payer.email,'owner@example.invalid');assert.equal(body.items[1].id,'delivery-fee');assert.match(body.back_urls.success,/delivery-tracking.html/);
});
test('paid orders do not generate another checkout',async()=>{
 const f=await setup({order:{...freshOrder(),payment_status:'approved'}});assert.equal((await f.request({orderId:42,guestToken:token})).status,409);assert.equal(f.provider.length,0);
});
test('existing preference is recovered instead of posted again',async()=>{
 const f=await setup({order:{...freshOrder(),mercado_pago_preference_id:'existing'}});assert.equal((await f.request({orderId:42,guestToken:token})).status,200);assert.equal(f.provider.length,1);assert.ok(!f.provider[0].opts.method);assert.match(f.provider[0].url,/existing$/);
});
test('checkout persistence failure is visible and does not return a payment link',async()=>{
 const f=await setup({saveError:true});const response=await f.request({orderId:42,guestToken:token});assert.equal(response.status,500);assert.equal((await response.json()).checkoutUrl,undefined);
});
test('guest endpoint rejects unknown tokens and unsupported actions without reading orders',async()=>{
 const f=await setup({file:'guest-pickup',found:false});assert.equal((await f.request({action:'status',token})).status,404);assert.equal((await f.request({action:'approve',token})).status,400);assert.ok(!f.calls.some(c=>c.name==='orders'));
});
test('guest creation sends only validated payload fields and hashes capabilities',async()=>{
 const f=await setup({file:'guest-pickup'});const response=await f.request({action:'create',token,restaurantId:'restaurant',items:[{id:'p',qty:2}],name:'Ana',payment_status:'approved',total:1});assert.equal(response.status,200);
 const call=f.calls.find(c=>c.rpc);assert.equal(call.args.p_token_hash,await sha256(token));assert.equal(call.args.p_name,'Ana');assert.equal(call.args.payment_status,undefined);assert.equal(call.args.total,undefined);assert.equal(response.headers.get('cache-control'),'no-store');
});
