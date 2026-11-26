import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
function recovery({query='',request=async()=>({}),update=async()=>({}),exchange=async()=>({data:{session:{},redirectType:'recovery'}})}={}){
 const nodes=new Map(),handlers={},alerts=[];let shown=false;
 const el=id=>{if(!nodes.has(id))nodes.set(id,{value:'test-only-123',textContent:'',disabled:false,classList:{add(){},remove(){if(id==='update-view')shown=true;}},addEventListener:(event,fn)=>handlers[id]=fn});return nodes.get(id);};
 const html=fs.readFileSync(new URL('../recuperar.html',import.meta.url),'utf8');
 const code=[...html.matchAll(/<script(?![^>]*src)[^>]*>([\s\S]*?)<\/script>/g)].at(-1)[1];
 const window={history:{replaceState(){}},location:{search:query,href:'https://app.test/recuperar.html'+query,replace(){}},
  supabase:{createClient:(_url,_key,{auth:options})=>{
   assert.equal(options.flowType,'pkce');assert.equal(options.detectSessionInUrl,false);assert.equal(options.storageKey,'sy-password-recovery');
   return {auth:{resetPasswordForEmail:request,updateUser:update,exchangeCodeForSession:exchange,signOut:async()=>{}}};
  }}};
 const ctx=vm.createContext({window,document:{getElementById:el},URL,URLSearchParams,encodeURIComponent,alert:m=>alerts.push(m),SUPABASE_URL:'https://example.supabase.co',SUPABASE_KEY:'public'});
 vm.runInContext(code,ctx);
 return{nodes,handlers,alerts,ready:vm.runInContext('recoveryReady',ctx),shown:()=>shown};
}
test('recovery email request unlocks the form after a thrown network error',async()=>{const s=recovery({request:async()=>{throw Error('Offline');}});await s.handlers['request-form']({preventDefault(){}});assert.equal(s.nodes.get('request-button').disabled,false);assert.match(s.alerts[0],/Offline/);});
test('password recovery update also unlocks after an exception',async()=>{const s=recovery({query:'?mode=update&code=qa',update:async()=>{throw Error('Offline');}});await s.ready;assert.equal(s.shown(),true);await s.handlers['update-form']({preventDefault(){}});assert.equal(s.nodes.get('update-button').disabled,false);assert.match(s.alerts[0],/Offline/);});
test('password recovery fails closed without a recovery code exchange',async()=>{
 for(const query of ['?mode=update','?mode=update&code=ordinary']){
  let updated=false;
  const s=recovery({query,exchange:async()=>({data:{session:{},redirectType:null}}),update:async()=>{updated=true;}});
  await s.ready;
  await s.handlers['update-form']({preventDefault(){}});
  assert.equal(s.shown(),false);
  assert.equal(updated,false);
 }
});
test('recovery retains staff destination while rejecting external next links',()=>{const staff=recovery({query:'?next=unirse.html'});assert.equal(staff.nodes.get('recovery-back').href,'index.html?next=unirse.html');const external=recovery({query:'?next=https://evil.test'});assert.equal(external.nodes.get('recovery-back').href,'index.html');});
const delivery=fs.readFileSync(new URL('../delivery-tracking.html',import.meta.url),'utf8');const loadCode=delivery.slice(delivery.indexOf('async function load(){'),delivery.indexOf('function render(){'));
function tracking(result){const status={};const initial={id:1,total:10};let rendered=0;const q={select(){return this;},eq(){return this;},maybeSingle:async()=>{if(result instanceof Error)throw result;return result;}};const ctx=vm.createContext({db:{from:()=>q},id:'1',loadVersion:0,order:initial,render:()=>rendered++,document:{getElementById:()=>status}});vm.runInContext(loadCode,ctx);return{ctx,status,initial,run:()=>vm.runInContext('load()',ctx),rendered:()=>rendered};}
test('delivery connection errors preserve last order instead of redirecting away',async()=>{const s=tracking(Error('Offline'));await s.run();assert.equal(s.ctx.order,s.initial);assert.match(s.status.textContent,/Sin conexión/);assert.equal(s.rendered(),0);});
test('a missing delivery reports unavailable access without an automatic wrong navigation',async()=>{const s=tracking({data:null,error:null});await s.run();assert.match(s.status.textContent,/No se encontró/);assert.equal(s.rendered(),0);});
