/* Styled calendars retain the original native fields as the form's source of truth. */
(() => {
    if (!('showPopover' in HTMLElement.prototype)) return;
    const controls = new WeakMap();
    let active = null, sequence = 0;
    const iso = date => `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;
    const parse = value => /^\d{4}-\d{2}-\d{2}$/.test(value || '') ? new Date(value+'T12:00:00') : null;
    function enhance(input) {
        if (controls.has(input)) return;
        const timed = input.type === 'datetime-local';
        const wrapper = document.createElement('span'); wrapper.className = 'sy-date';
        const trigger = document.createElement('button'); trigger.type = 'button'; trigger.className = 'sy-date-trigger';
        trigger.setAttribute('aria-haspopup','dialog'); trigger.setAttribute('aria-expanded','false');
        const caption = document.createElement('span');
        const icon = document.createElement('span'); icon.className = 'sy-date-icon'; icon.setAttribute('aria-hidden','true');
        trigger.append(caption,icon);
        const panel = document.createElement('div'); panel.className = 'sy-calendar'; panel.id = 'sy-calendar-'+(++sequence);
        panel.setAttribute('popover','auto'); panel.setAttribute('role','dialog');
        trigger.setAttribute('aria-controls',panel.id);
        const error = document.createElement('span'); error.hidden = true; error.className='sy-select-error'; error.id=panel.id+'-error'; error.setAttribute('role','alert');
        trigger.setAttribute('aria-describedby',error.id);
        input.before(wrapper); wrapper.append(input,trigger,panel,error);
        input.classList.add('sy-native-date'); input.tabIndex=-1; input.setAttribute('aria-hidden','true');
        let month = new Date(), draft = '', focusDate = '';
        function clearError(){error.hidden=true;error.textContent='';trigger.removeAttribute('aria-invalid');}
        function sync(){
            const label=input.labels?.[0]?.cloneNode(true);
            label?.querySelectorAll('input,button,.sy-date').forEach(node=>node.remove());
            const name=input.getAttribute('aria-label') || label?.textContent.trim() || input.placeholder || (timed?'Fecha y hora':'Fecha');
            const date=parse(input.value.slice(0,10));
            const value=date ? date.toLocaleDateString('es-MX',{day:'2-digit',month:'2-digit',year:'numeric'})+(timed?' · '+input.value.slice(11,16):'') : 'Seleccionar fecha';
            caption.textContent=value; trigger.setAttribute('aria-label',name+', '+value); panel.setAttribute('aria-label',name);
            trigger.disabled=input.disabled;trigger.setAttribute('aria-required',String(input.required));
            wrapper.hidden=input.hidden||input.classList.contains('hidden');
            const layout=[...input.classList].filter(name=>/^(?:[a-z]+:)*(?:w-|min-w-|max-w-|flex-|basis-|grow|shrink|col-|row-|self-|m[trblxy]?-|block)/.test(name));
            const classes='sy-date '+layout.join(' ');if(wrapper.className!==classes)wrapper.className=classes;
            if(input.validity.valid)clearError();
        }
        function close(){if(panel.isConnected&&panel.matches(':popover-open'))panel.hidePopover();trigger.setAttribute('aria-expanded','false');if(active===control)active=null;}
        function allowed(value){return (!input.min||value>=input.min.slice(0,10))&&(!input.max||value<=input.max.slice(0,10));}
        function commit(value){
            const candidate=input.cloneNode(); candidate.value=value;
            if(!candidate.validity.valid){error.hidden=false;error.textContent=candidate.validationMessage;trigger.setAttribute('aria-invalid','true');return;}
            input.value=value; clearError(); input.dispatchEvent(new Event('input',{bubbles:true})); input.dispatchEvent(new Event('change',{bubbles:true}));close();trigger.focus();
        }
        function button(text,label,action){const el=document.createElement('button');el.type='button';el.textContent=text;if(label)el.setAttribute('aria-label',label);el.addEventListener('click',action);return el;}
        function draw(focus=false){
            panel.replaceChildren();
            const header=document.createElement('div');header.className='sy-calendar-header';
            const title=document.createElement('strong');title.setAttribute('aria-live','polite');title.textContent=month.toLocaleDateString('es-MX',{month:'long',year:'numeric'});
            function moveMonth(step){month=new Date(month.getFullYear(),month.getMonth()+step,1,12);focusDate=iso(month);draw(true);}
            header.append(button('‹','Mes anterior',()=>moveMonth(-1)),title,button('›','Mes siguiente',()=>moveMonth(1)));panel.append(header);
            const weekdays=document.createElement('div');weekdays.className='sy-calendar-weekdays';weekdays.setAttribute('aria-hidden','true');
            for(const day of ['lu','ma','mi','ju','vi','sá','do']){const el=document.createElement('span');el.textContent=day;weekdays.append(el);}panel.append(weekdays);
            const grid=document.createElement('div');grid.className='sy-calendar-days';grid.setAttribute('role','group');grid.setAttribute('aria-label','Días del mes');
            const start=new Date(month.getFullYear(),month.getMonth(),1,12);start.setDate(start.getDate()-(start.getDay()+6)%7);
            const target=focusDate || draft || iso(new Date());
            const cells=[];
            for(let i=0;i<42;i++){
                const date=new Date(start);date.setDate(start.getDate()+i);const value=iso(date);
                const cell=button(String(date.getDate()),date.toLocaleDateString('es-MX',{dateStyle:'full'}),()=>{
                    draft=value;focusDate=value;
                    if(timed)draw(true);else commit(value);
                });
                cell.dataset.date=value;cell.disabled=!allowed(value);cell.tabIndex=-1;
                if(date.getMonth()!==month.getMonth())cell.classList.add('sy-calendar-outside');
                if(value===draft)cell.setAttribute('aria-pressed','true');
                if(value===iso(new Date()))cell.setAttribute('aria-current','date');
                cell.addEventListener('keydown',event=>{
                    const offsets={ArrowLeft:-1,ArrowRight:1,ArrowUp:-7,ArrowDown:7};let next=new Date(date);
                    if(event.key in offsets)next.setDate(next.getDate()+offsets[event.key]);
                    else if(event.key==='Home')next.setDate(next.getDate()-(next.getDay()+6)%7);
                    else if(event.key==='End')next.setDate(next.getDate()+6-(next.getDay()+6)%7);
                    else if(event.key==='PageUp'||event.key==='PageDown'){next.setDate(1);next.setMonth(next.getMonth()+(event.key==='PageUp'?-1:1));}
                    else return;
                    event.preventDefault();const candidate=iso(next);if(!allowed(candidate))return;
                    focusDate=candidate;month=new Date(next.getFullYear(),next.getMonth(),1,12);draw(true);
                });grid.append(cell);cells.push(cell);
            }
            const selected=cells.find(el=>el.dataset.date===target&&!el.disabled)||cells.find(el=>!el.disabled&&!el.classList.contains('sy-calendar-outside'))||cells.find(el=>!el.disabled);
            if(selected)selected.tabIndex=0;panel.append(grid);
            let time;
            if(timed){const label=document.createElement('label');label.className='sy-calendar-time';label.textContent='Hora';time=document.createElement('input');time.type='time';time.value=input.value.slice(11,16)||'12:00';time.step=input.step||'60';
                if(draft===input.min.slice(0,10))time.min=input.min.slice(11);
                if(draft===input.max.slice(0,10))time.max=input.max.slice(11);
                label.append(time);panel.append(label);
                // Keep the draft time when navigating months or selecting another date.
                time.value=input.dataset.calendarTime || time.value;
                time.addEventListener('input',()=>{input.dataset.calendarTime=time.value;});
            }
            const footer=document.createElement('div');footer.className='sy-calendar-footer';
            const clear=button('Borrar',null,()=>commit(''));clear.disabled=input.required;
            const today=button('Hoy',null,()=>{const value=iso(new Date());draft=value;focusDate=value;month=new Date();if(timed)draw(true);else commit(value);});today.disabled=!allowed(iso(new Date()));footer.append(clear,today);
            if(timed)footer.append(button('Aplicar',null,()=>{if(draft&&time.value)commit(draft+'T'+time.value);else{error.hidden=false;error.textContent='Selecciona la fecha y la hora.';}}));
            panel.append(footer);if(focus)selected?.focus();
        }
        const control={close,input,panel};controls.set(input,control);
        trigger.addEventListener('click',()=>{
            if(panel.matches(':popover-open'))return close();active?.close();
            draft=input.value.slice(0,10);focusDate=draft;delete input.dataset.calendarTime;
            month=parse(draft)||parse(input.min.slice(0,10))||new Date();draw();
            const rect=trigger.getBoundingClientRect(),width=Math.min(328,innerWidth-24);
            panel.style.width=width+'px';panel.style.left=Math.max(12,Math.min(rect.left,innerWidth-width-12))+'px';
            const below=innerHeight-rect.bottom-12,above=rect.top-12,up=below<390&&above>below;
            panel.style.maxHeight=Math.max(100,Math.min(innerHeight-24,up?above:below))+'px';
            panel.style.top=up?'auto':rect.bottom+6+'px';panel.style.bottom=up?innerHeight-rect.top+6+'px':'auto';
            panel.showPopover();active=control;trigger.setAttribute('aria-expanded','true');panel.querySelector('[data-date][tabindex="0"]')?.focus();
        });
        panel.addEventListener('keydown',event=>{if(event.defaultPrevented)return;if(event.key==='Escape'){event.preventDefault();close();trigger.focus();}});
        panel.addEventListener('toggle',()=>{if(!panel.matches(':popover-open')){trigger.setAttribute('aria-expanded','false');if(active===control)active=null;}});
        input.addEventListener('change',sync);input.addEventListener('focus',()=>trigger.focus());
        input.addEventListener('invalid',event=>{event.preventDefault();error.hidden=false;error.textContent=input.validationMessage;trigger.setAttribute('aria-invalid','true');trigger.focus();});
        input.form?.addEventListener('reset',()=>setTimeout(sync,0));
        for(const prop of ['value','valueAsDate','valueAsNumber']){const descriptor=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,prop);Object.defineProperty(input,prop,{configurable:true,get(){return descriptor.get.call(this);},set(value){descriptor.set.call(this,value);sync();}});}
        new MutationObserver(()=>{sync();close();}).observe(input,{attributes:true,attributeFilter:['class','hidden','disabled','min','max','required','step','value']});sync();
    }
    function scan(node){if(node.nodeType!==1)return;if(node.matches('input[type=date],input[type=datetime-local]'))enhance(node);node.querySelectorAll('input[type=date],input[type=datetime-local]').forEach(enhance);}
    function start(){scan(document.documentElement);new MutationObserver(records=>{if(active&&!active.input.isConnected)active.close();for(const record of records)for(const node of record.addedNodes)scan(node);}).observe(document.body,{subtree:true,childList:true});window.addEventListener('resize',()=>active?.close());window.addEventListener('scroll',event=>{if(active&&!active.panel.contains(event.target))active.close();},true);}
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
