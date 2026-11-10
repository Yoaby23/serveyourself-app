/* One time picker for business hours and scheduled-order calendars. */
(() => {
    if (!('showPopover' in HTMLElement.prototype)) return;
    const controls=new WeakMap();let active=null,sequence=0;
    function enhance(input){
        if(controls.has(input))return;
        const wrapper=document.createElement('span');wrapper.className='sy-time';
        const trigger=document.createElement('button');trigger.type='button';trigger.className='sy-date-trigger';trigger.setAttribute('aria-haspopup','dialog');trigger.setAttribute('aria-expanded','false');
        const caption=document.createElement('span'),icon=document.createElement('span');icon.className='sy-time-icon';icon.setAttribute('aria-hidden','true');trigger.append(caption,icon);
        const panel=document.createElement('div');panel.className='sy-time-panel';panel.id='sy-time-'+(++sequence);panel.setAttribute('popover','auto');panel.setAttribute('role','dialog');trigger.setAttribute('aria-controls',panel.id);
        const error=document.createElement('span');error.hidden=true;error.className='sy-select-error';error.id=panel.id+'-error';error.setAttribute('role','alert');trigger.setAttribute('aria-describedby',error.id);
        input.before(wrapper);wrapper.append(input,trigger,panel,error);input.classList.add('sy-native-date');input.tabIndex=-1;input.setAttribute('aria-hidden','true');
        function sync(){const label=input.labels?.[0]?.cloneNode(true);label?.querySelectorAll('input,button,.sy-time').forEach(el=>el.remove());const name=input.getAttribute('aria-label')||label?.textContent.trim()||'Hora';caption.textContent=input.value||'Seleccionar hora';trigger.setAttribute('aria-label',name+', '+caption.textContent);panel.setAttribute('aria-label',name);trigger.disabled=input.disabled;trigger.setAttribute('aria-required',String(input.required));wrapper.hidden=input.hidden||input.classList.contains('hidden');const layout=[...input.classList].filter(name=>/^(?:[a-z]+:)*(?:w-|min-w-|max-w-|flex-|basis-|grow|shrink|col-|row-|self-|m[trblxy]?-|block)/.test(name));const classes='sy-time '+layout.join(' ');if(wrapper.className!==classes)wrapper.className=classes;if(input.validity.valid){error.hidden=true;error.textContent='';trigger.removeAttribute('aria-invalid');}}
        function close(){if(panel.isConnected&&panel.matches(':popover-open'))panel.hidePopover();trigger.setAttribute('aria-expanded','false');if(active===control)active=null;}
        function apply(value){const candidate=input.cloneNode();candidate.value=value;if(!candidate.validity.valid){error.hidden=false;error.textContent=candidate.validationMessage;trigger.setAttribute('aria-invalid','true');return;}input.value=value;input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));close();trigger.focus();}
        function button(text,action){const el=document.createElement('button');el.type='button';el.textContent=text;el.addEventListener('click',action);return el;}
        const control={close,input,panel};controls.set(input,control);
        trigger.addEventListener('click',()=>{
            if(panel.matches(':popover-open'))return close();active?.close();panel.replaceChildren();
            const title=document.createElement('strong');title.textContent='Seleccionar hora';panel.append(title);
            const fields=document.createElement('div');fields.className='sy-time-fields';
            function field(name,count,value){const label=document.createElement('label');label.textContent=name;const select=document.createElement('select');select.setAttribute('aria-label',name);for(let i=0;i<count;i++){const option=document.createElement('option');option.value=String(i).padStart(2,'0');option.textContent=option.value;select.append(option);}select.value=value||'00';label.append(select);fields.append(label);return select;}
            const parts=(input.value||input.min||'12:00').split(':');const hour=field('Hora',24,parts[0]),minute=field('Minuto',60,parts[1]);
            // Preserve second precision only for fields that explicitly support it.
            const seconds=Number(input.step)>0&&Number(input.step)<60||parts.length>2?field('Segundo',60,parts[2]):null;
            panel.append(fields);const footer=document.createElement('div');footer.className='sy-calendar-footer';const clear=button('Borrar',()=>apply(''));clear.disabled=input.required;footer.append(clear,button('Aplicar',()=>apply(hour.value+':'+minute.value+(seconds?':'+seconds.value:''))));panel.append(footer);
            const rect=trigger.getBoundingClientRect(),width=Math.min(300,innerWidth-24),below=innerHeight-rect.bottom-12,above=rect.top-12,up=below<220&&above>below;
            panel.style.width=width+'px';panel.style.left=Math.max(12,Math.min(rect.left,innerWidth-width-12))+'px';panel.style.top=up?'auto':rect.bottom+6+'px';panel.style.bottom=up?innerHeight-rect.top+6+'px':'auto';panel.style.maxHeight=Math.max(100,up?above:below)+'px';panel.showPopover();active=control;trigger.setAttribute('aria-expanded','true');footer.lastElementChild.focus();
        });
        panel.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();event.stopPropagation();close();trigger.focus();}});
        panel.addEventListener('toggle',()=>{if(!panel.matches(':popover-open')){trigger.setAttribute('aria-expanded','false');if(active===control)active=null;}});
        input.addEventListener('change',sync);input.addEventListener('focus',()=>trigger.focus());input.addEventListener('invalid',event=>{event.preventDefault();error.hidden=false;error.textContent=input.validationMessage;trigger.setAttribute('aria-invalid','true');trigger.focus();});input.form?.addEventListener('reset',()=>setTimeout(sync,0));
        for(const prop of ['value','valueAsDate','valueAsNumber']){const d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,prop);Object.defineProperty(input,prop,{configurable:true,get(){return d.get.call(this);},set(value){d.set.call(this,value);sync();}});}
        new MutationObserver(()=>{sync();close();}).observe(input,{attributes:true,attributeFilter:['class','hidden','disabled','min','max','required','step','value']});sync();
    }
    function scan(node){if(node.nodeType!==1)return;if(node.matches('input[type=time]'))enhance(node);node.querySelectorAll('input[type=time]').forEach(enhance);}
    function start(){scan(document.documentElement);new MutationObserver(records=>{if(active&&!active.input.isConnected)active.close();for(const r of records)for(const node of r.addedNodes)scan(node);}).observe(document.body,{subtree:true,childList:true});window.addEventListener('resize',()=>active?.close());window.addEventListener('scroll',event=>{if(active&&!active.panel.contains(event.target))active.close();},true);}
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
