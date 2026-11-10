import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../cashier-checkout.js',import.meta.url),'utf8');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function setup(needsApproval=false,approvalDenied=false){
 const dialogs=[],calls=[];let logins=0,logouts=0,created=0;
 const customer={id:'new-client',customer_name:'Ana',phone:'525512345678',credit_enabled:true,credit_limit:500};
 const db={rpc:async(name,args)=>{calls.push({name,args});if(needsApproval)return{error:{code:'42501',message:'Approval required'}};created++;return{data:customer};}};
 const isolated={auth:{signInWithPassword:async()=>{logins++;return{};},signOut:async()=>{logouts++;}},rpc:async()=>{if(approvalDenied)return{error:{code:'42501',message:'Esta cuenta no tiene permiso para el restaurante'}};created++;return{data:customer};}};
 const window={serveYourself:{supabase:db},supabase:{createClient:(_url,_key,options)=>{assert.equal(options.auth.persistSession,false);return isolated;}}};
 const document={body:{appendChild(){}},createElement:()=>{
  const nodes=new Map(),events={};const dialog={querySelector(selector){if(!nodes.has(selector))nodes.set(selector,{value:'',disabled:false,textContent:''});return nodes.get(selector);},addEventListener(name,fn){events[name]=fn;},showModal(){this.shown=true;},close(){this.closed=true;events.close?.();},remove(){this.removed=true;}};
  dialogs.push(dialog);return dialog;
 }};
 const context=vm.createContext({window,document,crypto:{randomUUID:()=> 'request-id'},SUPABASE_URL:'https://app.test',SUPABASE_KEY:'public-key',console});vm.runInContext(source,context);
 return{context,dialogs,calls,db,window,stats:()=>({logins,logouts,created})};
}
function fill(dialog){dialog.querySelector('[name=customer-name]').value='Ana';dialog.querySelector('[name=phone]').value='5512345678';dialog.querySelector('[name=credit-limit]').value='500';}
const submit=dialog=>dialog.querySelector('form').onsubmit({preventDefault(){}});
test('capturing customer data does not request credentials and an authorized owner confirms directly',async()=>{
 const s=setup();const result=s.context.createCheckoutCreditCustomer('restaurant');
 const form=s.dialogs[0];assert.equal(form.shown,true);assert.equal(s.calls.length,0);assert.equal(s.dialogs.length,1);
 fill(form);await submit(form);
 assert.equal((await result).id,'new-client');assert.deepEqual(s.stats(),{logins:0,logouts:0,created:1});assert.equal(s.dialogs.length,1);
});
test('cashier is prompted only after confirming data and approval uses a separate session',async()=>{
 const s=setup(true);const result=s.context.createCheckoutCreditCustomer('restaurant');fill(s.dialogs[0]);
 assert.equal(s.calls.length,0);const confirmation=submit(s.dialogs[0]);await tick();
 assert.equal(s.dialogs.length,2);const approval=s.dialogs[1];assert.equal(approval.shown,true);
 approval.querySelector('[name=email]').value='owner@example.invalid';approval.querySelector('[name=password]').value='temporary-password';
 await submit(approval);await confirmation;
 assert.equal((await result).id,'new-client');assert.equal(s.window.serveYourself.supabase,s.db);
 assert.deepEqual(s.stats(),{logins:1,logouts:1,created:1});assert.equal(approval.querySelector('[name=password]').value,'');
});
test('a user without approval rights cannot create the client and captured fields remain available',async()=>{
 const s=setup(true,true);const result=s.context.createCheckoutCreditCustomer('restaurant');const form=s.dialogs[0];fill(form);
 const confirmation=submit(form);await tick();const approval=s.dialogs[1];approval.querySelector('[name=email]').value='other@example.invalid';approval.querySelector('[name=password]').value='temporary-password';await submit(approval);
 assert.match(approval.querySelector('[role=status]').textContent,/no tiene permiso/);assert.equal(s.stats().created,0);
 approval.querySelector('[data-cancel]').onclick();await confirmation;
 assert.equal(form.querySelector('[name=customer-name]').value,'Ana');assert.equal(form.closed,undefined);
 form.querySelector('[data-cancel]').onclick();assert.equal(await result,null);
});
