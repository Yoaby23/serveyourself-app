import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const runtime = require('../runtime.js');
function storage() { const values = new Map(); return { getItem: key => values.get(key), setItem: (key, value) => values.set(key, value) }; }

test('lost order response reuses the same durable request ID', async () => {
    const saved = storage(); const serverOrders = new Map(); let calls = 0;
    const db = { async rpc(name, {p_request_id, p_payload}) {
        assert.equal(name,'create_customer_order_once');
        if (!serverOrders.has(p_request_id)) serverOrders.set(p_request_id,{id:serverOrders.size + 1,...p_payload});
        if (++calls === 1) throw new Error('Lost response');
        return {data:serverOrders.get(p_request_id)};
    }};
    await assert.rejects(runtime.createOrderOnce(db,saved,'checkout',{items:[1]},()=> 'request-1'),/Lost response/);
    assert.equal((await runtime.createOrderOnce(db,saved,'checkout',{items:[1]},()=> 'must-not-be-used')).id,1);
    assert.equal(serverOrders.size,1);
});
test('changed cart gets its own request, and unavailable storage stops before creating an order', async () => {
    const saved=storage(),ids=[];const db={async rpc(_,p){ids.push(p.p_request_id);return {data:{id:ids.length}};}};
    await runtime.createOrderOnce(db,saved,'key',{qty:1},()=> 'first');
    await runtime.createOrderOnce(db,saved,'key',{qty:2},()=> 'second');
    assert.deepEqual(ids,['first','second']);
    await assert.rejects(runtime.createOrderOnce(db,{getItem:()=>null,setItem(){throw new Error('Storage denied');}},'key',{},()=> 'third'));
    assert.equal(ids.length,2);
});
test('CSV neutralizes formulas including leading whitespace and escapes quoted values', () => {
    for (const value of ['=1+1','+SUM(A1:A2)','-1+2','@SUM(A1)','  =1','\t=1','\n=1']) assert.ok(runtime.csvCell(value).startsWith('"\''));
    assert.equal(runtime.csvCell('Yoab "Mesero"'),'"Yoab ""Mesero"""');
    assert.equal(runtime.csvCell(100),'"100"');
});
test('restaurant calendar date differs from UTC around midnight', () => {
    assert.equal(runtime.dateInZone(new Date('2026-10-27T03:00:00Z'),'America/Mexico_City'),'2026-10-26');
    assert.equal(runtime.dateInZone(new Date('2026-10-27T03:00:00Z'),'Asia/Tokyo'),'2026-10-27');
});
test('report reads all pages and rejects any missing page instead of presenting incomplete totals', async () => {
    const all=Array.from({length:1201},(_,id)=>({id}));
    assert.equal((await runtime.allRows(()=>({range:async(a,b)=>({data:all.slice(a,b+1)})}))).length,1201);
    await assert.rejects(runtime.allRows(()=>({range:async(a,b)=>a?{error:new Error('Network')}:{data:all.slice(a,b+1)}})),/Network/);
});
test('audio play resolves without an element and still pauses/reset correctly', async () => {
    const audio={currentTime:20,paused:false,async play(){},pause(){this.paused=true;}};
    await runtime.previewSound(audio);assert.equal(audio.paused,true);assert.equal(audio.currentTime,0);
});
function worker(fetcher, cached) {
    const events={},writes=[],deleted=[];
    vm.runInNewContext(fs.readFileSync(new URL('../sw.js',import.meta.url),'utf8'),{
        URL,Response,fetch:fetcher,console:{warn(){}},importScripts(){throw new Error('Push CDN unavailable');},
        self:{location:{origin:'https://app.test'},addEventListener:(name,fn)=>events[name]=fn,clients:{claim(){}},skipWaiting(){}},
        caches:{open:async()=>({put:async(...args)=>writes.push(args),addAll:async()=>{}}),match:async()=>cached,keys:async()=>['other-app-cache','serveyourself-shell-v18'],delete:async name=>deleted.push(name)}
    });
    return {events,writes,deleted,async request(path,mode='navigate'){
        const pending=[];let response;
        events.fetch({request:{method:'GET',url:`https://app.test${path}`,mode},waitUntil:p=>pending.push(p),respondWith:p=>response=p});
        const result=await response;await Promise.all(pending);return result;
    }};
}
test('push CDN failure does not disable own worker; HTTP errors do not replace valid cached resources', async () => {
    const sw=worker(async()=>new Response('broken',{status:500}));
    assert.ok(sw.events.install);assert.equal((await sw.request('/app.js','cors')).status,500);assert.equal(sw.writes.length,0);
});
test('offline missing JS never receives HTML; cached files still work; navigation has a clear offline message', async () => {
    const offline=async()=>{throw new Error('Offline');};
    const sw=worker(offline);const js=await sw.request('/runtime.js','cors');assert.equal(js.status,503);assert.match(js.headers.get('content-type'),/text\/plain/);
    assert.match(await (await sw.request('/missing.html')).text(),/Sin conexión/);
    const cached=worker(offline,new Response('cached JS'));assert.equal(await (await cached.request('/app.js','cors')).text(),'cached JS');
});
test('successful resources are cached and activation preserves other apps caches',async()=>{
    const sw=worker(async()=>new Response('OK'));await sw.request('/app.js','cors');assert.equal(sw.writes.length,1);
    let done;sw.events.activate({waitUntil:p=>done=p});await done;assert.deepEqual(sw.deleted,['serveyourself-shell-v18']);
});
