import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(request) });
  if (request.method !== 'POST') return jsonResponse(request, { error: 'Método no permitido' }, 405);

  try {
    const authorization = request.headers.get('Authorization');
    if (!authorization) return jsonResponse(request, { error: 'Sesión requerida' }, 401);
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const client = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authorization } }
    });
    const { data: { user } } = await client.auth.getUser();
    if (!user) return jsonResponse(request, { error: 'Sesión inválida' }, 401);

    const { orderId, ticketId } = await request.json();
    let ticket: { id: number; order_id: number; status: string } | null = null;
    if (ticketId) {
      const { data } = await client.from('kitchen_tickets').select('id,order_id,status').eq('id', ticketId).single();
      ticket = data;
    }
    const targetOrderId = ticket?.order_id ?? orderId;
    const { data: order } = await client.from('orders')
      .select('id, customer_id, restaurant_id, restaurant_name, status, order_source, created_by')
      .eq('id', targetOrderId)
      .single();
    if (!order) {
      return jsonResponse(request, { error: 'Pedido no encontrado' }, 404);
    }

    if (order.restaurant_id !== user.id) {
      const { data: canOperateKitchen } = await client.rpc('has_restaurant_permission', {
        p_restaurant_id: order.restaurant_id,
        p_permission: 'view_kitchen'
      });
      if (!canOperateKitchen) return jsonResponse(request, { error: 'Sin permiso para notificar este pedido' }, 403);
    }

    const messages: Record<string, string> = {
      preparando: 'Tu pedido ya se está preparando.',
      listo: '¡Tu pedido está listo para recoger!',
      entregado: 'Tu pedido fue marcado como entregado.',
      cancelado: 'El restaurante canceló tu pedido.'
    };
    const notificationStatus = ticket?.status ?? order.status;
    if (!messages[notificationStatus]) return jsonResponse(request, { skipped: true });

    const appUrl = Deno.env.get('APP_URL') ?? 'https://serveyourself-app.vercel.app';
    const notifications: Array<{ recipient: string; message: string; url: string }> = [];
    if (order.customer_id) {
      notifications.push({ recipient: order.customer_id, message: messages[notificationStatus], url: `${appUrl}/menu.html` });
    }
    if (order.order_source === 'pos' && order.created_by && ['listo', 'cancelado'].includes(notificationStatus)) {
      notifications.push({
        recipient: order.created_by,
        message: notificationStatus === 'listo'
          ? `La comanda #${ticket?.id ?? order.id} de la cuenta #${order.id} está lista para entregar.`
          : `La comanda #${ticket?.id ?? order.id} fue cancelada.`,
        url: `${appUrl}/pos.html`
      });
    }
    if (!notifications.length) return jsonResponse(request, { skipped: true, reason: 'Sin destinatarios' });

    const results = await Promise.all(notifications.map(notification => fetch('https://api.onesignal.com/notifications', {
      method: 'POST',
      headers: {
        Authorization: `Key ${Deno.env.get('ONESIGNAL_REST_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        app_id: Deno.env.get('ONESIGNAL_APP_ID'),
        include_aliases: { external_id: [notification.recipient] },
        target_channel: 'push',
        headings: { es: order.restaurant_name, en: order.restaurant_name },
        contents: { es: notification.message, en: notification.message },
        url: notification.url
      })
    })));
    if (results.some(response => !response.ok)) throw new Error('No se pudo enviar una notificación');
    return jsonResponse(request, { sent: true, recipients: notifications.length });
  } catch (error) {
    return jsonResponse(request, { error: error instanceof Error ? error.message : 'Error interno' }, 500);
  }
});
