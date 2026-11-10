/* Keep native form values and change handlers while presenting an app-styled popup. */
(() => {
    if (!('showPopover' in HTMLElement.prototype)) return;
    const controls=new WeakMap();
    let active=null,sequence=0;
    function enhance(select){
        if(controls.has(select)||select.multiple||select.size>1)return;
        const wrapper=document.createElement('span');
        wrapper.className='sy-select';
        const button=document.createElement('button');
        button.type='button';button.className='sy-select-button';
        button.setAttribute('role','combobox');button.setAttribute('aria-haspopup','listbox');button.setAttribute('aria-expanded','false');
        const text=document.createElement('span');
        const arrow=document.createElement('span');arrow.className='sy-select-arrow';arrow.setAttribute('aria-hidden','true');
        button.append(text,arrow);
        const panel=document.createElement('div');
        panel.className='sy-select-list';panel.id='sy-select-list-'+(++sequence);panel.setAttribute('popover','auto');panel.setAttribute('role','listbox');
        button.setAttribute('aria-controls',panel.id);
        const message=document.createElement('span');message.className='sy-select-error';message.id=panel.id+'-error';message.hidden=true;message.setAttribute('role','alert');
        button.setAttribute('aria-describedby',message.id);
        select.before(wrapper);wrapper.append(select,button,panel,message);
        select.classList.add('sy-native-select');select.tabIndex=-1;select.setAttribute('aria-hidden','true');
        function clearError(){button.removeAttribute('aria-invalid');message.hidden=true;message.textContent='';}
        function sync(){
            if(active?.select===select)close();
            if(select.validity.valid)clearError();
            const layout=[...select.classList].filter(name=>/^(?:[a-z]+:)*(?:w-|min-w-|max-w-|flex-|basis-|grow|shrink|col-|row-|self-|m[trblxy]?-)/.test(name));
            const wrapperClass='sy-select '+layout.join(' ');
            if(wrapper.className!==wrapperClass)wrapper.className=wrapperClass;
            const value=select.selectedOptions[0]?.textContent||'';
            text.textContent=value;button.disabled=select.disabled;
            wrapper.hidden=select.hidden||select.classList.contains('hidden');
            const label=select.labels?.[0]?.cloneNode(true);
            label?.querySelectorAll('select,input,button,.sy-select').forEach(node=>node.remove());
            const caption=select.getAttribute('aria-label')||label?.textContent.trim()||'';
            button.setAttribute('aria-label',caption?caption+', '+value:value);
            panel.setAttribute('aria-label',caption||'Opciones');
            button.setAttribute('aria-required',String(select.required));
        }
        function close(){if(panel.isConnected&&panel.matches(':popover-open'))panel.hidePopover();button.setAttribute('aria-expanded','false');if(active===control)active=null;}
        function options(){return [...panel.querySelectorAll('[role=option]:not(:disabled)')];}
        function open(){
            if(button.disabled)return;
            active?.close();panel.replaceChildren();
            [...select.options].forEach((option,index)=>{
                if(option.hidden)return;
                const item=document.createElement('button');
                item.type='button';item.className='sy-select-option';item.setAttribute('role','option');item.setAttribute('aria-selected',String(option.selected));
                item.textContent=option.textContent;item.disabled=option.disabled||option.parentElement.disabled===true;
                item.addEventListener('click',()=>{
                    close();select.selectedIndex=index;clearError();
                    select.dispatchEvent(new Event('input',{bubbles:true}));select.dispatchEvent(new Event('change',{bubbles:true}));button.focus();
                });
                panel.append(item);
            });
            const rect=button.getBoundingClientRect();
            const below=innerHeight-rect.bottom-12,above=rect.top-12;
            const upward=below<180&&above>below;
            const height=Math.min(280,Math.max(80,upward?above:below));
            const width=Math.min(Math.max(rect.width,180),innerWidth-24);
            panel.style.width=width+'px';panel.style.maxHeight=height+'px';
            panel.style.left=Math.max(12,Math.min(rect.left,innerWidth-width-12))+'px';
            panel.style.top=upward?'auto':rect.bottom+6+'px';panel.style.bottom=upward?innerHeight-rect.top+6+'px':'auto';
            panel.showPopover();active=control;button.setAttribute('aria-expanded','true');
            const selected=panel.querySelector('[aria-selected=true]:not(:disabled)')||options()[0];selected?.focus();selected?.scrollIntoView({block:'nearest'});
        }
        const control={sync,close,select,panel};controls.set(select,control);
        button.addEventListener('click',()=>{panel.matches(':popover-open')?close():open();});
        button.addEventListener('keydown',event=>{if(['ArrowDown','ArrowUp','Home','End'].includes(event.key)){event.preventDefault();open();const items=options();(event.key==='End'?items.at(-1):event.key==='Home'?items[0]:panel.querySelector('[aria-selected=true]:not(:disabled)')||items[0])?.focus();}});
        let search='',searchedAt=0;
        panel.addEventListener('keydown',event=>{
            const items=options(),index=items.indexOf(document.activeElement);
            if(event.key==='Escape'){event.preventDefault();close();button.focus();return;}
            if(event.key==='Tab'){close();button.focus();return;}
            const steps={ArrowDown:1,ArrowUp:-1};
            if(event.key in steps){event.preventDefault();items[(index+steps[event.key]+items.length)%items.length]?.focus();}
            else if(event.key==='Home'||event.key==='End'){event.preventDefault();(event.key==='Home'?items[0]:items.at(-1))?.focus();}
            else if(event.key.length===1&&event.key!==' '){
                const now=Date.now();search=(now-searchedAt>700?'':search)+event.key.toLocaleLowerCase();searchedAt=now;
                items.find(item=>item.textContent.trim().toLocaleLowerCase().startsWith(search))?.focus();
            }
        });
        panel.addEventListener('toggle',()=>{if(!panel.matches(':popover-open')){button.setAttribute('aria-expanded','false');if(active===control)active=null;}});
        select.addEventListener('change',sync);select.addEventListener('focus',()=>button.focus());
        select.addEventListener('invalid',event=>{event.preventDefault();button.setAttribute('aria-invalid','true');message.textContent=select.validationMessage;message.hidden=false;button.focus();});
        select.form?.addEventListener('reset',()=>setTimeout(()=>{clearError();sync();},0));
        for(const property of ['value','selectedIndex']){
            const descriptor=Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,property);
            Object.defineProperty(select,property,{configurable:true,get(){return descriptor.get.call(this);},set(value){descriptor.set.call(this,value);sync();}});
        }
        sync();
    }
    function scan(node){
        if(node.nodeType!==1)return;
        if(node.matches('select'))enhance(node);
        node.querySelectorAll('select').forEach(enhance);
    }
    function start(){
        scan(document.documentElement);
        new MutationObserver(records=>{
            if(active&&!active.select.isConnected)active.close();
            for(const record of records){
                for(const node of record.addedNodes)scan(node);
                const select=record.target.nodeType===1?(record.target.matches('select')?record.target:record.target.closest('select')):record.target.parentElement?.closest('select');
                if(select)controls.get(select)?.sync();
            }
        }).observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['disabled','hidden','class','selected','label','required']});
        window.addEventListener('resize',()=>active?.close());
        window.addEventListener('scroll',event=>{if(active&&!active.panel.contains(event.target))active.close();},true);
    }
    if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
