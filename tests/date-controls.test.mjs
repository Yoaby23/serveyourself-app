import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
const source=fs.readFileSync(new URL('../date-controls.js',import.meta.url),'utf8');
function setup({type='date',value='2026-11-10',min='',max='',required=false}={}){
 let focused=null;
 class Element {
  constructor(tag='div'){this.tag=tag;this.nodeType=1;this.children=[];this.attrs={};this.dataset={};this.events={};this.style={};this.className='';this.disabled=false;this.hidden=false;this.isConnected=true;}
  get classList(){const self=this;return{add(...names){self.className+=" "+names.join(' ');},contains(name){return self.className.split(' ').includes(name);},[Symbol.iterator]:function*(){yield* self.className.split(' ').filter(Boolean);}};}
  setAttribute(k,v){this.attrs[k]=String(v);}getAttribute(k){return this.attrs[k]??null;}removeAttribute(k){delete this.attrs[k];}
  append(...nodes){this.children.push(...nodes);}before(node){this.wrapper=node;}replaceChildren(...nodes){this.children=[...nodes];}
  addEventListener(type,fn){(this.events[type]??=[]).push(fn);}dispatchEvent(event){for(const fn of this.events[event.type]||[])fn(event);}
  matches(selector){if(selector===':popover-open')return this.open;return this instanceof Input;}
  querySelectorAll(selector){const all=this.children.flatMap(el=>[el,...el.querySelectorAll('*')]);return selector==='*'?all:all.filter(el=>el instanceof Input&&['date','datetime-local'].includes(el.type));}
  querySelector(){return this.querySelectorAll('*').find(el=>el.dataset.date&&el.tabIndex===0);}
  showPopover(){this.open=true;}hidePopover(){this.open=false;}focus(){focused=this;}
  getBoundingClientRect(){return{left:20,top:100,bottom:148};}
 }
 class Input extends Element{
  constructor(){super('input');this.type=type;this._value=value;this.min=min;this.max=max;this.required=required;this.step='';this.labels=[];}
  get value(){return this._value;}set value(v){this._value=v;}
  get valueAsDate(){return new Date(this.value);}set valueAsDate(v){this.value=v.toISOString().slice(0,10);}
  get valueAsNumber(){return Date.parse(this.value);}set valueAsNumber(v){this.value=new Date(v).toISOString().slice(0,10);}
  get validity(){return{valid:!(this.required&&!this.value)&&(!this.value||(!this.min||this.value>=this.min)&&(!this.max||this.value<=this.max))};}
  get validationMessage(){return 'Fuera del intervalo permitido';}
  cloneNode(){const clone=new Input();clone._value=this._value;return clone;}
 }
 const input=new Input();
 const document={readyState:'complete',documentElement:{nodeType:1,matches:()=>false,querySelectorAll:()=>[input]},body:new Element(),createElement:tag=>tag==='input'?new Input():new Element(tag)};
 class Observer{observe(){}}
 vm.runInNewContext(source,{document,HTMLElement:Element,HTMLInputElement:Input,MutationObserver:Observer,Event:class{constructor(type){this.type=type;}},window:{addEventListener(){}},innerWidth:800,innerHeight:800,Date,setTimeout});
 // Presence of showPopover is the feature-detection contract.
 const wrapper=input.wrapper,trigger=wrapper.children[1],panel=wrapper.children[2];
 const click=el=>el.dispatchEvent({type:'click'});
 const nodes=()=>panel.querySelectorAll('*');
 return{input,trigger,panel,wrapper,click,nodes,focus:()=>focused};
}
test('calendar selection preserves the native value and emits existing form events',()=>{
 const s=setup();let changes=0;s.input.addEventListener('change',()=>changes++);
 s.click(s.trigger);assert.equal(s.panel.open,true);
 const day=s.nodes().find(el=>el.dataset.date==='2026-11-15');s.click(day);
 assert.equal(s.input.value,'2026-11-15');assert.equal(changes,1);assert.equal(s.panel.open,false);assert.equal(s.focus(),s.trigger);
 s.input.value='2026-12-02';assert.match(s.trigger.children[0].textContent,/02\/12\/2026/);
});
test('calendar enforces min/max and required fields and supports keyboard movement',()=>{
 const s=setup({min:'2026-11-09',max:'2026-11-20',required:true});s.click(s.trigger);
 assert.equal(s.nodes().find(el=>el.dataset.date==='2026-11-08').disabled,true);
 assert.equal(s.nodes().find(el=>el.textContent==='Borrar').disabled,true);
 const day=s.nodes().find(el=>el.dataset.date==='2026-11-10');day.dispatchEvent({type:'keydown',key:'ArrowRight',preventDefault(){}});
 assert.equal(s.focus().dataset.date,'2026-11-11');
 s.panel.dispatchEvent({type:'keydown',key:'Escape',preventDefault(){}});assert.equal(s.panel.open,false);assert.equal(s.input.value,'2026-11-10');
});
test('scheduled date applies only a valid combined date and time',()=>{
 const s=setup({type:'datetime-local',value:'2026-11-10T12:00',min:'2026-11-10T10:00',max:'2026-11-10T18:00'});s.click(s.trigger);
 const time=s.nodes().find(el=>el.tag==='input');time.value='09:00';s.click(s.nodes().find(el=>el.textContent==='Aplicar'));
 assert.equal(s.input.value,'2026-11-10T12:00');assert.equal(s.panel.open,true);
 time.value='16:30';s.click(s.nodes().find(el=>el.textContent==='Aplicar'));assert.equal(s.input.value,'2026-11-10T16:30');assert.equal(s.panel.open,false);
});
