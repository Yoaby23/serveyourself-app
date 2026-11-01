import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../caja.html',import.meta.url),'utf8');
const layout=fs.readFileSync(new URL('../cash-layout.js',import.meta.url),'utf8');
test('cashier sections restore URL state and push link opens the delivery panel',()=>{
 const keys=['pickup','tables','online','credit','shift'];
 const tabs=keys.map(key=>({dataset:{cashTab:key},setAttribute(){this.active=true;},removeAttribute(){this.active=false;}}));
 const panels=keys.map(key=>({dataset:{cashPanel:key}}));
 let change,scrolled=false;const window={location:{hash:'#credit'},addEventListener:(event,fn)=>change=fn};
 vm.runInNewContext(layout,{window,document:{querySelectorAll:selector=>selector==='[data-cash-tab]'?tabs:panels,getElementById:()=>({scrollIntoView(){scrolled=true;}})}});
 assert.equal(panels.filter(x=>!x.hidden)[0].dataset.cashPanel,'credit');
 window.location.hash='#ready-pickup';change();assert.equal(panels.filter(x=>!x.hidden)[0].dataset.cashPanel,'pickup');assert.equal(scrolled,true);
 window.location.hash='#tables';change();assert.equal(tabs.filter(x=>x.active)[0].dataset.cashTab,'tables');
});
test('pickup and table accounts render once in their own payment sections',()=>{
 const elements={};const accounts=[{id:1,service_type:'pickup'},{id:2,service_type:'dine_in'},{id:3,service_type:'pickup'}];
 const context={accounts,accountCard:o=>`order-${o.id};`,document:{getElementById:id=>elements[id]??=( {})}};
 const code=html.slice(html.indexOf('        function renderAccounts()'),html.indexOf('        function renderCashSummary()'));
 vm.runInNewContext(code+'renderAccounts()',context);
 assert.equal(elements['pickup-accounts'].innerHTML,'order-1;order-3;');assert.equal(elements.accounts.innerHTML,'order-2;');assert.equal(elements['pickup-account-count'].textContent,2);
});
const pos=fs.readFileSync(new URL('../pos.html',import.meta.url),'utf8');
const posCode=[...pos.matchAll(/<script(?![^>]*src)[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]).join('\n').replace(/init\(\);\s*$/,'');
test('cashier pickup returns to Caja and does not fetch waiter table accounts',async()=>{
 const elements=new Map();const el=id=>{if(!elements.has(id))elements.set(id,{innerHTML:'',value:'',classList:{add(){},toggle(){},remove(){},contains(){return true;}},addEventListener(){}});return elements.get(id);};
 let destination,calls=0;
 const context=vm.createContext({URLSearchParams,Map,Set,console,document:{getElementById:el,addEventListener(){}},window:{location:{search:'?from=caja',assign:url=>destination=url},serveYourself:{supabase:{rpc:async()=>{calls++;return{data:[]};}},escapeHtml:String},addEventListener(){},scrollTo(){}},setTimeout,clearTimeout});
 vm.runInContext(posCode,context);vm.runInContext("access={restaurant_id:'r'}",context);
 await vm.runInContext('refreshAccounts()',context);await vm.runInContext('loadReady()',context);assert.equal(calls,0);
 vm.runInContext('showTables()',context);assert.equal(destination,'caja.html#pickup');
});
