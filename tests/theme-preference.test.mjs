import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';import vm from 'node:vm';
const source=fs.readFileSync(new URL('../theme.js',import.meta.url),'utf8');
function setup(saved='system',dark=false){
 const store=new Map([['sy-theme',saved]]),events={},media={matches:dark,addEventListener:(name,fn)=>events.media=fn},root={dataset:{},style:{}},meta={};
 const document={documentElement:root,readyState:'loading',querySelectorAll:()=>[],querySelector:()=>meta,addEventListener:(name,fn)=>events[name]=fn};
 const window={localStorage:{getItem:key=>store.get(key),setItem:(key,value)=>store.set(key,value)},matchMedia:()=>media,addEventListener:(name,fn)=>events[name]=fn};
 vm.runInNewContext(source,{window,document});return{window,root,meta,media,events,store};
}
test('saved dark preference applies before content renders, regardless of system theme',()=>{const s=setup('dark',false);assert.equal(s.root.dataset.theme,'dark');assert.equal(s.root.style.colorScheme,'dark');assert.equal(s.meta.content,'#0b1120');});
test('system preference follows device changes without overwriting the preference',()=>{const s=setup('system',false);assert.equal(s.root.dataset.theme,'light');s.media.matches=true;s.events.media();assert.equal(s.root.dataset.theme,'dark');assert.equal(s.store.get('sy-theme'),'system');});
test('explicit light selection stays light when the system changes to dark',()=>{const s=setup('system',false);s.window.SYTheme.set('light');s.media.matches=true;s.events.media();assert.equal(s.root.dataset.theme,'light');assert.equal(s.store.get('sy-theme'),'light');});
test('other tabs update their palette when the shared preference changes',()=>{const s=setup('light');s.events.storage({key:'sy-theme',newValue:'dark'});assert.equal(s.root.dataset.theme,'dark');assert.equal(s.window.SYTheme.get(),'dark');});
test('invalid preferences fall back to the system and storage failures do not block rendering',()=>{const s=setup('unknown',true);assert.equal(s.root.dataset.theme,'dark');s.window.localStorage.setItem=()=>{throw Error('blocked');};s.window.SYTheme.set('light');assert.equal(s.root.dataset.theme,'light');});
