import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const cash=fs.readFileSync(new URL('../caja.html',import.meta.url),'utf8');
test('credit double click sends one payment and network failure restores controls',async()=>{
 let release,calls=0;const gate=new Promise(r=>release=r);const alerts=[];
 const elements={'credit-method-1':{value:'cash'},'credit-amount-1':{value:'50'},'credit-received-1':{value:'100'}};
 const ctx=vm.createContext({document:{getElementById:id=>elements[id]},alert:m=>alerts.push(m),money:String,loadAll:async()=>{},db:{rpc:async()=>{calls++;await gate;throw Error('Offline');}}});
 vm.runInContext(cash.slice(cash.indexOf('        const creditPaymentsInFlight='),cash.indexOf('        async function coupon(')),ctx);ctx.button={};
 const first=vm.runInContext('payCredit(1,button)',ctx),second=vm.runInContext('payCredit(1,button)',ctx);release();await Promise.all([first,second]);
 assert.equal(calls,1);assert.equal(ctx.button.disabled,false);assert.equal(alerts[0],'Offline');
});
test('online transfer card locks the selected method and does not show a cash input',()=>{
 const helper=cash.slice(cash.indexOf('        function isOnlinePickupOrder('),cash.indexOf('        function shiftTotals('));
 const card=cash.slice(cash.indexOf('        function accountCard('),cash.indexOf('        function renderAccounts('));
 const ctx=vm.createContext({payments:[],tables:[],waiters:[],creditCustomers:[],shift:{},esc:String,money:String,o:{id:5,order_source:'online',service_type:'pickup',payment_before_kitchen:true,payment_method:'transfer',total:50,items:[]}});
 vm.runInContext(helper+card+'result=accountCard(o)',ctx);assert.match(ctx.result,/value="transfer">Transferencia/);assert.match(ctx.result,/id="received-wrap-5" hidden/);assert.doesNotMatch(ctx.result,/value="cash"/);
});
test('waiter ready list recovers after an exception and preserves displayed tickets on query error',async()=>{
 const pos=fs.readFileSync(new URL('../pos.html',import.meta.url),'utf8');const code=pos.slice(pos.indexOf('async function loadReady()'),pos.indexOf('async function markDelivered('));let attempts=0;
 const q={select(){return this},eq(){return this},order:async()=>{attempts++;if(attempts===1)throw Error('Offline');return{error:Error('Retry later')};}};
 const ctx=vm.createContext({cashierPickup:false,loadingReady:false,access:{restaurant_id:'r',user:{id:'u'}},db:{from:()=>q},console:{warn(){}},readyOrders:{innerHTML:'Existing ticket'}});vm.runInContext(code,ctx);
 await vm.runInContext('loadReady()',ctx);assert.equal(ctx.loadingReady,false);await vm.runInContext('loadReady()',ctx);assert.equal(attempts,2);assert.equal(ctx.readyOrders.innerHTML,'Existing ticket');
});
test('automatic cashier refresh preserves active input only when the balance is unchanged',()=>{
 const code=fs.readFileSync(new URL('../cash-layout.js',import.meta.url),'utf8').split('/* Hash navigation')[0];
 let current;const input={id:'amount',value:'17',checked:false,focus(){},dispatchEvent(){}};
 const card={id:'card',dataset:{cashDraftVersion:'50:0'},querySelectorAll:()=>[input],contains:()=>true};input.closest=()=>card;current=card;
 const window={};vm.runInNewContext(code,{window,document:{activeElement:input,getElementById:id=>id==='card'?current:input},Event:class{}});
 const restore=window.captureCashDraft();input.value='50';restore();assert.equal(input.value,'17');
 const stale=window.captureCashDraft();current={...card,dataset:{cashDraftVersion:'50:20'}};input.value='30';stale();assert.equal(input.value,'30');
});
