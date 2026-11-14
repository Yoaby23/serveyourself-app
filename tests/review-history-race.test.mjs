import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
const html=fs.readFileSync(new URL('../menu.html',import.meta.url),'utf8');const code=html.slice(html.indexOf('        let historyLoadVersion=0;'),html.indexOf('        function tiempoRestantePago('));
test('a late old history response never replaces newer orders and refresh keeps the current view visible',async()=>{
 const gates=[];for(let i=0;i<2;i++){let resolve;const p=new Promise(r=>resolve=r);gates.push({p,resolve});}let count=0;
 const db={rpc:async()=>({}),from:table=>({select(){return this;},eq(){return table==='ratings'?Promise.resolve({data:[]}):this;},gte(){return this;},order(){return gates[count++].p;}})};
 const container={innerHTML:'Existing orders',dataset:{loaded:'true'}};const ctx=vm.createContext({_supabase:db,currentUser:{id:'u'},Date,Map,Number,window:{SYPickupArrival:{eligible:()=>false}},escapeHtml:String,document:{getElementById:()=>container},pickupArrival:{setOrders:async()=>{}}});vm.runInContext(code,ctx);
 const first=vm.runInContext('cargarHistorialPedidos()',ctx),second=vm.runInContext('cargarHistorialPedidos()',ctx);await new Promise(r=>setImmediate(r));assert.equal(container.innerHTML,'Existing orders');
 const order={id:1,restaurant_name:'New restaurant',items:[],total:10,payment_method:'cash',payment_status:'approved',status:'entregado',created_at:new Date().toISOString()};gates[1].resolve({data:[order],error:null});await second;assert.match(container.innerHTML,/New restaurant/);gates[0].resolve({data:[],error:null});await first;assert.match(container.innerHTML,/New restaurant/);
});
test('realtime location updates do not repeatedly announce the same ready pickup',()=>{
 const start=html.indexOf('        const readyOrderNotifications=');const end=html.indexOf('        async function conciliarRetornoMercadoPago()',start);let callback;const alerts=[];
 const channel={on(type,filter,fn){callback=fn;return this;},subscribe(){}};const ctx=vm.createContext({Set,String,currentUser:{id:'u'},_supabase:{channel:()=>channel},document:{getElementById:()=>({classList:{contains:()=>true}})},alert:m=>alerts.push(m)});vm.runInContext(html.slice(start,end)+'activarPedidosRealtime();',ctx);callback({new:{id:7,status:'listo'}});callback({new:{id:7,status:'listo'}});assert.equal(alerts.length,1);callback({new:{id:8,status:'listo'}});assert.equal(alerts.length,2);
});
