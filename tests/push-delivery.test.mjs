import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';
import {webcrypto} from 'node:crypto';
const source=fs.readFileSync(new URL('../supabase/functions/send-order-notification/index.ts',import.meta.url),'utf8').replace(/^import .*;\n/gm,'');
test('an unsubscribed recipient does not block other staff and the app ID matches the installed client',async()=>{
 let handler, completed=false;
 const requests=[];
 const order={id:1,restaurant_id:'owner',customer_id:'customer',created_by:'waiter',order_source:'pos',service_type:'pickup',status:'cancelado',payment_status:'expired'};
 const db={rpc:async()=>({data:[{id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',order_id:1,kind:'order',state:'cancelado'}]}),from:table=>{
  const chain={select(){return chain;},eq(){return chain;},maybeSingle:async()=>({data:order}),update(){completed=true;return chain;},then(resolve){resolve({data:table==='restaurant_staff'?[{user_id:'staff'}]:null});}};
  return chain;
 }};
 vm.runInNewContext(stripTypeScriptTypes(source),{createClient:()=>db,Deno:{env:{get:()=>''},serve:fn=>handler=fn},console,crypto:webcrypto,TextEncoder,Response,Map,
 corsHeaders:()=>({}),jsonResponse:(_req,data,status=200)=>new Response(JSON.stringify(data),{status}),fetch:async(_url,options)=>{
  requests.push(JSON.parse(options.body));
  return new Response(JSON.stringify(requests.length===1?{errors:['All included players are not subscribed']}:{id:'notice'}),{status:200});
 }});
 const response=await handler(new Request('https://app.test',{method:'POST',body:JSON.stringify({dispatchId:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'})}));
 assert.equal(response.status,200);
 assert.equal(completed,true);
 assert.ok(requests.length>1);
 assert.ok(requests.some(r=>r.include_aliases.external_id.includes('staff')));
 for(const request of requests)assert.equal(request.app_id,'c77aa3bf-9fbf-4928-9441-18093c934dcd');
});
