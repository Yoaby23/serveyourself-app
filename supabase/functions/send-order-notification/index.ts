import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';

type Notice = { message: string; path: string };
type Event = { id: string; order_id: number; ticket_id: number | null; kind: string; state: string };
type Order = { id: number; restaurant_id: string; restaurant_name: string; customer_id: string | null; created_by: string | null; order_source: string; service_type: string; status: string; payment_status: string; payment_before_kitchen: boolean; payment_method: string; delivery_status: string | null; assigned_driver_id: string | null; pickup_name: string | null };
const deliveryMessages: Record<string, string> = {
  pending_acceptance: 'El restaurante recibió tu pedido a domicilio.', accepted: 'El restaurante aceptó tu pedido.',
  preparing: 'Tu pedido se está preparando.', ready_for_dispatch: 'Tu pedido está listo para reparto.',
  picked_up: 'El repartidor recogió tu pedido.', on_the_way: 'Tu pedido va en camino.',
  arrived: 'El repartidor llegó a tu domicilio.', delivered: 'Tu pedido fue entregado.', cancelled: 'Tu pedido fue cancelado.'
};
const paymentMessages: Record<string, string> = {approved:'Pago confirmado.',refunded:'Se registró el reembolso.',expired:'El plazo para pagar terminó.',rejected:'El pago fue rechazado.'};

function createWorkerClient() {
  return createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
}

async function buildNotices(db: ReturnType<typeof createWorkerClient>, event: Event, order: Order) {
  const notices = new Map<string, Notice>();
  const add = (id: string | null, message: string, path: string) => { if (id) notices.set(id,{message,path}); };
  const customerPath = order.service_type === 'delivery' ? `/delivery-tracking.html?id=${order.id}` : '/menu.html?section=pedidos';
  const customer = (message: string) => add(order.customer_id, `Pedido #${order.id}: ${message}`, customerPath);
  async function staff(permission: string, message: string, path: string) {
    const {data,error} = await db.from('restaurant_staff').select('user_id').eq('restaurant_id',order.restaurant_id).eq('is_active',true).eq(permission,true);
    if (error) throw error;
    add(order.restaurant_id,message,path);
    for (const person of data || []) add(person.user_id,message,path);
  }
  if (event.kind === 'order' && order.status === 'cancelado') {
    const detail = paymentMessages[order.payment_status];
    customer(detail && order.payment_status !== 'approved' ? `Pedido cancelado. ${detail}` : 'Pedido cancelado.');
    if (order.order_source === 'pos') add(order.created_by,`Cuenta #${order.id} cancelada.`, '/pos.html');
    add(order.assigned_driver_id,`Entrega #${order.id} cancelada.`, '/repartidor.html');
    return notices;
  }
  if (order.status === 'cancelado') return notices;
  if (event.kind === 'cashier' && order.payment_status === 'pending') {
    const action = order.payment_method === 'transfer' ? 'validar transferencia' : 'cobrar en caja';
    await staff('can_close_accounts',`Pedido para llevar #${order.id}: ${action}.`, '/caja.html#pickup');
  } else if (event.kind === 'payment' && order.payment_status === event.state && paymentMessages[event.state]) {
    customer(paymentMessages[event.state]);
  } else if (event.kind === 'driver' && order.assigned_driver_id === event.state) {
    add(order.assigned_driver_id,`Tienes asignada la entrega #${order.id}.`, '/repartidor.html');
  } else if (event.kind === 'delivery' && order.delivery_status === event.state && deliveryMessages[event.state]) {
    customer(deliveryMessages[event.state]);
    if (event.state === 'pending_acceptance') await staff('can_manage_delivery',`Pedido a domicilio #${order.id} pendiente de aceptación.`, '/delivery.html');
    if (event.state === 'ready_for_dispatch') add(order.assigned_driver_id,`Pedido #${order.id} listo para recoger.`, '/repartidor.html');
    if (event.state === 'accepted' && !order.assigned_driver_id) {
      const {data,error}=await db.rpc('team_drivers_for_push', {p_restaurant_id:order.restaurant_id});
      if(error) throw error;
      for(const driver of data || []) add(driver.user_id,`Entrega #${order.id} disponible en ${order.restaurant_name}.`, '/repartidor.html');
    }
  } else if (event.kind === 'ticket') {
    const {data:ticket,error}=await db.from('kitchen_tickets').select('id,status').eq('id',event.ticket_id).eq('order_id',order.id).maybeSingle();
    if(error) throw error;
    if(!ticket || ticket.status !== event.state || (order.payment_before_kitchen && order.payment_status !== 'approved')) return notices;
    if(event.state === 'pendiente') await staff('can_view_kitchen',`Nueva comanda #${ticket.id} del pedido #${order.id}.`, '/cocina.html');
    if(order.service_type !== 'delivery') {
      if(event.state === 'preparando') customer('Tu pedido se está preparando.');
      if(event.state === 'entregado') customer('Tu pedido fue entregado.');
      if(event.state === 'listo') {
        customer(order.service_type === 'pickup' ? 'Tu pedido está listo para recoger.' : 'Tu comanda está lista.');
        if(order.order_source === 'pos') add(order.created_by,`Comanda #${ticket.id} de la cuenta #${order.id} lista para entregar.`, '/pos.html');
        if(order.service_type === 'pickup') await staff('can_close_accounts',`Pedido #${order.id} listo para entregar a ${order.pickup_name || 'la persona que recoge'}.`, '/caja.html#ready-pickup');
      }
    }
  }
  return notices;
}

