/* Shared accessible dialogs. Server functions remain authoritative for totals and permissions. */
window.SYOrderTools=(()=>{
 const esc=value=>window.serveYourself.escapeHtml(value),money=value=>new Intl.NumberFormat('es-MX',{style:'currency',currency:'MXN'}).format(Number(value));
 function open(title,body,submit){
  const previous=document.activeElement,d=document.createElement('dialog');d.className='sy-order-dialog';
  d.innerHTML=`<form><header><h2 id="order-dialog-title">${esc(title)}</h2><button type="button" data-close aria-label="Cerrar">×</button></header><div class="sy-order-body">${body}</div><p data-error role="status"></p><footer><button type="button" data-close>Cancelar</button><button type="submit" class="sy-order-primary">Confirmar</button></footer></form>`;
  d.setAttribute('aria-labelledby','order-dialog-title');document.body.append(d);let busy=false;
  const status=d.querySelector('[data-error]'),button=d.querySelector('[type=submit]');
  d.querySelectorAll('[data-close]').forEach(b=>b.onclick=()=>{if(!busy)d.close()});
  d.addEventListener('cancel',e=>{if(busy)e.preventDefault()});
  d.addEventListener('close',()=>{d.remove();previous?.isConnected&&previous.focus({preventScroll:true})},{once:true});
  d.querySelector('form').onsubmit=async e=>{e.preventDefault();if(busy)return;busy=true;status.textContent='';d.querySelectorAll('button').forEach(b=>b.disabled=true);
   try{await submit(d);d.close()}catch(error){status.textContent=error.message||'No se pudo guardar. Reintenta.'}finally{busy=false;d.querySelectorAll('button').forEach(b=>b.disabled=false)}
  };d.showModal();return {d,status,button};
 }
 function splitGroups(items,count,read){
  if(!Number.isInteger(count)||count<2||count>10)throw Error('Selecciona entre 2 y 10 cuentas.');
  const groups=Array.from({length:count-1},()=>[]);let remainder=0;
  items.forEach((item,index)=>{let moved=0;groups.forEach((group,g)=>{const qty=Number(read(index,g));if(!Number.isInteger(qty)||qty<0)throw Error('Usa cantidades enteras, sin valores negativos.');if(qty)group.push({id:item.id,qty});moved+=qty});if(moved>Number(item.qty))throw Error(`La cantidad de ${item.nombre} supera los productos de la cuenta.`);remainder+=Number(item.qty)-moved});
  if(!remainder||groups.some(g=>!g.length))throw Error('Cada cuenta debe conservar al menos un producto.');return groups;
 }
 function split(db,order,actor,refresh){
  const {d}=open(`Dividir cuenta #${order.id}`,`<label>Número de cuentas<select data-count>${Array.from({length:9},(_,i)=>`<option value="${i+2}">${i+2} cuentas</option>`).join('')}</select></label><p>Distribuye las cantidades. Lo que no muevas permanecerá en la cuenta 1.</p><div data-items></div>`,async dialog=>{
   const count=Number(dialog.querySelector('[data-count]').value),groups=splitGroups(order.items,count,(i,g)=>dialog.querySelector(`[data-item="${i}"][data-group="${g}"]`).value);
   const payload={p_order_id:order.id,p_groups:groups,p_expected_items:order.items};
   await recordCashOperationOnce(db,sessionStorage,`sy-split:${actor}:${order.id}`,'split_order',payload);await refresh();
  });
  const count=d.querySelector('[data-count]'),items=d.querySelector('[data-items]');
  function render(){items.innerHTML=order.items.map((item,i)=>`<fieldset class="sy-split-item"><legend>${esc(item.nombre)} · ${Number(item.qty)} disponibles</legend><p data-left="${i}">Cuenta 1: ${Number(item.qty)}</p><div class="sy-split-targets">${Array.from({length:Number(count.value)-1},(_,g)=>`<label>Cuenta ${g+2}<input type="number" min="0" max="${Number(item.qty)}" step="1" value="0" data-item="${i}" data-group="${g}" required></label>`).join('')}</div></fieldset>`).join('')}
  count.onchange=render;items.oninput=()=>order.items.forEach((item,i)=>{const moved=[...items.querySelectorAll(`[data-item="${i}"]`)].reduce((n,f)=>n+Number(f.value),0);d.querySelector(`[data-left="${i}"]`).textContent=`Cuenta 1: ${Number(item.qty)-moved}`});render();
 }
 function coupons(db,id,refresh){
  const {d,status,button}=open(`Cupón · cuenta #${id}`,'<p data-loading>Consultando promociones disponibles…</p><div data-options></div>',async dialog=>{
   const selected=dialog.querySelector('input[name=coupon]:checked');if(!selected)throw Error('Selecciona un cupón.');
   const {error}=await db.rpc('apply_order_coupon',{p_order_id:id,p_code:selected.value});if(error)throw error;await refresh();
  });button.disabled=true;
  db.rpc('list_order_coupon_options',{p_order_id:id}).then(({data,error})=>{
   if(!d.isConnected)return;d.querySelector('[data-loading]').remove();if(error){status.textContent=error.message;return}
   const options=data||[];d.querySelector('[data-options]').innerHTML=options.length?options.map(c=>`<label class="sy-coupon-option"><input type="radio" name="coupon" value="${esc(c.code)}" required><span><b>${esc(c.code)}</b><small>${c.discount_type==='percent'?Number(c.discount_value)+'%':money(c.discount_value)} de descuento · ahorras ${money(c.discount_amount)}</small></span></label>`).join(''):'<p>No hay cupones vigentes para esta cuenta.</p>';button.disabled=!options.length;
  }).catch(()=>{if(d.isConnected)status.textContent='No se pudieron consultar los cupones. Cierra e intenta de nuevo.'});
 }
 function rating(db,id,refresh){
  let rating=0;const {d,button}=open('Califica tu pedido',`<div class="sy-rating-stars" role="group" aria-label="Selecciona de una a cinco estrellas">${[1,2,3,4,5].map(n=>`<button type="button" data-star="${n}" aria-label="${n} ${n===1?'estrella':'estrellas'}" aria-pressed="false"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m12 2 3.1 6.3 6.9 1-5 4.9 1.2 6.9-6.2-3.3-6.2 3.3 1.2-6.9-5-4.9 6.9-1Z"/></svg></button>`).join('')}</div><p data-rating>Selecciona las estrellas</p><label>Comentario (opcional)<textarea maxlength="1000" rows="3"></textarea></label>`,async dialog=>{
   if(!rating)throw Error('Selecciona las estrellas para calificar.');const {error}=await db.rpc('submit_rating',{p_order_id:id,p_rating:rating,p_comment:dialog.querySelector('textarea').value.trim()});if(error)throw error;await refresh();
  });button.disabled=true;d.querySelectorAll('[data-star]').forEach(star=>star.onclick=()=>{rating=Number(star.dataset.star);d.querySelectorAll('[data-star]').forEach(b=>{b.classList.toggle('is-selected',Number(b.dataset.star)<=rating);b.setAttribute('aria-pressed',String(Number(b.dataset.star)===rating))});d.querySelector('[data-rating]').textContent=`${rating} de 5 estrellas`;button.disabled=false});
 }
 return {split,coupons,rating,splitGroups};
})();
