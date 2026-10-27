import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
import { corsHeaders } from '../_shared/cors.ts';
import { getValidMercadoPagoToken } from '../_shared/mercado-pago.ts';
import { refundOrder } from '../_shared/refunds.ts';

async function validMercadoPagoSignature(request: Request, paymentId: string | null) {
  const secret = Deno.env.get('MERCADO_PAGO_WEBHOOK_SECRET');
  const signature = request.headers.get('x-signature');
  const requestId = request.headers.get('x-request-id');
  if (!secret || !signature || !requestId || !paymentId) return false;
  const parts = Object.fromEntries(signature.split(',').map(part => part.trim().split('=', 2)));
  if (!parts.ts || !parts.v1) return false;
  const manifest = `id:${paymentId.toLowerCase()};request-id:${requestId};ts:${parts.ts};`;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const digest = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(manifest)));
  const expected = [...digest].map(byte => byte.toString(16).padStart(2, '0')).join('');
  if (expected.length !== parts.v1.length) return false;
  let difference = 0;
  for (let index = 0; index < expected.length; index += 1) difference |= expected.charCodeAt(index) ^ parts.v1.charCodeAt(index);
  return difference === 0;
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(request) });
  }

  try {
    let requesterId: string | null = null;
    const url = new URL(request.url);
    const body = request.method === 'POST' ? await request.json().catch(() => ({})) : {};
    let paymentId = url.searchParams.get('data.id')
      ?? url.searchParams.get('payment_id')
      ?? url.searchParams.get('collection_id')
      ?? url.searchParams.get('id')
      ?? body?.data?.id
      ?? body?.payment_id
      ?? body?.collection_id
      ?? body?.id;
    const orderId = url.searchParams.get('order_id')
      ?? url.searchParams.get('external_reference')
      ?? body?.order_id
      ?? body?.external_reference;
    if (!orderId) {
      console.log('Mercado Pago notification ignored: missing payment or order id', {
        paymentId: paymentId ?? null,
        orderId: orderId ?? null,
        type: url.searchParams.get('type') ?? url.searchParams.get('topic') ?? body?.type ?? null
      });
      return new Response('ignored', { status: 200, headers: corsHeaders(request) });
    }

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    if (request.method === 'POST') {
      if (!await validMercadoPagoSignature(request, paymentId ? String(paymentId) : null)) {
        return new Response('invalid signature', { status: 401, headers: corsHeaders(request) });
      }
    } else if (request.method === 'GET') {
      const authorization = request.headers.get('Authorization');
      if (!authorization) return new Response('authentication required', { status: 401, headers: corsHeaders(request) });
      const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
        global: { headers: { Authorization: authorization } }
      });
      const { data: { user } } = await userClient.auth.getUser();
      if (!user) return new Response('invalid session', { status: 401, headers: corsHeaders(request) });
      requesterId = user.id;
    } else {
      return new Response('method not allowed', { status: 405, headers: corsHeaders(request) });
    }
    const { data: order, error: orderError } = await admin.from('orders')
      .select('id, customer_id, restaurant_id, total, payment_method, payment_status, payment_expires_at, created_at, status, cancellation_reason, mercado_pago_preference_id')
      .eq('id', orderId)
      .single();
    if (orderError || !order || order.payment_method !== 'mercado_pago') {
      console.error('Mercado Pago order not found', { orderId, orderError });
      return new Response('order not found', { status: 404, headers: corsHeaders(request) });
    }
    if (request.method === 'GET' && requesterId && requesterId !== order.customer_id && requesterId !== order.restaurant_id) {
      const userClient = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
        global: { headers: { Authorization: request.headers.get('Authorization')! } }
      });
      const { data: allowed } = await userClient.rpc('has_restaurant_permission', {
        p_restaurant_id: order.restaurant_id, p_permission: 'close_accounts'
      });
      if (!allowed) return new Response('forbidden', { status: 403, headers: corsHeaders(request) });
    }

    const accessToken = await getValidMercadoPagoToken(admin, order.restaurant_id);
    if (!paymentId) {
      const searchUrl = new URL('https://api.mercadopago.com/v1/payments/search');
      searchUrl.searchParams.set('external_reference', String(order.id));
      const searchResponse = await fetch(searchUrl, {
        headers: { Authorization: `Bearer ${accessToken}` }
      });
      const searchResult = await searchResponse.json().catch(() => ({}));
      if (!searchResponse.ok) throw new Error('No se pudo consultar Mercado Pago');
      const matchingPayment = Array.isArray(searchResult?.results)
        ? searchResult.results.sort((a: any, b: any) => { const ranks: Record<string, number> = { refunded: 4, charged_back: 4, approved: 3, pending: 2, in_process: 2 }; return (ranks[b.status] || 0) - (ranks[a.status] || 0) || Date.parse(b.date_last_updated || b.date_created) - Date.parse(a.date_last_updated || a.date_created); }).find((candidate: Record<string, unknown>) =>
          String(candidate.external_reference) === String(order.id)
          && Math.abs(Number(candidate.transaction_amount) - Number(order.total)) <= 0.01)
        : null;
      paymentId = matchingPayment?.id ? String(matchingPayment.id) : null;
      if (!searchResponse.ok || !paymentId) {
        const expiresAt = new Date(order.payment_expires_at ?? new Date(order.created_at).getTime() + 20 * 60 * 1000).getTime();
        if (expiresAt <= Date.now() && order.payment_status === 'pending') {
          const { error: expirationError } = await admin.from('orders').update({
            payment_status: 'expired',
            status: 'cancelado',
            cancellation_reason: 'Tiempo de pago agotado (20 minutos)'
          }).eq('id', order.id).eq('payment_status', 'pending');
          if (expirationError) throw expirationError;
        }
        console.log('No Mercado Pago payment found for order', { orderId });
        return new Response('payment not found', { status: 404, headers: corsHeaders(request) });
      }
    }

    const paymentResponse = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, {
      headers: { Authorization: `Bearer ${accessToken}` }
    });
    if (!paymentResponse.ok) {
      console.error('Mercado Pago payment lookup failed', { paymentId, status: paymentResponse.status });
      return new Response('invalid payment', { status: 400, headers: corsHeaders(request) });
    }

    const payment = await paymentResponse.json();
    if (String(payment.external_reference) !== String(order.id)) {
      return new Response('reference mismatch', { status: 409, headers: corsHeaders(request) });
    }
    if (Math.abs(Number(order.total) - Number(payment.transaction_amount)) > 0.01) {
      return new Response('amount mismatch', { status: 409, headers: corsHeaders(request) });
    }

    if (payment.currency_id !== 'MXN') return new Response('currency mismatch', { status: 409, headers: corsHeaders(request) });
    const { data: refundOperation, error: refundError } = await admin.from('payment_refund_operations').select('*').eq('order_id', order.id).maybeSingle();
    if (refundError) throw refundError;
    const expiresAt = new Date(order.payment_expires_at ?? new Date(order.created_at).getTime() + 20 * 60 * 1000).getTime();
    const paymentCreatedAt = new Date(payment.date_created).getTime();
    if (!Number.isFinite(paymentCreatedAt)) throw new Error('Invalid payment date');
    if (refundOperation?.status === 'pending') {
      await refundOrder(admin, order, refundOperation.payment_id, refundOperation.reason, refundOperation.actor_id);
      return new Response('refund reconciled', { headers: corsHeaders(request) });
    }
    if (paymentCreatedAt > expiresAt && payment.status === 'approved') {
      await refundOrder(admin, order, String(paymentId), 'Pago recibido fuera de tiempo y reembolsado automáticamente');
      return new Response('late payment refunded', { headers: corsHeaders(request) });
    }
    const { data: reconciliation, error: updateError } = await admin.rpc('reconcile_order_payment', { p_order_id: order.id, p_payment: payment });
    if (updateError) throw updateError;
    const paymentStatus = reconciliation?.payment_status || order.payment_status;

    console.log('Mercado Pago order reconciled', { orderId, paymentId, paymentStatus });
    return new Response('ok', { status: 200, headers: corsHeaders(request) });
  } catch (error) {
    console.error('Mercado Pago webhook error', error);
    return new Response('error', { status: 500, headers: corsHeaders(request) });
  }
});
