import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../order-tools.js',import.meta.url),'utf8');
const window={};vm.runInNewContext(source,{window});
const groups=window.SYOrderTools.splitGroups,items=[{id:'a',nombre:'Café',qty:4},{id:'b',nombre:'Pan',qty:2}];
test('three account allocation moves selected quantities and leaves the original remainder',()=>{
 const result=groups(items,3,(i,g)=>[[1,2],[0,1]][i][g]);
 assert.deepEqual(JSON.parse(JSON.stringify(result)),[[{id:'a',qty:1}],[{id:'a',qty:2},{id:'b',qty:1}]]);
});
test('split rejects over-allocation across several target accounts',()=>assert.throws(()=>groups(items,3,(i,g)=>i===0?3:0),/supera/));
test('split rejects empty target and empty original account',()=>{
 assert.throws(()=>groups(items,3,()=>0),/Cada cuenta/);
 assert.throws(()=>groups(items,2,i=>items[i].qty),/Cada cuenta/);
});
test('split rejects fractional and negative quantities and invalid account counts',()=>{
 for(const qty of [-1,.5,NaN])assert.throws(()=>groups(items,2,()=>qty),/enteras/);
 for(const n of [1,11,2.5])assert.throws(()=>groups(items,n,()=>1),/2 y 10/);
});
test('delivery navigation follows the enabled business service even for owners',()=>{
 const appSource=fs.readFileSync(new URL('../app.js',import.meta.url),'utf8');
 const method=appSource.slice(appSource.indexOf('    workFeatures(access)'),appSource.indexOf('    workBottomItems(access)')).trim().replace(/,$/,'');
 const app=vm.runInNewContext('({'+method+'})');
 assert.equal(app.workFeatures({staff_role:'owner',delivery_enabled:false}).some(x=>x.href==='delivery.html'),false);
 assert.equal(app.workFeatures({staff_role:'owner',delivery_enabled:true}).some(x=>x.href==='delivery.html'),true);
});
test('cart quantity updates preserve DOM controls, scroll offset and background lock',()=>{
 const html=fs.readFileSync(new URL('../restaurante.html',import.meta.url),'utf8');
 const code=html.slice(html.indexOf('        function actualizarModalCarrito()'),html.indexOf('\n        async function',html.indexOf('        function actualizarModalCarrito()')));
 const line={},qty={},row={dataset:{product:'a'},querySelector:s=>s==='[data-line]'?line:qty};
 const panel={scrollTop:240},list={children:[row],closest:()=>panel,appendChild(){throw Error('Existing controls were recreated')}};
 const el={};let ctx={carrito:[{id:'a',nombre:'Café',price:25,qty:3}],serviceType:'pickup',deliveryQuote:null,escapeHtml:String,document:{getElementById:id=>id==='lista-carrito'?list:el[id]??={}}};
 // Isolate this single function without unrelated checkout code.
 const end=code.indexOf('\n        }')+10;vm.runInNewContext(code.slice(0,end)+';actualizarModalCarrito();',ctx);
 assert.equal(qty.textContent,3);assert.equal(panel.scrollTop,240);assert.equal(el['modal-total'].innerText,'$75.00');
 assert.match(html,/function abrirCarrito\(\).*sy-cart-open/);assert.match(html,/function cerrarCarrito\(\).*remove\('sy-cart-open'\)/);
});
test('selecting three stars submits three, once, with the optional comment',async()=>{
 const controls={status:{},submit:{},form:{},rating:{},textarea:{value:'Muy bien'},close:{}};
 const stars=[1,2,3,4,5].map(n=>({dataset:{star:String(n)},classList:{toggle(_key,value){this.selected=value}},setAttribute(_key,value){this.pressed=value}}));
 let closed=false;const dialog={isConnected:true,setAttribute(){},showModal(){},addEventListener(){},close(){closed=true},querySelector:s=>s==='[data-error]'?controls.status:s==='[type=submit]'?controls.submit:s==='form'?controls.form:s==='[data-rating]'?controls.rating:s==='textarea'?controls.textarea:null,querySelectorAll:s=>s==='[data-star]'?stars:s==='button'?[...stars,controls.submit,controls.close]:[controls.close]};
 let calls=0,release,args;const gate=new Promise(r=>release=r),window={serveYourself:{escapeHtml:String}};
 vm.runInNewContext(source,{window,document:{activeElement:null,createElement:()=>dialog,body:{append(){}}}});
 window.SYOrderTools.rating({rpc:async(_name,payload)=>{calls++;args=payload;await gate;return{}}},'42',async()=>{});
 assert.equal(controls.submit.disabled,true);stars[2].onclick();assert.equal(controls.submit.disabled,false);
 assert.deepEqual(stars.map(s=>s.classList.selected),[true,true,true,false,false]);
 const first=controls.form.onsubmit({preventDefault(){}}),second=controls.form.onsubmit({preventDefault(){}});release();await Promise.all([first,second]);
 assert.equal(calls,1);assert.equal(args.p_rating,3);assert.equal(args.p_comment,'Muy bien');assert.equal(closed,true);
});
