import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../app.js',import.meta.url),'utf8');
const method=source.slice(source.indexOf('    goBack('),source.indexOf('    requestBack()')).trim().replace(/,$/,'');
function run(referrer,length){let back=0;const location={origin:'https://app.test',href:'https://app.test/cuenta.html'};const context={document:{referrer},window:{location,history:{length,back(){back++;}}},URL};vm.runInNewContext(`({${method}}).goBack('funciones.html')`,context);return {back,href:location.href};}
test('back returns to actual same-origin history',()=>{assert.equal(run('https://app.test/equipo.html',2).back,1);});
test('external entry never sends the user outside the app',()=>{assert.deepEqual(run('https://external.test',4),{back:0,href:'funciones.html'});});
test('direct entry and empty history use safe fallback',()=>{assert.equal(run('',1).href,'funciones.html');assert.equal(run('https://app.test/menu.html',1).back,0);});

test('back skips authentication screens to avoid redirect loops',()=>{for(const page of ['index.html','registro.html','recuperar.html'])assert.equal(run('https://app.test/'+page,3).href,'funciones.html');});
