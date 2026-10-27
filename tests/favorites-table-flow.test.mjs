import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import {createRequire} from 'node:module';
const runtime=createRequire(import.meta.url)('../runtime.js');
test('favorites are only updated after server confirmation and removal persists',async()=>{
 const favorites=new Set();const calls=[];
 const db={async rpc(name,params){calls.push({name,...params});return {data:params.p_favorite};}};
 await runtime.setFavorite(db,favorites,'restaurant-1',true);assert.equal(favorites.has('restaurant-1'),true);
 await runtime.setFavorite(db,favorites,'restaurant-1',false);assert.equal(favorites.size,0);
 assert.equal(calls[0].name,'set_restaurant_favorite');
 await assert.rejects(runtime.setFavorite({rpc:async()=>({error:new Error('Offline')})},favorites,'restaurant-1',true));
 assert.equal(favorites.size,0);
});
const html=fs.readFileSync(new URL('../pos.html',import.meta.url),'utf8');
const code=[...html.matchAll(/<script(?![^>]*src)[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]).join('\n').replace(/init\(\);\s*$/,'');
function waiterScreen(rows,{error=false,open=true}={}){
 const elements=new Map();const element=id=>{if(!elements.has(id))elements.set(id,{innerHTML:'',textContent:'',value:'',classList:{add(){},toggle(){},remove(){},contains(){return false;}},addEventListener(){}});return elements.get(id);};
 const alerts=[];let summaries=0;
 const context=vm.createContext({Map,Set,console,Number,setTimeout,clearTimeout,document:{getElementById:element,addEventListener(){}},window:{serveYourself:{supabase:{async rpc(name){if(name==='get_pos_shift_status')return {data:{is_open:open}};summaries++;return error?{error:{message:'Offline'}}:{data:rows};}},escapeHtml:v=>v},scrollTo(){},addEventListener(){}},alert:message=>alerts.push(message)});
 vm.runInContext(code,context);
 vm.runInContext("access={restaurant_id:'restaurant-1'};tables=[{id:4,name:'Mesa 4'}];",context);
 return {context,elements,alerts,get summaries(){return summaries;}};
}
test('tapping occupied table opens menu directly on its existing account, with no chooser',async()=>{
 const ui=waiterScreen([{id:10,table_id:4,total:100},{id:11,table_id:4,total:200}]);
 await vm.runInContext('chooseTable(4)',ui.context);
 assert.equal(vm.runInContext('selectedAccount',ui.context),10);
 assert.match(ui.elements.get('order-context').innerHTML,/Agregar a la cuenta #10/);
 assert.doesNotMatch(html,/account-dialog|ABRIR CUENTA NUEVA|selectAccount\(/);
});
test('empty table opens menu for its first round; query failure prevents stale selection',async()=>{
 const ui=waiterScreen([]);await vm.runInContext('chooseTable(4)',ui.context);
 assert.equal(vm.runInContext('selectedAccount',ui.context),null);
 assert.equal(vm.runInContext('selectedTable.id',ui.context),4);
 const failed=waiterScreen([],{error:true});await vm.runInContext('chooseTable(4)',failed.context);
 assert.equal(vm.runInContext('selectedTable',failed.context),null);assert.equal(failed.alerts.length,1);
});
test('closed cash shift blocks ordering and double taps make only one selection request',async()=>{
 const closed=waiterScreen([],{open:false});await vm.runInContext('chooseTable(4)',closed.context);
 assert.equal(closed.summaries,0);
 const ui=waiterScreen([{id:10,table_id:4,total:100}]);await Promise.all([vm.runInContext('chooseTable(4)',ui.context),vm.runInContext('chooseTable(4)',ui.context)]);
 assert.equal(ui.summaries,1);
});
function customerScreen() {
 const html=fs.readFileSync(new URL('../menu.html',import.meta.url),'utf8');
 const code=[...html.matchAll(/<script(?![^>]*src)[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]).join('\n').replace('conciliarRetornoMercadoPago().finally(() => inicializar());','');
 const elements=new Map();const make=id=>{if(!elements.has(id))elements.set(id,{id,textContent:'',innerHTML:'',value:'',dataset:{},attributes:{},classList:{add(){},remove(){},toggle(){}},setAttribute(k,v){this.attributes[k]=v;},removeAttribute(k){delete this.attributes[k];}});return elements.get(id);};
 const tabs=['explorar','favoritos','perfil'].map(id=>{const e=make('tab-'+id);e.dataset.customerTab=id;return e;});
 const context=vm.createContext({Map,Set,Date,console,Number,setTimeout,clearTimeout,SYRuntime:runtime,window:{serveYourself:{supabase:{},escapeHtml:v=>String(v),safeImageUrl:()=>''},addEventListener(){}},document:{body:{dataset:{}},getElementById:make,querySelectorAll:query=>query==='[data-customer-tab]'?tabs:[]}});
 vm.runInContext(code,context);vm.runInContext('cargarRestaurantes=async()=>{};cargarHistorialPedidos=async()=>{};',context);
 return {context,elements,tabs,html};
}
test('bottom navigation switches Inicio, Favoritos and Cuenta with correct selected state',()=>{
 const ui=customerScreen();
 assert.equal((ui.html.match(/data-customer-tab=/g)||[]).length,3);
 vm.runInContext("matchedRestaurants=[{id:'a',business_name:'A'},{id:'b',business_name:'B'}];favoriteIds=new Set(['b']);mostrarSeccion('favoritos');",ui.context);
 assert.equal(ui.elements.get('explore-title').textContent,'Favoritos');
 assert.match(ui.elements.get('lista-restaurantes').innerHTML,/restaurante.html\?id=b/);
 assert.doesNotMatch(ui.elements.get('lista-restaurantes').innerHTML,/restaurante.html\?id=a/);
 assert.equal(ui.tabs[1].attributes['aria-current'],'page');
 vm.runInContext("mostrarSeccion('explorar')",ui.context);
 assert.match(ui.elements.get('lista-restaurantes').innerHTML,/restaurante.html\?id=a/);
 assert.equal(ui.elements.get('explore-title').textContent,'Inicio');
 vm.runInContext("mostrarSeccion('perfil')",ui.context);
 assert.equal(ui.tabs[2].attributes['aria-current'],'page');assert.equal(ui.tabs[0].attributes['aria-current'],undefined);
});
