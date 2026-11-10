import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {createRequire} from 'node:module';
const runtime=createRequire(import.meta.url)('../runtime.js');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('refresh bursts run sequentially and process the newest update',async()=>{
 let release,calls=0,active=0,maximum=0;
 const gate=new Promise(resolve=>release=resolve);
 const refresh=runtime.serialRefresh(async()=>{calls++;active++;maximum=Math.max(maximum,active);if(calls===1)await gate;active--;});
 const first=refresh();refresh();refresh();await tick();
 assert.equal(calls,1);release();await first;
 assert.equal(calls,2);assert.equal(maximum,1);
 await refresh();assert.equal(calls,3);
});
test('refresh can recover after a failed query',async()=>{
 let calls=0;const refresh=runtime.serialRefresh(async()=>{if(++calls===1)throw Error('Offline');});
 await assert.rejects(refresh(),/Offline/);await refresh();assert.equal(calls,2);
});
test('cashier reload reuses the persisted operation after a lost payment response',async()=>{
 const stored=new Map();const storage={getItem:key=>stored.get(key),setItem:(key,value)=>stored.set(key,value),removeItem:key=>stored.delete(key)};
 let payments=0;const applied=new Map();
 const db={rpc:async(name,args)=>{assert.equal(name,'cashier_create_takeaway');if(!applied.has(args.p_request_id)){payments++;applied.set(args.p_request_id,{id:7,payment_status:'approved'});throw Error('Lost response');}return{data:applied.get(args.p_request_id)};}};
 const script=fs.readFileSync(new URL('../cashier-checkout.js',import.meta.url),'utf8');
 const first=vm.createContext({SYRuntime:runtime});vm.runInContext(script,first);
 await assert.rejects(first.createCashierOrderOnce(db,storage,'key',{p_method:'cash'}),/Lost response/);
 const reloaded=vm.createContext({SYRuntime:runtime});vm.runInContext(script,reloaded);
 assert.equal((await reloaded.createCashierOrderOnce(db,storage,'key',{p_method:'cash'})).id,7);
 assert.equal(payments,1);
});
test('a known validation rollback releases the cashier draft for correction',async()=>{
 const stored=new Map();const storage={getItem:key=>stored.get(key),setItem:(key,value)=>stored.set(key,value),removeItem:key=>stored.delete(key)};
 const ctx=vm.createContext({SYRuntime:runtime});vm.runInContext(fs.readFileSync(new URL('../cashier-checkout.js',import.meta.url),'utf8'),ctx);
 await assert.rejects(ctx.createCashierOrderOnce({rpc:async()=>({error:{code:'P0001',message:'Cash insufficient'}})},storage,'key',{}));
 assert.equal(stored.size,0);
});
test('cash collection retry recovers the original receipt even after the displayed amount changes',async()=>{
 const stored=new Map();const storage={getItem:key=>stored.get(key),setItem:(key,value)=>stored.set(key,value),removeItem:key=>stored.delete(key)};
 let charged=0;const requests=new Map();
 const db={rpc:async(_name,args)=>{if(!requests.has(args.p_request_id)){charged+=args.p_payload.p_amount;requests.set(args.p_request_id,{amount:args.p_payload.p_amount});throw Error('Lost response');}return{data:requests.get(args.p_request_id)};}};
 const ctx=vm.createContext({SYRuntime:runtime});vm.runInContext(fs.readFileSync(new URL('../cashier-checkout.js',import.meta.url),'utf8'),ctx);
 await assert.rejects(ctx.recordCashOperationOnce(db,storage,'key','order_payment',{p_amount:20}),/Lost response/);
 const result=await ctx.recordCashOperationOnce(db,storage,'key','order_payment',{p_amount:80});
 assert.equal(result.data.amount,20);assert.equal(result.recovered,true);assert.equal(charged,20);assert.equal(stored.size,0);
});
