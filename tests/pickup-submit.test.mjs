import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../pos.html',import.meta.url),'utf8');
const code=html.slice(html.indexOf('let submittingOrder=false;'),html.indexOf('async function loadReady()'));
function screen(name,{rpcError=false}={}){
 let release;const gate=new Promise(resolve=>release=resolve);let calls=0;const alerts=[];
 const elements={'pickup-name':{value:name,focus(){}},'submit-order':{disabled:false,textContent:''}};
 const cart=new Map([['product',1]]);
 const context=vm.createContext({$:id=>elements[id],cart,alert:m=>alerts.push(m),checkShiftStatus:()=>gate,db:{rpc:async()=>{calls++;return rpcError?{error:new Error('Offline')}:{data:{id:1,total:100,pickup_name:name}};}},access:{restaurant_id:'r'},serviceType:'pickup',selectedTable:null,selectedAccount:null,orderNotes:{value:''},successTitle:{},successOrder:{},successModal:{classList:{add(){},remove(){}}},renderCart(){},clearTimeout(){},setTimeout(){return 1;},successTimer:null,showTables(){},refreshAccounts:async()=>{},money:n=>String(n)});
 vm.runInContext(code,context);
 return {context,release,cart,elements,alerts,get calls(){return calls;},submit:()=>vm.runInContext('submitOrder()',context)};
}
test('pickup name validation prevents sending a blank account',async()=>{const ui=screen('   ');await ui.submit();assert.equal(ui.calls,0);assert.equal(ui.alerts.length,1);});
test('double click during shift verification creates only one request',async()=>{const ui=screen('Ana');const first=ui.submit();const second=ui.submit();ui.release(true);await Promise.all([first,second]);assert.equal(ui.calls,1);assert.equal(ui.cart.size,0);assert.equal(ui.elements['submit-order'].disabled,false);});
test('failed submission keeps cart and restores submit control',async()=>{const ui=screen('Ana',{rpcError:true});const running=ui.submit();ui.release(true);await running;assert.equal(ui.cart.size,1);assert.equal(ui.elements['submit-order'].disabled,false);assert.equal(ui.alerts[0],'Offline');});
