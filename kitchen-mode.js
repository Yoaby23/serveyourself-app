(() => {
 function create({db,restaurantId,button,status,onChange,onRefresh}) {
  let known=false,training=false,busy=false,version=0,orders=[];
  function report(text){status.textContent=text;button.title=text;}
  function render() {
   button.disabled=busy;button.setAttribute('aria-checked',String(known&&training));
   button.querySelector('[data-mode-state]').textContent=busy?'Guardando…':!known?'Comprobar':training?'Activado':'Desactivado';
   if(!known){report('Comprobando configuración de cocina…');return;}
   report(training?'Registra tiempos al comenzar y marcar listo. Desactiva Entrenamiento para aplicar lo aprendido.':orders.some(o=>o.model_ready)?'Estimaciones aprendidas y preparación conjunta activas.':'Aprende con tus pedidos; usa los tiempos configurados mientras reúne datos fiables.');
  }
  function accept(value){known=true;training=Boolean(value.training_mode);render();onChange?.(training);}
  async function load(){const request=++version;try{const {data,error}=await db.rpc('get_kitchen_mode',{p_restaurant_id:restaurantId});if(error)throw error;if(request!==version||busy)return;accept(data);}catch(error){if(request===version&&!busy){render();report('No se pudo verificar el modo de cocina. Pulsa Entrenamiento para reintentar.');}}}
  async function toggle(){if(busy)return;if(!known)return load();busy=true;++version;render();try{const {data,error}=await db.rpc('set_kitchen_mode',{p_restaurant_id:restaurantId,p_training_mode:!training});if(error)throw error;busy=false;accept(data);await onRefresh?.();}catch(error){busy=false;render();report('No se pudo guardar el modo. Se mantiene la configuración anterior.');}}
  button.onclick=toggle;render();return{load,toggle,updateOrders(value){orders=value||[];render();}};
 }
 window.SYKitchenMode={create};
})();
