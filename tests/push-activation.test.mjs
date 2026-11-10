import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
const source=fs.readFileSync(new URL('../app.js',import.meta.url),'utf8');
function setup(){let requested=0,opted=0,initialized=0,script;const window={APP_CONFIG:{oneSignalAppId:'app'},navigator:{userAgent:'Chrome'},Notification:{permission:'default'}};const sdk={init:async()=>{initialized++},login:async()=>{},Notifications:{isPushSupported:()=>true,permission:true,requestPermission:async()=>{requested++}},User:{PushSubscription:{optedIn:false,optIn:async()=>{opted++;sdk.User.PushSubscription.optedIn=true}}}};const ctx=vm.createContext({window,setTimeout,clearTimeout,document:{querySelector:()=>null,createElement:()=>({dataset:{}}),head:{appendChild:s=>script=s}}});const app=vm.runInContext('({'+source.slice(source.indexOf('    async initPushNotifications(user)'),source.indexOf('\n};',source.indexOf('    async initPushNotifications(user)')))+'})',ctx);return{app,sdk,window,stats:()=>({requested,opted,initialized}),script:()=>script};}
test('push initializes once before permission and opts in after browser permission',async()=>{const s=setup();const a=s.app.initPushNotifications({id:'u'}),b=s.app.initPushNotifications({id:'u'});await s.window.OneSignalDeferred[0](s.sdk);assert.equal(await a,true);assert.equal(await b,true);assert.equal(await s.app.requestPushPermission(),true);assert.deepEqual(s.stats(),{initialized:1,requested:1,opted:1});});
test('script loading failure resolves initialization and reports a useful error without hanging',async()=>{const s=setup();const p=s.app.initPushNotifications({id:'u'});s.script().onerror();assert.equal(await p,false);await assert.rejects(s.app.requestPushPermission(),/no pudo cargar/);});
test('blocked browser permission is explained without prompting or claiming activation',async()=>{const s=setup();s.window.Notification.permission='denied';await assert.rejects(s.app.requestPushPermission(),/permisos de este sitio/);assert.equal(s.stats().requested,0);});
test('a cold click prepares service and asks for a fresh click instead of losing user activation',async()=>{const s=setup();const init=s.app.initPushNotifications({id:'u'});const click=s.app.requestPushPermission();await s.window.OneSignalDeferred[0](s.sdk);await init;await assert.rejects(click,/nuevamente/);assert.equal(s.stats().requested,0);});

test('el permiso concedido antes del login activa la suscripción al identificar al usuario', async () => {
  const s = setup();
  const pending = new Map([['sy-install-push-pending', '1']]);
  s.window.localStorage = {getItem: key => pending.get(key), removeItem: key => pending.delete(key)};
  s.window.Notification.permission = 'granted';
  const init = s.app.initPushNotifications({id: 'driver'});
  await s.window.OneSignalDeferred[0](s.sdk);
  assert.equal(await init, true);
  assert.equal(s.stats().opted, 1);
  assert.equal(pending.size, 0);
});

test('la app instalada solicita ambos permisos y avanza únicamente cuando ambos están concedidos', async () => {
  const storage = new Map();
  const nodes = new Map();
  const events = {};
  let dialogs = 0, pushes = 0, locations = 0, closed = 0;
  const dialog = {
    setAttribute() {}, remove() {}, showModal() { dialogs++; }, close() { closed++; events.close(); },
    addEventListener(name, callback) { events[name] = callback; },
    querySelector(selector) { const element = {}; nodes.set(selector, element); return element; }
  };
  const navigator = {standalone: false, geolocation: {getCurrentPosition(ok) { locations++; ok(); }}};
  const Notification = {permission: 'default', async requestPermission() { pushes++; Notification.permission='granted'; return 'granted'; }};
  const window = {navigator, Notification, addEventListener() {}, removeEventListener() {}, serveYourself: {}, localStorage: {
    getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value)
  }};
  const document = {getElementById() {}, createElement: () => dialog, body: {appendChild() {}}};
  const start = source.indexOf('async function showInstalledPermissions');
  const show = vm.runInNewContext('(' + source.slice(start, source.indexOf("window.addEventListener('load'", start)) + ')', {window, document, navigator, Notification});
  await show();
  assert.equal(dialogs, 0);
  navigator.standalone = true;
  await show();
  assert.deepEqual([dialogs, pushes, locations], [1, 0, 0]);
  await nodes.get('[data-permission="push"]').onclick();
  assert.deepEqual([pushes, locations], [1, 0]);
  assert.equal(closed, 0);
  nodes.get('[data-permission="location"]').onclick();
  assert.equal(locations, 1);
  assert.equal(closed, 1);
  assert.equal(nodes.has('[data-finish]'), false);
});
