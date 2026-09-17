import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';
import { getValidMercadoPagoToken } from '../_shared/mercado-pago.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(request) });
  if (request.method !== 'POST') return jsonResponse(request, { error: 'Método no permitido' }, 405);

  try {
    const authorization = request.headers.get('Authorization');
    if (!authorization) return jsonResponse(request, { error: 'Sesión requerida' }, 401);

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } }
    });
    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) return jsonResponse(request, { error: 'Sesión inválida' }, 401);

    const { orderId } = await request.json();
    const { data: order, error: orderError } = await userClient
      .from('orders')
      .select('id, customer_id, restaurant_id, restaurant_name, items, total, payment_method, payment_status')
      .eq('id', orderId)
      .single();
    if (orderError || !order || order.customer_id !== user.id) {
      return jsonResponse(request, { error: 'Pedido no encontrado' }, 404);
    }
    if (order.payment_method !== 'mercado_pago' || order.payment_status !== 'pending') {
      return jsonResponse(request, { error: 'El pedido no requiere pago en línea' }, 409);
    }

    const adminClient = createClient(supabaseUrl, serviceKey);
    const accessToken = await getValidMercadoPagoToken(adminClient, order.restaurant_id);
    const appUrl = Deno.env.get('APP_URL')!;
    const feePercent = Math.max(0, Math.min(100, Number(Deno.env.get('MERCADO_PAGO_FEE_PERCENT') ?? 0)));
    const marketplaceFee = Math.round(Number(order.total) * feePercent) / 100;
    const preferenceBody: Record<string, unknown> = {
      items: order.items.map((item: Record<string, unknown>) => ({
        id: String(item.id),
        title: String(item.nombre),
        quantity: Number(item.qty),
        unit_price: Number(item.price),
        currency_id: 'MXN'
      })),
      payer: { email: user.email },
      external_reference: String(order.id),
      statement_descriptor: 'SERVEYOURSELF',
      back_urls: {
        success: `${appUrl}/menu.html?payment=success`,
        pending: `${appUrl}/menu.html?payment=pending`,
        failure: `${appUrl}/menu.html?payment=failure`
      },
      auto_return: 'approved',
      notification_url: `${supabaseUrl}/functions/v1/mercado-pago-webhook?order_id=${encodeURIComponent(order.id)}`
    };
    if (marketplaceFee > 0) preferenceBody.marketplace_fee = marketplaceFee;
    const preferenceResponse = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
        'X-Idempotency-Key': `order-${order.id}`
      },
      body: JSON.stringify(preferenceBody)
    });
    const preference = await preferenceResponse.json();
    if (!preferenceResponse.ok) throw new Error(preference.message ?? 'No se pudo iniciar el pago');

    await adminClient.from('orders')
      .update({ mercado_pago_preference_id: preference.id })
      .eq('id', order.id);

    return jsonResponse(request, { checkoutUrl: preference.init_point, preferenceId: preference.id });
  } catch (error) {
    return jsonResponse(request, { error: error instanceof Error ? error.message : 'Error interno' }, 500);
  }
});
