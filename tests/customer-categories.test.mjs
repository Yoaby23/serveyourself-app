import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
test('customer menu groups categories independently, including reserved object names',()=>{
 const html=fs.readFileSync(new URL('../restaurante.html',import.meta.url),'utf8');const start=html.indexOf('        function renderizarProductos(');const end=html.indexOf('\n        }',start)+10;const sections=[];
 const ctx=vm.createContext({document:{getElementById:()=>({appendChild:s=>sections.push(s.innerHTML)}),createElement:()=>({})},productosPorId:new Map(),escapeHtml:v=>String(v),safeImageUrl:()=>''});
 vm.runInContext(html.slice(start,end),ctx);ctx.products=[{id:1,name:'Agua',price:20,category:'Bebidas',is_available:true},{id:2,name:'Sopa',price:40,category:'Platillos',is_available:true},{id:3,name:'Especial',price:60,category:'constructor',is_available:true}];vm.runInContext('renderizarProductos(products)',ctx);assert.equal(sections.length,3);assert.match(sections[0],/Bebidas/);assert.doesNotMatch(sections[0],/Sopa/);assert.match(sections[1],/Platillos/);assert.match(sections[2],/Especial/);
});
