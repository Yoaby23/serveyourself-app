(() => {
 function create({db,restaurantId,button,title,status,onChange,onRefresh}) {
  let known=false,training=false,busy=false,version=0,orders=[];
  function render() {
   button.disabled=busy;button.setAttribute('aria-checked',String(known&&training));
   button.querySelector('[data-mode-state]').textContent=busy?'Guardando…':!known?'Comprobar':training?'Activado':'Desactivado';
   title.textContent=known&&training?'Entrenando con tus pedidos':'Cocina automática';
   if(!known){status.textContent='Comprobando configuración de cocina…';return;}
   status.textContent=training?'Registra tiempos al comenzar y marcar listo. Desactiva Entrenamiento para aplicar lo aprendido.':orders.some(o=>o.model_ready)?'Estimaciones aprendidas y preparación conjunta activas.':'Aprende con tus pedidos; usa los tiempos configurados mientras reúne datos fiables.';
  }
  function accept(value){known=true;training=Boolean(value.training_mode);render();onChange?.(training);}
  async function load(){const request=++version;try{const {data,error}=await db.rpc('get_kitchen_mode',{p_restaurant_id:restaurantId});if(error)throw error;if(request!==version||busy)return;accept(data);}catch(error){if(request===version&&!busy){render();status.textContent='No se pudo verificar el modo de cocina. Pulsa Entrenamiento para reintentar.';}}}
  async function toggle(){if(busy)return;if(!known)return load();busy=true;++version;render();try{const {data,error}=await db.rpc('set_kitchen_mode',{p_restaurant_id:restaurantId,p_training_mode:!training});if(error)throw error;busy=false;accept(data);await onRefresh?.();}catch(error){busy=false;render();status.textContent='No se pudo guardar el modo. Se mantiene la configuración anterior.';}}
  button.onclick=toggle;render();return{load,toggle,updateOrders(value){orders=value||[];render();}};
 }
 window.SYKitchenMode={create};
})();