async function deliveryKey(eventId: string, recipient: string) {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${eventId}:${recipient}`))).slice(0,16);
  bytes[6]=(bytes[6]&15)|64; bytes[8]=(bytes[8]&63)|128;
  const h=Array.from(bytes,n=>n.toString(16).padStart(2,'0')).join('');
  return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;
}

Deno.serve(async request => {
  if(request.method==='OPTIONS') return new Response('ok',{headers:corsHeaders(request)});
  if(request.method!=='POST') return jsonResponse(request,{error:'Método no permitido'},405);
  try {
    const body=await request.json();
    // Cached clients may still invoke the old endpoint. Only committed database events send alerts.
    if(!body.dispatchId) return jsonResponse(request,{skipped:true});
    if(!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(body.dispatchId)) return jsonResponse(request,{error:'Evento inválido'},400);
    const db=createWorkerClient();
    const {data:events,error:claimError}=await db.rpc('claim_order_notification',{event_id:body.dispatchId});
    if(claimError) throw claimError;
    const event:Event|undefined=events?.[0];
    if(!event) return jsonResponse(request,{skipped:true});
    const {data:order,error}=await db.from('orders').select('id,restaurant_id,restaurant_name,customer_id,created_by,order_source,service_type,status,payment_status,payment_before_kitchen,payment_method,delivery_status,assigned_driver_id,pickup_name').eq('id',event.order_id).maybeSingle();
    if(error) throw error;
    const notices=order?await buildNotices(db,event,order):new Map<string,Notice>();
    for(const [recipient,notice] of notices) {
      const response=await fetch('https://api.onesignal.com/notifications',{method:'POST',headers:{Authorization:`Key ${Deno.env.get('ONESIGNAL_REST_API_KEY')}`,'Content-Type':'application/json'},body:JSON.stringify({
        app_id:Deno.env.get('ONESIGNAL_APP_ID'),idempotency_key:await deliveryKey(event.id,recipient),target_channel:'push',include_aliases:{external_id:[recipient]},
        headings:{es:order?.restaurant_name || 'ServeYourself',en:order?.restaurant_name || 'ServeYourself'},contents:{es:notice.message,en:notice.message},url:(Deno.env.get('APP_URL')||'https://serveyourself-app.vercel.app')+notice.path
      })});
      if(!response.ok) throw Error(`OneSignal rechazó el aviso (${response.status})`);
    }
    const {error:finishError}=await db.from('order_notification_events').update({completed_at:new Date().toISOString()}).eq('id',event.id);
    if(finishError) throw finishError;
    return jsonResponse(request,{processed:true});
  } catch(error) {
    console.error('order_notification_failed',error instanceof Error?error.message:'Error de base de datos');
    return jsonResponse(request,{error:'No se pudo procesar el aviso'},500);
  }
});
