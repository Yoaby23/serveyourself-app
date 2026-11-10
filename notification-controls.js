/* Reflect the current device permission and subscription without prompting. */
(() => {
 const subscribed=new WeakSet();
 function sync(){
  const sdk=window.serveYourself?._pushSDK,subscription=sdk?.User?.PushSubscription;
  const granted=window.Notification?.permission==='granted';
  // While the SDK loads, a granted browser permission needs no activation prompt.
  const active=granted&&subscription?.optedIn!==false;
  document.querySelectorAll('[data-sy-enable-notifications]').forEach(button=>{
   button.hidden=active;
   const card=button.closest('[data-sy-notification-prompt]');if(card)card.hidden=active;
  });
  if(subscription?.addEventListener&&!subscribed.has(subscription)){subscribed.add(subscription);subscription.addEventListener('change',sync);sdk.Notifications?.addEventListener?.('permissionChange',sync);}
 }
 function start(){sync();navigator.permissions?.query({name:'notifications'}).then(permission=>permission.addEventListener('change',sync)).catch(()=>{});}
 window.addEventListener('sy:push-state',sync);window.addEventListener('focus',sync);window.addEventListener('pageshow',sync);
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
