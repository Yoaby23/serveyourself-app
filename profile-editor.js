const profileApp=window.serveYourself;
let profileUser=null;
async function initProfile(){
 const get=id=>document.getElementById(id),status=get('profile-status');
 try{
  profileUser=await profileApp.requireUser();if(!profileUser)return;
  const mode=new URLSearchParams(window.location.search).get('mode');
  // Explicit personal mode remains personal even if this user also owns a business.
  const access=mode==='personal'?null:await profileApp.getRestaurantAccess();
  if(access)profileApp.renderRestaurantNavigation(access);else profileApp.renderPersonalNavigation();
  const context=access?'work':'personal';get('profile-return').href=access?'cuenta.html':'cuenta.html?mode=personal';get('profile-password').href='cambiar-contrasena.html?mode='+context;
  const {data,error}=await profileApp.supabase.from('profiles').select('full_name,phone,address').eq('id',profileUser.id).single();
  if(error||!data)throw error||Error('Perfil no disponible.');
  get('profile-email').value=profileUser.email||'';get('profile-name').value=data.full_name||'';get('profile-phone').value=data.phone||'';get('profile-address').value=data.address||'';
  status.textContent='';get('profile-save').disabled=false;
 }catch(error){status.textContent='No se pudo cargar tu perfil. Recarga para reintentar.';}
}
document.getElementById('profile-form').addEventListener('submit',async event=>{
 event.preventDefault();const get=id=>document.getElementById(id),button=get('profile-save'),status=get('profile-status');
 if(button.disabled||!profileUser)return;
 button.disabled=true;status.textContent='Guardando…';
 try{
  const updates={phone:get('profile-phone').value.trim(),address:get('profile-address').value.trim()};
  const {error}=await profileApp.supabase.from('profiles').update(updates).eq('id',profileUser.id).select('id').single();
  if(error)throw error;status.textContent='Perfil actualizado.';
 }catch(error){status.textContent=error.message||'No se pudo guardar el perfil.';}finally{button.disabled=false;}
});
initProfile();
