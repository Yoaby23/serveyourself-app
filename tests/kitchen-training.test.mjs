import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../kitchen-training.js',import.meta.url),'utf8');
function setup(handler=async()=>({data:{models:[],recent_samples:[]}}),confirm=true) {
 const elements=new Map(),calls=[];let refreshed=0,serial=0;
 const element=()=>({value:'',checked:false,textContent:'',innerHTML:'',dataset:{},children:[],querySelectorAll(){return[];}});
 const get=id=>{if(!elements.has(id))elements.set(id,element());return elements.get(id);};
 const rows=get('training-items');rows.appendChild=row=>rows.children.push(row);rows.querySelectorAll=()=>rows.children;
 get('training-service').value='pickup';get('training-minutes').value='12';
 const document={getElementById:get,createElement(){const row=element();const nodes={'[data-product]':{value:'p'},'[data-quantity]':{value:'2'},'[data-remove]':{}};row.querySelector=s=>nodes[s];row.remove=()=>rows.children.splice(rows.children.indexOf(row),1);return row;}};
 get('kitchen-training-dialog').showModal=()=>{};
 const window={serveYourself:{escapeHtml:x=>String(x)},confirm:()=>confirm};
 vm.runInNewContext(source,{window,document,crypto:{randomUUID:()=>`request-${++serial}`},Date,console});
 const controller=window.SYKitchenTraining.create({db:{rpc:async(name,args)=>{calls.push({name,args});return handler(name,args);}},access:{restaurant_id:'r'},products:[{id:'p',name:'Producto'}],onTrained:async()=>refreshed++,root:document});
 return{controller,elements,get,calls,rows,refreshed:()=>refreshed};
}
test('manual saving sends observed items and minutes to the server then refreshes the live queue',async()=>{
 const s=setup();await s.controller.save();const call=s.calls[0];assert.equal(call.name,'save_kitchen_training_sample');assert.equal(call.args.p_prep_minutes,12);assert.equal(call.args.p_items[0].qty,2);assert.equal(call.args.p_request_id,'request-1');assert.equal(s.refreshed(),1);assert.equal(s.get('training-minutes').value,'');
});
test('a failed response preserves data and request id so retry does not duplicate training',async()=>{
 let fail=true;const s=setup(async name=>{if(name==='save_kitchen_training_sample'&&fail){fail=false;return{error:{message:'Red interrumpida'}};}return{data:{models:[],recent_samples:[]}};});
 await s.controller.save();assert.equal(s.get('training-minutes').value,'12');assert.equal(s.refreshed(),0);await s.controller.save();const saves=s.calls.filter(x=>x.name==='save_kitchen_training_sample');assert.equal(saves[0].args.p_request_id,saves[1].args.p_request_id);assert.equal(s.refreshed(),1);
});
test('double submission issues only one training write',async()=>{
 let resolve;const hold=new Promise(r=>resolve=r);const s=setup(async name=>{if(name==='save_kitchen_training_sample')await hold;return{data:{models:[],recent_samples:[]}};});
 const first=s.controller.save();await s.controller.save();assert.equal(s.calls.length,1);resolve();await first;
});
test('invalid minutes and duplicate products are rejected before any database write',async()=>{
 const s=setup();s.get('training-minutes').value='0';await s.controller.save();assert.equal(s.calls.length,0);s.get('training-minutes').value='12';s.get('training-add-item').onclick();await s.controller.save();assert.equal(s.calls.length,0);assert.match(s.get('training-message').textContent,/una sola fila/);
});
test('preview reports whether trained data was applied and never saves a sample',async()=>{
 const s=setup(async()=>({data:{minutes:12.7,model_ready:true,reason:'Datos entrenados'}}));await s.controller.estimate();assert.deepEqual(s.calls.map(c=>c.name),['preview_kitchen_training']);assert.match(s.get('training-preview').textContent,/12.7 min · Modelo entrenado/);assert.equal(s.refreshed(),0);
});
test('insufficient data is reported as calibration rather than a successfully usable model',async()=>{
 const s=setup(async name=>name==='train_kitchen_model'?{data:{sample_count:4,model_ready:false}}:{data:{models:[],recent_samples:[]}});await s.controller.train();assert.match(s.get('training-message').textContent,/4 mediciones.*tiempo configurado/);assert.equal(s.refreshed(),1);
});
test('manual deletion recalculates and refreshes the queue',async()=>{
 const s=setup();await s.controller.remove(9);assert.equal(s.calls[0].name,'delete_kitchen_training_sample');assert.equal(s.calls[0].args.p_sample_id,9);assert.equal(s.refreshed(),1);
});

test('declining deletion does not send any database operation',async()=>{const s=setup(undefined,false);await s.controller.remove(9);assert.equal(s.calls.length,0);});
