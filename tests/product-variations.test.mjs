import test from 'node:test';
import assert from 'node:assert/strict';
import {ProductVariations as variants} from './variation-test-helper.mjs';
const rows=[{id:'p',name:'Café',price:25,has_variations:true,is_available:true},{id:'s',parent_product_id:'p',name:'Café · Chico',variation_name:'Chico',price:25,is_available:true},{id:'l',parent_product_id:'p',name:'Café · Grande',variation_name:'Grande',price:40,is_available:true}];
test('variants form one product card with distinct sellable IDs',()=>{const cards=variants.catalog(rows);assert.equal(cards.length,1);assert.equal(cards[0].variants.length,2);assert.equal(variants.sellable(rows[0],rows),false);assert.equal(variants.sellable(rows[1],rows),true);assert.equal(variants.sellable(rows[2],rows),true)});
test('the displayed starting price ignores unavailable and retired variants',()=>{const changed=rows.map(r=>({...r}));changed[1].is_available=false;assert.equal(variants.catalog(changed)[0].price,40);changed[2].is_archived=true;assert.equal(variants.catalog(changed)[0].is_available,false);assert.equal(variants.catalog(changed)[0].variants.length,1)});
test('disabling the whole product blocks every variation without changing individual availability',()=>{const changed=rows.map(r=>({...r}));changed[0].is_available=false;assert.equal(variants.catalog(changed)[0].is_available,false);assert.equal(variants.sellable(changed[1],changed),false);assert.equal(changed[1].is_available,true);changed[0].is_available=true;assert.equal(variants.sellable(changed[1],changed),true)});
test('archived products and dangling variations cannot be ordered',()=>{assert.equal(variants.catalog(rows.map(r=>({...r,is_archived:true}))).length,0);assert.equal(variants.sellable(rows[1],[rows[1]]),false)});
test('existing products keep their ordinary price and quantity flow',()=>{const p={id:'a',name:'Pan',price:12,is_available:true};assert.equal(variants.catalog([p])[0].price,12);assert.equal(variants.sellable(p,[p]),true)});
test('variation editor retains IDs and validates duplicate names and prices',()=>{
 const listeners={},container={innerHTML:'',addEventListener:(type,fn)=>listeners[type]=fn,dispatchEvent(){},querySelector:()=>({focus(){}})};
 const editor=variants.editor(container);editor.set(rows.slice(1));
 assert.equal(editor.get()[0].id,'s');listeners.input({target:{dataset:{name:'1'},value:' chico '}});assert.throws(()=>editor.get(),/único/);
 listeners.input({target:{dataset:{name:'1'},value:'Grande'}});listeners.input({target:{dataset:{price:'1'},value:'-3'}});assert.throws(()=>editor.get(),/precio/);
 listeners.input({target:{dataset:{price:'1'},value:'45'}});listeners.input({target:{dataset:{stock:'1'},checked:false}});assert.equal(editor.get()[1].price,45);assert.equal(editor.get()[1].is_available,false);
});
test('variation selection sends the chosen sellable ID and blocks an option that became unavailable',async()=>{
 const {default:fs}=await import('node:fs'),{default:vm}=await import('node:vm');
 const form={},status={},selected={value:'l'},close={},changes=[];
 const dialog={isConnected:true,setAttribute(){},showModal(){},addEventListener(){},close(){this.closed=true},querySelector:s=>s==='form'?form:s==='[data-error]'?status:selected,querySelectorAll:()=>[close]};
 const window={serveYourself:{escapeHtml:String}};vm.runInNewContext(fs.readFileSync(new URL('../product-variations.js',import.meta.url),'utf8'),{window,document:{activeElement:null,body:{append(){}},createElement:()=>dialog}});
 const current=rows.map(p=>({...p}));window.ProductVariations.choose('p',current,id=>changes.push(id));
 current[2].is_available=false;form.onsubmit({preventDefault(){}});assert.equal(changes.length,0);assert.match(status.textContent,/disponible/);
 current[2].is_available=true;form.onsubmit({preventDefault(){}});assert.deepEqual(changes,['l']);assert.equal(dialog.closed,true);
});
