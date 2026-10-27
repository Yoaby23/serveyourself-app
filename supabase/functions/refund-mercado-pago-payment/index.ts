import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';
import { refundOrder } from '../_shared/refunds.ts';

Deno.serve(async request => {
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
    const body = await request.json();
    const orderId = Number(body?.orderId);
    const reason = String(body?.reason ?? '').trim().slice(0, 300);
    if (!Number.isSafeInteger(orderId) || reason.length < 4) {
      return jsonResponse(request, { error: 'Pedido o motivo inválido' }, 400);
    }
    const { data: order } = await client.from('orders')
      .select('id,restaurant_id,service_type,delivery_status,payment_method,payment_status,mercado_pago_payment_id,total')
      .eq('id', orderId).single();
    if (!order || order.service_type !== 'delivery') return jsonResponse(request, { error: 'Pedido no encontrado' }, 404);
    const { data: allowed } = await client.rpc('has_restaurant_permission', {
      p_restaurant_id: order.restaurant_id, p_permission: 'manage_delivery'
    });
    if (!allowed) return jsonResponse(request, { error: 'Sin permiso de delivery' }, 403);
    const admin = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: existing, error: operationError } = await admin.from('payment_refund_operations').select('*').eq('order_id', order.id).maybeSingle();
    if (operationError) throw operationError;
    if (existing?.status === 'completed' || order.payment_status === 'refunded') return jsonResponse(request, { refunded: true });
    if (!existing && (order.delivery_status === 'delivered' || order.delivery_status === 'cancelled')) return jsonResponse(request, { error: 'El pedido ya está cerrado' }, 409);
    if (!existing && (order.payment_method !== 'mercado_pago' || order.payment_status !== 'approved' || !order.mercado_pago_payment_id)) return jsonResponse(request, { error: 'El pedido no tiene un pago aprobado para reembolsar' }, 409);
    const result = await refundOrder(admin, order, existing?.payment_id || order.mercado_pago_payment_id, existing?.reason || reason, user.id);
    return jsonResponse(request, result);

  } catch (error) {
    return jsonResponse(request, { error: error instanceof Error ? error.message : 'Error interno' }, 500);
  }
});
