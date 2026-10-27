import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const read=path=>fs.readFileSync(new URL('../'+path,import.meta.url),'utf8');
function kitchen(){
 const elements=new Map();const get=id=>{if(!elements.has(id))elements.set(id,{innerHTML:'',textContent:'',classList:{add(){},remove(){},toggle(){}},addEventListener(){}});return elements.get(id);};
 const context=vm.createContext({console,Date,Number,setTimeout,clearTimeout,SYRuntime:{},document:{getElementById:get,addEventListener(){},visibilityState:'visible'},window:{serveYourself:{supabase:{},escapeHtml:v=>String(v)},addEventListener(){}}});
 const scripts=[...read('cocina.html').matchAll(/<script(?![^>]*src)[^>]*>([\s\S]*?)<\/script>/g)];
 vm.runInContext(scripts.at(-1)[1].replace(/init\(\);\s*$/,''),context);
 vm.runInContext("orders=[];tables=[];products=[];",context);
 return {context,elements};
}
const base={id:1,order_id:1,status:'pendiente',service_type:'pickup',items:[{id:'p',nombre:'Plato',qty:1}],created_at:new Date().toISOString(),recommended_start_at:new Date().toISOString(),target_ready_at:new Date().toISOString(),predicted_prep_minutes:20,priority_override:0,minimum_samples:10,sample_count:0,missing_ingredients:[],untracked_products:0};
test('shortage blocks start and explains exact ingredient deficit',()=>{
 const ui=kitchen();ui.context.order={...base,has_shortage:true,missing_ingredients:[{name:'Harina',shortage:1,unit:'kg'}]};
 const html=vm.runInContext('orderCard(order,0)',ui.context);assert.match(html,/disabled aria-disabled="true"/);assert.match(html,/Harina: faltan 1.000 kg/);assert.match(html,/ESPERANDO INSUMOS/);
});
test('ready resources allow preparation; missing recipes explicitly show partial tracking',()=>{
 const ui=kitchen();ui.context.order={...base,has_shortage:false,untracked_products:1};
 const html=vm.runInContext('orderCard(order,0)',ui.context);assert.doesNotMatch(html,/disabled aria-disabled/);assert.match(html,/Control parcial de insumos/);assert.match(html,/Calibrando tiempos/);
});
test('validation error is displayed without claiming a confidence interval',()=>{
 const ui=kitchen();ui.context.order={...base,has_shortage:false,model_ready:true,sample_count:12,mean_absolute_error:1.5};
 const html=vm.runInContext('orderCard(order,0)',ui.context);assert.match(html,/error de validación 1.5 min/);assert.doesNotMatch(html,/±/);
});
test('sufficient but unsuitable observations clearly use configured time',()=>{
 const ui=kitchen();ui.context.order={...base,has_shortage:false,model_ready:false,sample_count:100};
 assert.match(vm.runInContext('orderCard(order,0)',ui.context),/Usando tiempo configurado para esta comanda/);
});
test('render preserves database priority rather than sorting again by age',()=>{
 const ui=kitchen();ui.context.ordered=[{...base,id:2,priority_override:2,has_shortage:false},{...base,id:1,priority_override:0,has_shortage:false}];
 vm.runInContext('orders=ordered;render()',ui.context);const html=ui.elements.get('orders-pendiente').innerHTML;
 assert.ok(html.indexOf('Comanda #2')<html.indexOf('Comanda #1'));
});
