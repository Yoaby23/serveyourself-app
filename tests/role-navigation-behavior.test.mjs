import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
const read=path=>fs.readFileSync(new URL('../'+path,import.meta.url),'utf8');
function appFor(page='pos.html'){
 const nodes=new Map();const make=()=>({innerHTML:'',textContent:'',attributes:{},style:{setProperty(){}},dataset:{},setAttribute(k,v){this.attributes[k]=v;},addEventListener(){}});
 nodes.set('restaurant-nav',make());
 const document={body:{classList:{add(){}},appendChild:node=>nodes.set(node.id,node)},head:{appendChild(){}},getElementById:id=>nodes.get(id)||null,querySelector:selector=>selector.includes('.sy-restaurant-nav')?nodes.get('restaurant-nav'):null,addEventListener(){},createElement:make};
 const window={location:{origin:'https://app.test',pathname:'/'+page},history:{length:1},addEventListener(){},supabase:{createClient:()=>({})}};
 vm.runInNewContext(read('app.js'),{window,document,navigator:{},location:window.location,URL,alert(){}});
 return {app:window.serveYourself,nodes};
}
const roles={
 owner:{staff_role:'owner'},waiter:{staff_role:'waiter',can_create_orders:true},kitchen:{staff_role:'kitchen',can_view_kitchen:true},cashier:{staff_role:'cashier',can_close_accounts:true},manager:{staff_role:'manager',can_create_orders:true,can_close_accounts:true,can_manage_delivery:true},driver:{staff_role:'driver',can_deliver_orders:true}
};
for(const [role,access] of Object.entries(roles))test(`${role}: bottom navigation is bounded, unique and all operational features honor permissions`,()=>{
 const {app,nodes}=appFor();const items=app.workBottomItems(access);const features=app.workFeatures(access);
 assert.ok(items.length>=3&&items.length<=5);assert.equal(new Set(items.map(item=>item.href)).size,items.length);
 assert.ok(items.some(item=>item.href==='funciones.html'));assert.ok(items.some(item=>item.href==='cuenta.html'));
 if(role!=='owner')assert.ok(!features.some(item=>['equipo.html','qr.html','inventario.html','admin.html?section=config'].includes(item.href)));
 if(!access.can_close_accounts&&role!=='owner')assert.ok(!features.some(item=>item.href==='caja.html'));
 if(!access.can_view_kitchen&&role!=='owner')assert.ok(!features.some(item=>item.href==='cocina.html'));
 app.renderRestaurantNavigation(access);
 assert.match(nodes.get('sy-work-bottom-nav').innerHTML,/Cuenta/);
 assert.doesNotMatch(nodes.get('sy-work-bottom-nav').innerHTML,/dropdown|toggleRestaurantMenu|aria-expanded/);
 app.renderRestaurantNavigation(access);assert.equal([...nodes.keys()].filter(id=>id==='sy-work-bottom-nav').length,1);
});
test('all owner functions remain reachable through the full-page hub',()=>{
 const {app}=appFor();const links=app.workFeatures(roles.owner).map(item=>item.href);
 for(const target of ['pos.html','caja.html','cocina.html','delivery.html','equipo.html','inventario.html','reportes.html','clientes.html','qr.html','admin.html?section=productos','admin.html?section=config'])assert.ok(links.includes(target),target);
});
test('active route, dark kitchen navigation and customer detail links remain accessible',()=>{
 const {app,nodes}=appFor('cocina.html');app.renderRestaurantNavigation(roles.kitchen,{dark:true});
 assert.match(nodes.get('sy-work-bottom-nav').innerHTML,/href="cocina.html" aria-current="page"/);
 assert.match(nodes.get('sy-work-bottom-nav').className,/dark/);
 app.renderPersonalNavigation();assert.match(nodes.get('sy-personal-bottom-nav').innerHTML,/section=favoritos/);
});
test('no role retains a navigation dropdown and account actions have full-page destinations',()=>{
 for(const page of ['app.js','menu.html','admin.html'])assert.doesNotMatch(read(page),/toggleUserMenu|toggleAdminMenu|toggleRestaurantMenu|id="user-menu"|id="admin-menu"|restaurant-menu-dropdown/);
 for(const action of ['enableWorkNotifications','installApp','signOut','platform-admin.html','menu.html?section=pedidos'])assert.ok(read('cuenta.html').includes(action),action);
 assert.match(read('styles.css'),/body\.sy-has-bottom-nav[^}]*safe-area-inset-bottom/);
 assert.match(read('styles.css'),/@media print[^}]*sy-role-bottom-nav/);
});
