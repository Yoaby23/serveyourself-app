import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../equipo.html',import.meta.url),'utf8');
const code=html.slice(html.indexOf("document.getElementById('invite-code').addEventListener"),html.indexOf('async function loadStaff'));
function setup(fail=false){
 let listener,finish,timer;const alerts=[];
 const gate=new Promise(resolve=>finish=resolve);
 const button={dataset:{code:'ABC123'},textContent:'ABC123',addEventListener(_,fn){listener=fn;}};
 vm.runInNewContext(code,{document:{getElementById:()=>button},navigator:{clipboard:{writeText:async()=>{await gate;if(fail)throw Error('Denied');}}},alert:m=>alerts.push(m),setTimeout:fn=>{timer=fn;}});
 return {button,alerts,finish,click:e=>listener(e),restore:()=>timer?.()};
}
test('copy keeps the button reference after event dispatch completes',async()=>{
 const ui=setup(),event={currentTarget:ui.button};const pending=ui.click(event);event.currentTarget=null;ui.finish();await pending;
 assert.equal(ui.button.textContent,'Copiado');ui.restore();assert.equal(ui.button.textContent,'ABC123');
});
test('clipboard rejection is handled without a false success',async()=>{
 const ui=setup(true);const pending=ui.click({currentTarget:ui.button});ui.finish();await pending;
 assert.equal(ui.alerts.length,1);assert.equal(ui.button.textContent,'ABC123');
});
test('a pending copy timer does not replace a newer invitation',async()=>{
 const ui=setup();const pending=ui.click({currentTarget:ui.button});ui.finish();await pending;
 ui.button.dataset.code='NEW456';ui.button.textContent='NEW456';ui.restore();assert.equal(ui.button.textContent,'NEW456');
});
