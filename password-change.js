const form=document.getElementById('password-form'),result=document.getElementById('result');
const passwordMode=new URLSearchParams(window.location.search).get('mode')==='personal'?'personal':'work';
const passwordReturn='perfil.html?mode='+passwordMode;
const cancel=document.getElementById('password-cancel');cancel.href=passwordReturn;
cancel.addEventListener('click',event=>{event.preventDefault();window.serveYourself.goBack(passwordReturn);});
form.onsubmit=async event=>{
 event.preventDefault();
 const button=form.querySelector('button'),password=document.getElementById('new-password').value;
 if(button.disabled)return;
 if(password!==document.getElementById('confirm-password').value){result.textContent='Las contraseñas nuevas deben coincidir.';return;}
 button.disabled=true;result.textContent='Guardando contraseña…';let changed=false;
 const isolated=window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
 try{
  const {data:{user},error:userError}=await window.serveYourself.supabase.auth.getUser();
  if(userError||!user?.email)throw new Error('Inicia sesión para cambiar tu contraseña.');
  const {data,error}=await isolated.auth.signInWithPassword({email:user.email,password:document.getElementById('current-password').value});
  if(error||data.user?.id!==user.id)throw new Error('La contraseña actual no es correcta.');
  const {error:updateError}=await isolated.auth.updateUser({password});
  if(updateError)throw updateError;
  form.reset();changed=true;result.textContent='Contraseña actualizada.';
 }catch(error){result.textContent=error.message;}
 finally{try{await isolated.auth.signOut({scope:'local'});}catch{}button.disabled=false;}
 if(changed)window.serveYourself.goBack(passwordReturn);
};
