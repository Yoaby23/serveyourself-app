import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
const page=fs.readFileSync(new URL('../platform-admin.html',import.meta.url),'utf8');
const init=page.slice(page.indexOf('async function init()'),page.indexOf('async function load()'));
async function setup({allowed=true,error=null,role='owner'}={}){
 let destination=null,nav=null,loaded=0;const elements=new Map();const get=id=>{if(!elements.has(id))elements.set(id,{});return elements.get(id);};
 const access={staff_role:role};const app={requireUser:async()=>({id:'u'}),getRestaurantAccess:async()=>access,restaurantHome:a=>a.staff_role==='owner'?'funciones.html':'caja.html',renderRestaurantNavigation:a=>nav=a.staff_role,renderBottomNavigation:()=>nav='personal'};
 const context=vm.createContext({window:{serveYourself:app},document:{getElementById:get},db:{rpc:async()=>({data:allowed,error})},location:{replace:url=>destination=url},load:async()=>loaded++});vm.runInContext(init,context);await context.init();return{destination,nav,loaded,get};
}
test('platform administrators retain their restaurant navigation',async()=>{const s=await setup();assert.equal(s.nav,'owner');assert.equal(s.loaded,1);assert.equal(s.destination,null);});
test('denied platform access returns an owner to restaurant functions',async()=>{const s=await setup({allowed:false});assert.equal(s.destination,'funciones.html');assert.equal(s.loaded,0);});
test('platform permission lookup failure stays in place with a retry',async()=>{const s=await setup({allowed:null,error:{message:'network'}});assert.equal(s.destination,null);assert.equal(s.get('platform-retry').hidden,false);assert.equal(s.loaded,0);});
