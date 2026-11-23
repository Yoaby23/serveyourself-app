/* Variations are sellable product IDs, so prices and kitchen stations stay server-authoritative. */
window.ProductVariations=(()=>{
 const available=p=>p&&p.is_available!==false&&!p.is_archived;
 function sellable(p,rows){return Boolean(available(p)&&!p.has_variations&&(!p.parent_product_id||rows.some(r=>r.id===p.parent_product_id&&available(r)&&r.has_variations)))}
 function catalog(rows){return rows.filter(p=>!p.parent_product_id&&!p.is_archived).map(p=>{
  const variants=rows.filter(v=>v.parent_product_id===p.id&&!v.is_archived).map(v=>({...v,is_available:available(p)&&available(v)}));
  const enabled=variants.filter(available);return {...p,variants,is_available:available(p)&&(!p.has_variations||enabled.length>0),price:p.has_variations&&enabled.length?Math.min(...enabled.map(v=>Number(v.price))):p.price};
 })}
 function choose(id,rows,add){
  const p=catalog(rows).find(p=>p.id===id);if(!p||!p.is_available)return;
  if(!p.has_variations){if(sellable(p,rows))add(id);return}
  const esc=window.serveYourself.escapeHtml,money=n=>Number(n).toLocaleString('es-MX',{style:'currency',currency:'MXN'}),previous=document.activeElement;
  const d=document.createElement('dialog');d.className='sy-order-dialog';d.setAttribute('aria-label','Elige una variación de '+p.name);
  d.innerHTML=`<form><header><h2>${esc(p.name)}</h2><button type="button" data-close aria-label="Cerrar">×</button></header><p>Elige tu presentación</p><div class="sy-variation-options">${p.variants.map(v=>`<label class="sy-coupon-option"><input type="radio" name="variation" value="${esc(v.id)}" required ${v.is_available?'':'disabled'}><span><b>${esc(v.variation_name)}</b><small>${v.is_available?money(v.price):'Agotado'}</small></span></label>`).join('')}</div><p data-error role="status"></p><footer><button type="button" data-close>Cancelar</button><button type="submit" class="sy-order-primary">Agregar al pedido</button></footer></form>`;
  document.body.append(d);d.querySelectorAll('[data-close]').forEach(b=>b.onclick=()=>d.close());d.addEventListener('close',()=>{d.remove();if(previous?.isConnected)previous.focus({preventScroll:true})},{once:true});
  d.querySelector('form').onsubmit=e=>{e.preventDefault();const id=d.querySelector('input[name=variation]:checked')?.value;
   if(!sellable(rows.find(v=>v.id===id),rows)){d.querySelector('[data-error]').textContent='Esta opción ya no está disponible. Elige otra.';return}add(id);d.close();
  };d.showModal();
 }
 function editor(container){
  const esc=value=>window.serveYourself.escapeHtml(value);let values=[];
  function render(){container.innerHTML=values.map((v,i)=>`<div class="sy-variation-row"><label>Variación<input data-name="${i}" type="text" maxlength="80" placeholder="Ej. Grande" value="${esc(v.name)}" required></label><label>Precio ($)<input data-price="${i}" type="number" min="0.01" max="999999" step="0.01" inputmode="decimal" value="${esc(v.price)}" required></label><label class="sy-variation-stock"><input data-stock="${i}" type="checkbox" ${v.is_available?'checked':''}>Disponible</label><button type="button" data-remove="${i}" class="sy-action-danger" aria-label="Eliminar variación ${esc(v.name||String(i+1))}">Eliminar</button></div>`).join('');container.dispatchEvent(new Event('variationschange',{bubbles:true}))}
  container.addEventListener('input',e=>{const field=e.target;if(field.dataset.name!==undefined)values[Number(field.dataset.name)].name=field.value;if(field.dataset.price!==undefined)values[Number(field.dataset.price)].price=field.value;if(field.dataset.stock!==undefined)values[Number(field.dataset.stock)].is_available=field.checked});
  container.addEventListener('click',e=>{const button=e.target.closest('[data-remove]');if(button){values.splice(Number(button.dataset.remove),1);render()}});
  return {set(rows){values=rows.map(v=>({id:v.id,name:v.variation_name,price:v.price,is_available:v.is_available}));render()},add(){if(values.length>=50)return;values.push({id:crypto.randomUUID(),name:'',price:'',is_available:true});render();container.querySelector('[data-name="'+(values.length-1)+'"]').focus()},get(){const seen=new Set();return values.map(v=>{const name=v.name.trim().replace(/\s+/g,' '),price=Number(v.price),key=name.toLocaleLowerCase();if(!name||name.length>80||seen.has(key)||!Number.isFinite(price)||price<=0||price>999999)throw Error('Cada variación necesita un nombre único y un precio mayor a cero.');seen.add(key);return {...v,name,price}})},count(){return values.length}};
 }
 return {catalog,sellable,choose,editor};
})();
