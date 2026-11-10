import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
const source=fs.readFileSync(new URL('../pickup-arrival.js',import.meta.url),'utf8');
function setup({permission='granted',accuracy=10,handler=null}={}){
 const store=new Map(),events={},windowEvents={},calls=[],status={},button={setAttribute(){}};let locates=0,timer=null,clears=0;
 const select={value:'car'},box={dataset:{pickupArrival:'1'},querySelector:s=>s==='[data-share-pickup]'?button:s==='[data-pickup-transport]'?select:status};
 const root={visibilityState:'visible',querySelectorAll:()=>[box],addEventListener:(name,fn)=>events[name]=fn};
 const geo={getCurrentPosition(ok){locates++;ok({coords:{latitude:20,longitude:-103,accuracy},timestamp:Date.now()});}};
 const window={addEventListener:(name,fn)=>windowEvents[name]=fn};const navigator={geolocation:geo,permissions:{query:async()=>({state:permission})}};
 vm.runInNewContext(source,{window,navigator,document:root,Date,localStorage:{},setInterval:fn=>{timer=fn;return 1;},clearInterval:()=>{timer=null;clears++;}});
 const control=window.SYPickupArrival.create({db:{rpc:async(name,args)=>{calls.push({name,args});return handler?handler(name,args):{data:{eta_minutes:8}};}},root,geo,permissions:navigator.permissions,storage:{getItem:k=>store.get(k),setItem:(k,v)=>store.set(k,v),removeItem:k=>store.delete(k)}});
 return{control,events,windowEvents,calls,status,store,root,select,box,stats:()=>({locates,timer,clears}),eligible:window.SYPickupArrival.eligible};
}
const order={id:1,service_type:'pickup',scheduled_for:'2026-11-11T12:00:00Z',payment_status:'approved',status:'pendiente'};
const flush=()=>new Promise(r=>setImmediate(r));
test('only paid active scheduled pickup offers arrival sharing',()=>{const s=setup();assert.equal(s.eligible(order),true);for(const extra of [{scheduled_for:null},{payment_status:'pending'},{status:'entregado'},{service_type:'delivery'}])assert.equal(s.eligible({...order,...extra}),false);});
test('order loading never requests location until the customer chooses to share',async()=>{const s=setup();await s.control.setOrders([order]);assert.equal(s.stats().locates,0);assert.equal(s.calls.length,0);});
test('sharing sends observed coordinates to the server and labels arrival as approximate',async()=>{const s=setup();await s.control.setOrders([order]);await s.control.start(1);await flush();assert.deepEqual(s.calls.map(c=>c.name),['set_pickup_location_sharing','update_pickup_arrival']);assert.equal(s.calls[1].args.p_accuracy,10);assert.match(s.status.textContent,/aproximada en 8 min/);await s.control.stop();assert.equal(s.calls.at(-1).args.p_enabled,false);assert.equal(s.stats().timer,null);});
test('imprecise GPS fixes are never sent as trusted arrival data',async()=>{const s=setup({accuracy:500});await s.control.setOrders([order]);await s.control.start(1);await flush();assert.equal(s.calls.filter(c=>c.name==='update_pickup_arrival').length,0);assert.match(s.status.textContent,/suficientemente precisa/);});
test('restoring consent never raises another native prompt when browser permission is missing',async()=>{const s=setup({permission:'prompt'});s.store.set('sy-pickup-arrival-order','1');await s.control.setOrders([order]);assert.equal(s.stats().locates,0);assert.equal(s.calls.length,0);});
test('backgrounding pauses GPS and completion stops the tracking timer',async()=>{const s=setup();await s.control.setOrders([order]);await s.control.start(1);await flush();s.root.visibilityState='hidden';s.events.visibilitychange();assert.equal(s.stats().timer,null);await s.control.setOrders([{...order,status:'entregado'}]);assert.equal(s.store.has('sy-pickup-arrival-order'),false);});
test('travel choice persists across order-card refreshes instead of resetting to car',async()=>{const s=setup();await s.control.setOrders([order]);s.select.value='walking';s.events.change({target:{matches:()=>true,closest:()=>s.box,value:'walking'}});await s.control.setOrders([order]);assert.equal(s.select.value,'walking');});
