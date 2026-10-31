import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { jsonResponse, corsHeaders } from '../_shared/cors.ts';
import { sha256, validGuestToken, guestOrderId } from '../_shared/guest-access.ts';
Deno.serve(async (request) => {
  const respond = (body: unknown, status = 200) => {
    const response = jsonResponse(request, body, status);
    response.headers.set('Cache-Control', 'no-store');
    return response;
  };
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(request) });
  if (request.method !== 'POST') return respond({ error: 'Método no permitido' }, 405);
  try {
    const raw = await request.text();
    if (raw.length > 16000) return respond({ error: 'Solicitud demasiado grande' }, 413);
    const body = JSON.parse(raw);
    if (!validGuestToken(body.token)) return respond({ error: 'Solicitud inválida' }, 400);
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    let orderId: number | null;
    if (body.action === 'create') {
      const client = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 'unknown';
      const { data, error } = await admin.rpc('create_guest_pickup_order', {
        p_token_hash: await sha256(body.token), p_client_hash: await sha256(client),
        p_restaurant_id: body.restaurantId, p_items: body.items, p_name: body.name
      });
      if (error) return respond({ error: error.code === 'P0001' ? error.message : 'No se pudo crear el pedido. Revisa los productos e inténtalo de nuevo.' }, 400);
      orderId = data.id;
    } else if (body.action === 'status') {
      orderId = await guestOrderId(admin, body.token);
    } else return respond({ error: 'Acción inválida' }, 400);
    if (!orderId) return respond({ error: 'Pedido no encontrado o acceso vencido' }, 404);
    const { data: order, error } = await admin.from('orders')
      .select('id,restaurant_id,pickup_name,items,total,status,payment_status,payment_expires_at,created_at')
      .eq('id', orderId).single();
    if (error || !order) return respond({ error: 'No se pudo consultar el pedido' }, 500);
    // An expiry is display-only here. Payment state is changed only by reconciliation.
    return respond({ order, expired: order.payment_status === 'pending' && Date.parse(order.payment_expires_at) <= Date.now() });
  } catch {
    return respond({ error: 'No se pudo procesar la solicitud. Conserva este pedido e inténtalo de nuevo.' }, 400);
  }
});
