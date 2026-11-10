import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import fs from 'node:fs';
import vm from 'node:vm';
const runtime=createRequire(import.meta.url)('../runtime.js');
const week=Array.from({length:7},()=>({closed:true}));week[0]={closed:false,open:'18:00',close:'02:00'};
test('weekly hours respect business timezone, closed days and previous-day overnight closing',()=>{
 const b={business_hours:week,timezone:'America/Mexico_City'};
 assert.equal(runtime.isBusinessOpen(b,new Date('2026-11-03T01:00:00Z')),true); // Monday 19:00
 assert.equal(runtime.isBusinessOpen(b,new Date('2026-11-03T07:59:00Z')),true); // Tuesday 01:59
 assert.equal(runtime.isBusinessOpen(b,new Date('2026-11-03T08:00:00Z')),false);
 assert.equal(runtime.isBusinessOpen(b,new Date('2026-11-04T01:00:00Z')),false);
 assert.equal(runtime.isBusinessOpen({...b,accepting_orders:false},new Date('2026-11-03T01:00:00Z')),false);
});
test('24-hour common schedule and legacy schedules remain supported',()=>{
 assert.equal(runtime.isBusinessOpen({business_hours:week.map(()=>({closed:false,allDay:true})),timezone:'UTC'},new Date('2026-11-04T03:00:00Z')),true);
 assert.equal(runtime.isBusinessOpen({open_time:'09:00',close_time:'17:00',timezone:'UTC'},new Date('2026-11-04T18:00:00Z')),false);
});
test('transfer receipt link targets only the registered phone and includes order reference',()=>{
 const url=runtime.transferReceiptUrl('55 1234 5678',{id:42,pickup_name:'Ana & Luis',total:50});
 assert.match(url,/^https:\/\/wa.me\/525512345678\?text=/);assert.match(decodeURIComponent(url),/pedido #42/);assert.match(decodeURIComponent(url),/Ana & Luis/);
 assert.equal(runtime.transferReceiptUrl('invalid',{id:1,total:0}),null);
});
test('closed-all-week configuration is not silently converted to open every day',()=>{
 const elements=new Map();const get=id=>{if(!elements.has(id))elements.set(id,{value:'',hidden:false});return elements.get(id);};
 const window={serveYourself:{safeImageUrl:()=>''}};
 vm.runInNewContext(fs.readFileSync(new URL('../business-settings.js',import.meta.url),'utf8'),{window,document:{getElementById:get}});
 window.BusinessSettings.load({business_hours:Array.from({length:7},()=>({closed:true}))});assert.equal(get('cfg-hours-mode').value,'daily');
});
test('business image is staged for the single settings save, without a separate profile update',async()=>{
 const elements={'cfg-business-image':{files:[{type:'image/png',size:100}],value:'file'}};
 let uploaded;const db={storage:{from:()=>({upload:async(path)=>{uploaded=path;return{};},getPublicUrl:path=>({data:{publicUrl:'https://images.test/'+path}})})},from:()=>{throw Error('A separate profile write must not occur');}};
 const window={};vm.runInNewContext(fs.readFileSync(new URL('../business-settings.js',import.meta.url),'utf8'),{window,document:{getElementById:id=>elements[id]},crypto:{randomUUID:()=> 'image-id'},createImageBitmap:async()=>({close(){}})});
 const image=await window.BusinessSettings.uploadImage(db,'owner');
 assert.equal(uploaded,'owner/business/image-id.png');assert.equal(image.path,uploaded);assert.equal(image.url,'https://images.test/'+uploaded);
 assert.equal(elements['cfg-business-image'].value,'file','The file remains available until the settings update succeeds');
});
