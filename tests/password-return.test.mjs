import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import fs from 'node:fs';
const source=fs.readFileSync(new URL('../password-change.js',import.meta.url),'utf8');
function setup({mode='work',loginError=false,updateError=false,logoutError=false}={}){
 const button={disabled:false},nodes=new Map(),order=[];let updates=0;
 const get=id=>{if(!nodes.has(id))nodes.set(id,{value:'',addEventListener(type,fn){this[type]=fn;}});return nodes.get(id);};
 const form=get('password-form');form.querySelector=()=>button;form.reset=()=>{for(const node of nodes.values())node.value='';order.push('reset');};
 const app={supabase:{auth:{getUser:async()=>({data:{user:{id:'u',email:'u@example.invalid'}}})}},goBack:target=>order.push(target)};
 const isolated={auth:{signInWithPassword:async()=>({data:{user:{id:'u'}},error:loginError?{}:null}),updateUser:async()=>{updates++;return{error:updateError?{message:'Falló el cambio'}:null};},signOut:async()=>{order.push('logout');if(logoutError)throw Error('offline');}}};
 vm.runInNewContext(source,{window:{location:{search:'?mode='+mode},serveYourself:app,supabase:{createClient:(_url,_key,options)=>{assert.equal(options.auth.persistSession,false);return isolated;}}},document:{getElementById:get},URLSearchParams,SUPABASE_URL:'https://example.invalid',SUPABASE_KEY:'public'});
 get('new-password').value='new-test-password';get('confirm-password').value='new-test-password';get('current-password').value='old-test-password';
 return{get,form,button,order,updates:()=>updates,submit:()=>form.onsubmit({preventDefault(){}})};
}
for(const mode of ['work','personal'])test(`password success returns to ${mode} only after updating and clearing the isolated session`,async()=>{const s=setup({mode});await s.submit();assert.equal(s.updates(),1);assert.deepEqual(s.order,['reset','logout','perfil.html?mode='+mode]);assert.equal(s.get('current-password').value,'');});
test('wrong current password does not update or navigate away',async()=>{const s=setup({loginError:true});await s.submit();assert.equal(s.updates(),0);assert.deepEqual(s.order,['logout']);assert.match(s.get('result').textContent,/actual no es correcta/);});
test('failed password update stays on the form and allows retry',async()=>{const s=setup({updateError:true});await s.submit();assert.deepEqual(s.order,['logout']);assert.equal(s.button.disabled,false);assert.equal(s.get('result').textContent,'Falló el cambio');});
test('cleanup failure does not trap the user after a successful password change',async()=>{const s=setup({logoutError:true});await s.submit();assert.equal(s.order.at(-1),'perfil.html?mode=work');});
