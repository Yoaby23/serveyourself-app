/* Registration uploads only after authentication. Pending files stay on this device. */
window.BusinessImages=(() => {
 const formats={'image/jpeg':'jpg','image/png':'png','image/webp':'webp','image/avif':'avif'},memory=new Map(),running=new Map();
 async function validate(file){
  if(!file)return;
  if(!formats[file.type]||file.size>5*1024*1024)throw Error('Usa una imagen JPG, PNG, WebP o AVIF de hasta 5 MB.');
  const bitmap=await createImageBitmap(file);bitmap.close();
 }
 function database(){return new Promise((resolve,reject)=>{
  if(!window.indexedDB)return reject(Error('Almacenamiento local no disponible.'));
  const request=window.indexedDB.open('sy-registration-images',1);
  request.onupgradeneeded=()=>{const db=request.result;if(!db.objectStoreNames.contains('pending'))db.createObjectStore('pending',{keyPath:'id'});};
  request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);request.onblocked=()=>reject(Error('Cierra otras pestañas para conservar la imagen.'));
 });}
 async function transaction(mode,operation){const db=await database();try{return await new Promise((resolve,reject)=>{const tx=db.transaction('pending',mode),request=operation(tx.objectStore('pending'));let value;request.onsuccess=()=>value=request.result;tx.oncomplete=()=>resolve(value);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error||Error('No se pudo guardar la imagen local.'));});}finally{db.close();}}
 async function stage(id,file){
  if(!file)return {persistent:true};await validate(file);
  const item={id,file,path:`${id}/business/${crypto.randomUUID()}.${formats[file.type]}`};memory.set(id,item);
  try{await transaction('readwrite',store=>store.put(item));return {persistent:true};}catch{return {persistent:false};}
 }
 async function applyPending(db,user){
  if(!user?.id)return null;if(running.has(user.id))return running.get(user.id);
  const operation=(async()=>{
   let item=memory.get(user.id);if(!item){try{item=await transaction('readonly',store=>store.get(user.id));}catch{return null;}}
   if(!item)return null;
   const {data:{user:verified},error:authError}=await db.auth.getUser();if(authError||verified?.id!==user.id)throw authError||Error('La sesión terminó.');
   const {data:profile,error:profileError}=await db.from('profiles').select('role').eq('id',user.id).single();if(profileError)throw profileError;if(profile?.role!=='negocio')return null;
   await validate(item.file);
   const {error}=await db.storage.from('product-images').upload(item.path,item.file,{upsert:false,contentType:item.file.type});if(error&&String(error.statusCode)!=='409')throw error;
   const url=db.storage.from('product-images').getPublicUrl(item.path).data.publicUrl;
   const saved=await db.from('profiles').update({avatar_url:url}).eq('id',user.id).select('id').single();if(saved.error)throw saved.error;
   memory.delete(user.id);try{await transaction('readwrite',store=>store.delete(user.id));}catch{}
   return url;
  })();running.set(user.id,operation);try{return await operation;}finally{running.delete(user.id);}
 }
 function preview(input,output){let currentUrl;input.addEventListener('change',async()=>{
  const file=input.files[0];input.setCustomValidity('');if(currentUrl)URL.revokeObjectURL(currentUrl);output.hidden=true;
  if(!file)return;try{await validate(file);currentUrl=URL.createObjectURL(file);output.src=currentUrl;output.hidden=false;}catch(error){input.setCustomValidity(error.message);input.reportValidity();}
 });}
 return {validate,stage,applyPending,preview};
})();
