/* Runs in the document head, before paint, and shares one preference across all roles. */
(() => {
 const key='sy-theme',values=['system','light','dark'],media=window.matchMedia?.('(prefers-color-scheme: dark)');
 let preference='system';
 try{const saved=window.localStorage.getItem(key);if(values.includes(saved))preference=saved;}catch{}
 function apply(){
  const resolved=preference==='system'?(media?.matches?'dark':'light'):preference;
  document.documentElement.dataset.theme=resolved;
  document.documentElement.style.colorScheme=resolved;
  document.querySelectorAll('[data-sy-theme-select]').forEach(select=>{select.value=preference;});
  let meta=document.querySelector('meta[name="theme-color"]');
  if(!meta){meta=document.createElement('meta');meta.name='theme-color';document.head.appendChild(meta);}
  meta.content=resolved==='dark'?'#0b1120':'#f8fafc';
 }
 function set(value){if(!values.includes(value))return;preference=value;try{window.localStorage.setItem(key,value);}catch{}apply();}
 function mount(){
  document.querySelectorAll('[data-theme-setting]').forEach(container=>{
   if(container.querySelector('[data-sy-theme-select]'))return;
   const label=document.createElement('label');label.className='sy-config-field';label.textContent='Apariencia';
   const select=document.createElement('select');select.setAttribute('data-sy-theme-select','');select.setAttribute('aria-label','Apariencia');
   for(const [value,text] of [['system','Según el dispositivo'],['light','Claro'],['dark','Oscuro']]){const option=document.createElement('option');option.value=value;option.textContent=text;select.append(option);}
   select.value=preference;select.addEventListener('change',()=>set(select.value));label.append(select);container.append(label);
  });apply();
 }
 media?.addEventListener?.('change',()=>{if(preference==='system')apply();});
 window.addEventListener('storage',event=>{if(event.key===key){preference=values.includes(event.newValue)?event.newValue:'system';apply();}});
 window.addEventListener('pageshow',()=>{try{const saved=window.localStorage.getItem(key);preference=values.includes(saved)?saved:'system';}catch{}apply();});
 window.SYTheme={set,get:()=>preference,resolved:()=>document.documentElement.dataset.theme};
 apply();
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount,{once:true});else mount();
})();
