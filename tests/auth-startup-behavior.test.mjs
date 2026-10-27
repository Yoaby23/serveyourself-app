import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
const read=name=>fs.readFileSync(new URL('../'+name,import.meta.url),'utf8');
function screen(file,{session=null,user=null,error=null,role='cliente',query='',wait}={}) {
 const elements=new Map(),state={finished:0,failed:0,redirect:null},nodes=id=>{
  if(!elements.has(id))elements.set(id,{textContent:'',innerText:'',value:'',dataset:{},hidden:false,classList:{add(){},remove(){},toggle(){}},addEventListener(){},querySelector(){return {textContent:''}}});return elements.get(id);
 };
 const client={auth:{async getSession(){if(wait)await wait;return {data:{session},error};},async getUser(){return {data:{user},error};}},from(){return {select(){return this},eq(){return this},async maybeSingle(){return {data:{role}}}}}};
 const context=vm.createContext({URL,URLSearchParams,console,setTimeout,clearTimeout,alert(){},window:{location:{search:query,href:'https://app.test/'+file,replace:url=>state.redirect=url},addEventListener(){},authStartup:{finish(){state.finished++;},fail(){state.failed++;},redirect:url=>state.redirect=url},serveYourself:{supabase:client,async getOrCreateProfile(){return {role};},async getRestaurantAccess(){return {staff_role:'waiter'};},restaurantHome:()=> 'pos.html'}},document:{body:{dataset:{}},getElementById:nodes,querySelectorAll:()=>[]}});
 const scripts=[...read(file).matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)];
 const code=scripts.at(-1)[1].replace(/initializeAccess\(\);\s*$/,'').replace(/completeOAuthRegistration\(\);\s*$/,'');
 vm.runInContext(code,context);return {context,state,elements,run:()=>vm.runInContext(file==='index.html'?'initializeAccess()':'completeOAuthRegistration()',context)};
}
test('access and registration hide their content in the initial HTML before scripts verify the session',()=>{
 for(const file of ['index.html','registro.html']){
  const html=read(file);assert.match(html,/<html[^>]*data-auth-pending/);assert.match(html,/html\[data-auth-pending\] body > :not\(#auth-splash\)/);assert.match(html,/Logo de ServeYourself/);assert.match(html,/id="auth-retry" hidden/);
 }
});
test('saved session keeps splash visible until verification then redirects owner without exposing login',async()=>{
 let resolve;const wait=new Promise(r=>resolve=r);
 const ui=screen('index.html',{session:{user:{id:'u'}},user:{id:'u'},role:'negocio',wait});
 const running=ui.run();assert.equal(ui.state.finished,0);assert.equal(ui.state.redirect,null);
 resolve();await running;assert.equal(ui.state.redirect,'admin.html');assert.equal(ui.state.finished,0);
});
test('saved staff session goes directly to its work destination',async()=>{
 const ui=screen('index.html',{session:{user:{id:'u'}},user:{id:'u'}});await ui.run();assert.equal(ui.state.redirect,'pos.html');assert.equal(ui.state.finished,0);
});
test('no session reveals access only after the check finishes',async()=>{
 const ui=screen('index.html');await ui.run();assert.equal(ui.state.finished,1);assert.equal(ui.state.redirect,null);
});
test('network failure keeps access hidden and offers recovery instead of showing a false logged-out state',async()=>{
 const ui=screen('index.html',{error:{message:'Network failure'}});await ui.run();assert.equal(ui.state.failed,1);assert.equal(ui.state.finished,0);
});
test('fresh registration verifies first then reveals registration',async()=>{
 const ui=screen('registro.html');await ui.run();assert.equal(ui.state.finished,1);assert.equal(ui.state.redirect,null);
});
test('already registered owner opening registration is redirected directly into the app',async()=>{
 const ui=screen('registro.html',{session:{user:{id:'u'}},user:{id:'u'},role:'negocio',query:'?role=negocio'});await ui.run();assert.equal(ui.state.redirect,'admin.html');assert.equal(ui.state.finished,0);
});
test('signed-in customer creating a business gets the completion form after session validation',async()=>{
 const ui=screen('registro.html',{session:{user:{id:'u',user_metadata:{name:'Yoab'},email:'qa@example.invalid'}},user:{id:'u'},role:'cliente',query:'?role=negocio'});await ui.run();assert.equal(ui.state.finished,1);assert.equal(ui.elements.get('ui-form').dataset.oauth,'true');assert.equal(ui.state.redirect,null);
});
