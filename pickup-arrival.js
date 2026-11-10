(() => {
 function eligible(order){return order.service_type==='pickup'&&Boolean(order.scheduled_for)&&order.payment_status==='approved'&&!['entregado','cancelado'].includes(order.status);}
 function create({db,root=document,geo=navigator.geolocation,permissions=navigator.permissions,storage=localStorage}) {
  const key='sy-pickup-arrival-order';let orders=[],active=null,busy=false,timer=null,generation=0,sending=false,lastSent=0,stopPending=null;
  const messages=new Map(),transports=new Map();
  function stored(){try{return storage.getItem(key);}catch{return null;}}
  function remember(id){try{if(id)storage.setItem(key,String(id));else storage.removeItem(key);}catch{}}
  function orderFor(id){return orders.find(o=>String(o.id)===String(id)&&eligible(o));}
  function containers(){return root.querySelectorAll('[data-pickup-arrival]');}
  function render(){for(const box of containers()){
   const id=String(box.dataset.pickupArrival),button=box.querySelector('[data-share-pickup]'),sharing=String(active)===id;
   const select=box.querySelector('[data-pickup-transport]');if(select)select.value=transports.get(id)||orders.find(o=>String(o.id)===id)?.pickup_transport||'car';
   button.disabled=busy;button.setAttribute('aria-pressed',String(sharing));button.textContent=stopPending===id?'Reintentar detener ubicación':sharing?'Dejar de compartir llegada':'Voy en camino';
   box.querySelector('[data-pickup-arrival-status]').textContent=messages.get(id)||'Comparte tu llegada para que cocina ajuste el inicio de preparación. Mantén la app abierta; el tiempo es aproximado.';
  }}
  function message(id,text){messages.set(String(id),text);render();}
  function pause(){++generation;clearInterval(timer);timer=null;}
  async function stop(id=active){if(!id)return;pause();active=null;remember(null);render();
   let error;try{({error}=await db.rpc('set_pickup_location_sharing',{p_order_id:Number(id),p_enabled:false}));}catch(caught){error=caught;}
   if(error){stopPending=String(id);message(id,'Se detuvo la ubicación en este dispositivo. Reintenta para confirmar la desactivación con el negocio.');}
   else{stopPending=null;message(id,'Ubicación desactivada. Se usará el horario programado.');}
  }
  async function send(id,position,token){
   if(token!==generation||String(active)!==String(id)||sending||Date.now()-lastSent<15000)return;
   const {latitude,longitude,accuracy}=position.coords;
   if(!Number.isFinite(accuracy)||accuracy>100){message(id,'La ubicación no es suficientemente precisa. Se mantiene el horario programado.');return;}
   const box=[...containers()].find(b=>String(b.dataset.pickupArrival)===String(id));const transport=transports.get(String(id))||box?.querySelector('[data-pickup-transport]')?.value||'car';
   sending=true;
   try{const {data,error}=await db.rpc('update_pickup_arrival',{p_order_id:Number(id),p_latitude:latitude,p_longitude:longitude,p_accuracy:accuracy,p_observed_at:new Date(position.timestamp).toISOString(),p_transport:transport});
    if(token!==generation)return;
    if(error)throw error;lastSent=Date.now();message(id,Number(data.eta_minutes)===0?'Llegaste al restaurante. Cocina ya tiene tu ubicación.':`Llegada aproximada en ${Number(data.eta_minutes)} min. Cocina ajusta la preparación según tu llegada.`);
   }catch(error){if(token===generation)message(id,'No se pudo actualizar tu llegada. Se usará el horario programado si la ubicación deja de estar disponible.');}
   finally{sending=false;}
  }
  function locate(id,token){if(token!==generation||root.visibilityState==='hidden'||!geo)return;
   geo.getCurrentPosition(position=>send(id,position,token),async error=>{if(token!==generation)return;if(error.code===1){await stop(id);message(id,'Ubicación no autorizada. Tu pickup conserva el horario programado.');}else message(id,'No se pudo obtener tu ubicación. Reintentando; se conserva el horario programado sin señal reciente.');},{enableHighAccuracy:true,maximumAge:15000,timeout:10000});
  }
  async function start(id,{resume=false}={}){
   if(busy||!orderFor(id))return;
   if(!geo){message(id,'Este dispositivo no permite compartir ubicación. Se conserva el horario programado.');return;}
   busy=true;render();
   try{
    if(resume){let allowed=false;try{allowed=(await permissions?.query({name:'geolocation'}))?.state==='granted';}catch{}if(!allowed){message(id,'Pulsa Voy en camino para volver a compartir tu llegada.');return;}}
    if(active&&String(active)!==String(id))await stop(active);
    const {error}=await db.rpc('set_pickup_location_sharing',{p_order_id:Number(id),p_enabled:true});if(error)throw error;
    pause();active=String(id);stopPending=null;remember(id);lastSent=0;
    const token=generation;message(id,'Obteniendo tu ubicación para estimar la llegada…');locate(id,token);timer=setInterval(()=>locate(id,token),30000);
   }catch(error){message(id,error.message||'No se pudo compartir tu llegada. Reintenta.');}
   finally{busy=false;render();}
  }
  async function toggle(id){if(busy)return;if(stopPending===String(id)||String(active)===String(id)){busy=true;render();try{await stop(id);}finally{busy=false;render();}}else await start(id);}
  root.addEventListener('click',event=>{const button=event.target.closest('[data-share-pickup]');if(button)toggle(button.dataset.sharePickup);});
  root.addEventListener('change',event=>{if(!event.target.matches('[data-pickup-transport]'))return;const id=String(event.target.closest('[data-pickup-arrival]').dataset.pickupArrival);transports.set(id,event.target.value);if(String(active)===id){lastSent=0;locate(active,generation);}});
  root.addEventListener('visibilitychange',()=>{if(root.visibilityState==='hidden')pause();else if(active){const id=active;active=null;start(id,{resume:true});}});
  window.addEventListener('pagehide',pause);
  window.addEventListener('pageshow',()=>{if(!timer&&active){const id=active;active=null;start(id,{resume:true});}});
  return{start,stop,toggle,async setOrders(value){orders=value||[];if(active&&!orderFor(active)){pause();remember(null);active=null;}render();const id=stored();if(!active&&id&&orderFor(id)&&root.visibilityState!=='hidden')await start(id,{resume:true});else if(id&&!orderFor(id))remember(null);}};
 }
 window.SYPickupArrival={create,eligible};
})();
