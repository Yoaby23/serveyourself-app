/* Owner-only settings reuse the profile and its existing image storage policy. */
window.BusinessSettings = (() => {
    const days=['Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'];
    const $=id=>document.getElementById(id);
    const safeTime=(value,fallback)=>/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(value||'')?value:fallback;
    function load(profile) {
        $('cfg-business-name').value=profile.business_name||'';
        $('cfg-business-phone').value=profile.phone||'';
        $('cfg-business-preview').src=window.serveYourself.safeImageUrl(profile.avatar_url)||'logo.png';
        const fallback={closed:false,allDay:!profile.open_time,open:profile.open_time?.slice(0,5)||'09:00',close:profile.close_time?.slice(0,5)||'18:00'};
        const week=profile.business_hours||days.map(()=>({...fallback}));
        $('cfg-hours-mode').value=!week[0].closed&&week.every(d=>JSON.stringify(d)===JSON.stringify(week[0]))?'common':'daily';
        if(profile.business_hours){$('cfg-open-time').value=week[0].allDay?'':week[0].open||'';$('cfg-close-time').value=week[0].allDay?'':week[0].close||'';}
        $('cfg-weekdays').innerHTML=week.map((d,i)=>`<div class="business-day"><label><input id="day-${i}-enabled" type="checkbox" ${d.closed?'':'checked'}> ${days[i]}</label><label><input id="day-${i}-all" type="checkbox" ${d.allDay?'checked':''}> 24 horas</label><label>Apertura<input id="day-${i}-open" type="time" value="${safeTime(d.open,'09:00')}"></label><label>Cierre<input id="day-${i}-close" type="time" value="${safeTime(d.close,'18:00')}"></label></div>`).join('');
        $('cfg-weekdays').onchange=syncDays;
        syncDays();mode();
    }
    function syncDays(){for(let i=0;i<7;i++){const closed=!$(`day-${i}-enabled`).checked,allDay=$(`day-${i}-all`).checked;$(`day-${i}-all`).disabled=closed;$(`day-${i}-open`).disabled=closed||allDay;$(`day-${i}-close`).disabled=closed||allDay;}}
    function mode(){const daily=$('cfg-hours-mode').value==='daily';$('cfg-weekdays').hidden=!daily;$('cfg-common-hours').hidden=daily;}
    function values(){
        const daily=$('cfg-hours-mode').value==='daily',open=$('cfg-open-time').value,close=$('cfg-close-time').value;
        if(!daily&&Boolean(open)!==Boolean(close))throw Error('Indica apertura y cierre, o deja ambos vacíos para abrir 24 horas.');
        const hours=days.map((day,i)=>daily?{closed:!$(`day-${i}-enabled`).checked,allDay:$(`day-${i}-all`).checked,open:$(`day-${i}-open`).value,close:$(`day-${i}-close`).value}:{closed:false,allDay:!open,open,close});
        hours.forEach((d,i)=>{if(!d.closed&&!d.allDay&&(!d.open||!d.close||d.open===d.close))throw Error(`Revisa el horario de ${days[i]}. Para abrir todo el día marca 24 horas.`);});
        const name=$('cfg-business-name').value.trim(),phone=$('cfg-business-phone').value.trim();
        if(!name)throw Error('Indica el nombre del negocio.');
        if($('cfg-transfer').checked&&!window.SYRuntime.transferReceiptUrl(phone,{id:0,total:0}))throw Error('Registra un teléfono válido del negocio para recibir comprobantes. Incluye el código de país si no es de México.');
        return {business_name:name,phone,business_hours:hours,open_time:daily?null:open||null,close_time:daily?null:close||null};
    }
    async function uploadImage(db,id){
        const file=$('cfg-business-image').files[0];
        if(!file)return null;
        const formats={'image/jpeg':'jpg','image/png':'png','image/webp':'webp','image/avif':'avif'};
        if(!formats[file.type]||file.size>5*1024*1024)throw Error('Usa JPG, PNG, WebP o AVIF de hasta 5 MB.');
        const bitmap=await createImageBitmap(file);bitmap.close();
        const path=`${id}/business/${crypto.randomUUID()}.${formats[file.type]}`;
        const {error}=await db.storage.from('product-images').upload(path,file,{upsert:false,contentType:file.type});
        if(error)throw error;
        return {path,url:db.storage.from('product-images').getPublicUrl(path).data.publicUrl};
    }
    return {load,mode,values,uploadImage};
})();
