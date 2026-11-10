/* Address lookup is explicit: no requests while typing and no silent first-result choice. */
window.AddressLocation=class {
 constructor({input,button,results,status,onSelect,onInvalidate=()=>{}}){
  Object.assign(this,{input,button,results,status,onSelect,onInvalidate});this.cache=new Map();this.version=0;this.resolved=null;
  input.addEventListener('input',()=>{this.version++;this.abort?.abort();button.disabled=false;this.resolved=null;results.replaceChildren();status.textContent='';onInvalidate();});
  button.addEventListener('click',()=>this.search());
 }
 normalize(value){return String(value||'').trim().replace(/\s+/g,' ').toLocaleLowerCase();}
 setResolved(address,latitude,longitude){
  if(address&&latitude!==null&&longitude!==null&&Number.isFinite(Number(latitude))&&Number.isFinite(Number(longitude))){this.resolved={address:this.normalize(address),latitude:Number(latitude),longitude:Number(longitude)};}
 }
 point(){return this.resolved?.address===this.normalize(this.input.value)?this.resolved:null;}
 async search(){
  const address=this.input.value.trim(),key=this.normalize(address);const version=++this.version;
  this.abort?.abort();this.results.replaceChildren();this.resolved=null;this.onInvalidate();
  if(address.length<8){this.status.textContent='Escribe calle, número, colonia y ciudad para encontrar la dirección.';return;}
  this.button.disabled=true;this.status.textContent='Buscando dirección…';this.abort=new AbortController();const controller=this.abort;
  const timer=setTimeout(()=>controller.abort(),12000);
  try{
   let features=this.cache.get(key);
   if(!features){const url=new URL('https://photon.komoot.io/api/');url.searchParams.set('q',address);url.searchParams.set('limit','5');
    const response=await fetch(url,{signal:controller.signal,credentials:'omit',referrerPolicy:'no-referrer'});
    if(!response.ok)throw Error('No se pudo buscar la dirección. Intenta de nuevo.');
    const data=await response.json();features=(Array.isArray(data.features)?data.features:[]).filter(f=>f.geometry?.type==='Point'&&f.geometry.coordinates?.length>=2&&Number.isFinite(f.geometry.coordinates[0])&&Number.isFinite(f.geometry.coordinates[1])&&Math.abs(f.geometry.coordinates[0])<=180&&Math.abs(f.geometry.coordinates[1])<=90);this.cache.set(key,features);
   }
   if(version!==this.version)return;
   if(!features.length){this.status.textContent='No encontramos esa dirección. Revisa el número, la ciudad y el código postal.';return;}
   this.status.textContent='Selecciona la dirección que corresponde:';
   for(const feature of features){const p=feature.properties||{},label=[p.name,[p.street,p.housenumber].filter(Boolean).join(' '),p.district,p.postcode,p.city||p.town||p.village,p.state,p.country].filter(Boolean).filter((v,i,a)=>a.indexOf(v)===i).join(', ');
    const button=document.createElement('button');button.type='button';button.className='sy-address-result';button.textContent=label||address;
    button.addEventListener('click',()=>{if(version!==this.version||this.normalize(this.input.value)!==key)return;const [longitude,latitude]=feature.geometry.coordinates;this.setResolved(address,latitude,longitude);this.results.replaceChildren();this.status.textContent='Dirección ubicada: '+(label||address);this.onSelect({latitude,longitude,address});});this.results.append(button);
   }
  }catch(error){if(version===this.version)this.status.textContent=error.name==='AbortError'?'La búsqueda tardó demasiado. Vuelve a intentarlo.':error.message;}
  finally{clearTimeout(timer);if(version===this.version)this.button.disabled=false;}
 }
};
