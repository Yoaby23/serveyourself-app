import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
const html=fs.readFileSync(new URL('../restaurante.html',import.meta.url),'utf8');
test('a quote that completes after the address changes cannot re-enable an old delivery price',async()=>{
 const fn=html.slice(html.indexOf('        async function calculateQuote()'),html.indexOf('        function mostrarDatosTransferencia()'));let resolve;const nodes={textContent:''};
 const ctx=vm.createContext({document:{getElementById:()=>nodes},_supabase:{rpc:()=>new Promise(r=>resolve=r)},resId:'restaurant',actualizarModalCarrito(){throw Error('Stale quote must not update the UI');}});
 vm.runInContext("let serviceType='delivery',deliveryMarker={getLatLng:()=>({lat:19,lng:-99})},carrito=[{price:50,qty:1}],deliveryAddressLocation={point:()=>({latitude:19,longitude:-99})},deliveryQuoteRequest=0,deliveryQuote=null;"+fn,ctx);
 const pending=ctx.calculateQuote();vm.runInContext('deliveryQuoteRequest++;deliveryAddressLocation.point=()=>null;',ctx);resolve({data:{distance_km:1,delivery_fee:20,eta_minutes:30}});await pending;assert.equal(vm.runInContext('deliveryQuote',ctx),null);
});
