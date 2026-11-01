import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const app=fs.readFileSync(new URL('../app.js',import.meta.url),'utf8');
const methods=app.slice(app.indexOf('    restaurantHome(access)'),app.indexOf('    goBack('));
function setup(access,path='/clientes.html'){
 let destination;
 const ctx=vm.createContext({window:{location:{pathname:path,replace:url=>destination=url}},alert(){}});
 vm.runInContext('api={'+methods+'}',ctx);
 ctx.api.requireUser=async()=>({id:'user'});ctx.api.getRestaurantAccess=async()=>access;
 return {api:ctx.api,get destination(){return destination;}};
}
test('denied credit configuration returns a cashier to the same credit section, even with waiter permissions',async()=>{
 const ui=setup({staff_role:'cashier',can_close_accounts:true,can_create_orders:true});
 assert.equal(await ui.api.requireRestaurantAccess(['owner']),null);assert.equal(ui.destination,'caja.html#credit');
});
test('denied work permissions route staff to their work home instead of the customer menu',async()=>{
 const ui=setup({staff_role:'kitchen',can_view_kitchen:true},'/pos.html');
 assert.equal(await ui.api.requireRestaurantPermission('can_create_orders'),null);assert.equal(ui.destination,'cocina.html');
});
test('owner retains credit configuration access and customer remains unauthorized',async()=>{
 const owner=setup({staff_role:'owner'});assert.equal((await owner.api.requireRestaurantAccess(['owner'])).staff_role,'owner');assert.equal(owner.destination,undefined);
 const customer=setup(null);assert.equal(await customer.api.requireRestaurantAccess(['owner']),null);assert.equal(customer.destination,'menu.html');
});
