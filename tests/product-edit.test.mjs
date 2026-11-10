import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../admin.html',import.meta.url),'utf8');
function setup(error=null){
 let submit,write;const elements=new Map();const get=id=>{if(!elements.has(id))elements.set(id,{value:'',files:[],disabled:false,focus(){},scrollIntoView(){},reset(){},addEventListener(_,fn){submit=fn}});return elements.get(id)};
 const db={from:()=>({insert(payload){return this.update(payload);},update(payload){write={payload,filters:[]};const q={eq(k,v){write.filters.push([k,v]);return q},select(){return q},async single(){return{data:error?null:{id:'p1'},error}}};return q}})};
 const ctx=vm.createContext({document:{getElementById:get},_supabase:db,currentRestaurantId:'owner',alert(){},cargarProductos:async()=>{}});
 vm.runInContext("let editingProductId=null,productSaving=false,menuCategories=[{name:'Sopas'},{name:'Bebidas'}],adminProducts=[{id:'p1',name:'Sopa',price:50,category:'Sopas',kitchen_station_id:7}];"+html.slice(html.indexOf('        function cancelarEdicionProducto()'),html.indexOf('        function cargarConfiguracion')),ctx);
 return{ctx,get,submit:()=>submit({preventDefault(){}}),write:()=>write};
}
test('editing updates the existing product and preserves image and availability',async()=>{
 const s=setup();vm.runInContext("editarProducto('p1')",s.ctx);assert.equal(s.get('prod-name').value,'Sopa');s.get('prod-name').value='Sopa grande';s.get('prod-price').value='75';s.get('prod-station').value='9';s.get('prod-category').value='Bebidas';await s.submit();assert.deepEqual(JSON.parse(JSON.stringify(s.write())),{payload:{category:'Bebidas',name:'Sopa grande',price:75,kitchen_station_id:9},filters:[['id','p1'],['restaurant_id','owner']]});assert.equal(s.get('btn-save-prod').textContent,'Agregar producto');
});
test('failed update keeps the edit and entered values available for retry',async()=>{
 const s=setup({message:'Disconnected'});vm.runInContext("editarProducto('p1')",s.ctx);s.get('prod-name').value='Nueva sopa';await s.submit();assert.equal(s.get('prod-name').value,'Nueva sopa');assert.equal(s.get('btn-save-prod').textContent,'Guardar cambios');assert.equal(s.get('btn-save-prod').disabled,false);
});

test('adding consecutive products retains the chosen category and station',async()=>{
 const s=setup();s.get('prod-name').value='Café';s.get('prod-price').value='30';s.get('prod-category').value='Bebidas';s.get('prod-station').value='9';await s.submit();assert.equal(s.write().payload.is_available,true);assert.equal(s.get('prod-category').value,'Bebidas');assert.equal(s.get('prod-station').value,'9');assert.match(s.get('product-save-status').textContent,/siguiente/);
});
