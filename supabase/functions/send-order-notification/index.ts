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

    const { orderId } = await request.json();
    const { data: order } = await client.from('orders')
      .select('id, customer_id, restaurant_id, restaurant_name, status')
      .eq('id', orderId)
      .single();
    if (!order || order.restaurant_id !== user.id) {
      return jsonResponse(request, { error: 'Pedido no encontrado' }, 404);
    }

    const messages: Record<string, string> = {
      preparando: 'Tu pedido ya se está preparando.',
      listo: '¡Tu pedido está listo para recoger!',
      entregado: 'Tu pedido fue marcado como entregado.',
      cancelado: 'El restaurante canceló tu pedido.'
    };
    if (!messages[order.status]) return jsonResponse(request, { skipped: true });

    const oneSignalResponse = await fetch('https://api.onesignal.com/notifications', {
      method: 'POST',
      headers: {
        Authorization: `Key ${Deno.env.get('ONESIGNAL_REST_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        app_id: Deno.env.get('ONESIGNAL_APP_ID'),
        include_aliases: { external_id: [order.customer_id] },
        target_channel: 'push',
        headings: { es: order.restaurant_name, en: order.restaurant_name },
        contents: { es: messages[order.status], en: messages[order.status] },
        url: `${Deno.env.get('APP_URL')}/menu.html`
      })
    });
    if (!oneSignalResponse.ok) throw new Error('No se pudo enviar la notificación');
    return jsonResponse(request, { sent: true });
  } catch (error) {
    return jsonResponse(request, { error: error instanceof Error ? error.message : 'Error interno' }, 500);
  }
});
