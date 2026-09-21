import { createClient } from 'npm:@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';
import { getValidMercadoPagoToken } from '../_shared/mercado-pago.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(request) });
  }

  try {
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
    const { data: order, error: orderError } = await admin.from('orders')
      .select('id, restaurant_id, total, payment_method, payment_status, payment_expires_at, created_at, status, cancellation_reason, mercado_pago_preference_id')
      .eq('id', orderId)
      .single();
    if (orderError || !order || order.payment_method !== 'mercado_pago') {
      console.error('Mercado Pago order not found', { orderId, orderError });
      return new Response('order not found', { status: 404, headers: corsHeaders(request) });
    }

    const accessToken = await getValidMercadoPagoToken(admin, order.restaurant_id);
    if (!paymentId) {
      const searchUrl = new URL('https://api.mercadopago.com/v1/payments/search');
      searchUrl.searchParams.set('external_reference', String(order.id));
      const searchResponse = await fetch(searchUrl, {
        headers: { Authorization: `Bearer ${accessToken}` }
      });
      const searchResult = await searchResponse.json().catch(() => ({}));
      const matchingPayment = Array.isArray(searchResult?.results)
        ? searchResult.results.find((candidate: Record<string, unknown>) =>
          String(candidate.external_reference) === String(order.id)
          && Math.abs(Number(candidate.transaction_amount) - Number(order.total)) <= 0.01)
        : null;
      paymentId = matchingPayment?.id ? String(matchingPayment.id) : null;
      if (!searchResponse.ok || !paymentId) {
        const expiresAt = new Date(order.payment_expires_at ?? new Date(order.created_at).getTime() + 20 * 60 * 1000).getTime();
        if (expiresAt <= Date.now() && order.payment_status === 'pending') {
          await admin.from('orders').update({
            payment_status: 'expired',
            status: 'cancelado',
            cancellation_reason: 'Tiempo de pago agotado (20 minutos)'
          }).eq('id', order.id).eq('payment_status', 'pending');
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

    const expiresAt = new Date(order.payment_expires_at ?? new Date(order.created_at).getTime() + 20 * 60 * 1000).getTime();
    const paymentCreatedAt = new Date(payment.date_created ?? Date.now()).getTime();
    if (paymentCreatedAt > expiresAt) {
      await admin.from('orders').update({
        payment_status: 'expired',
        status: 'cancelado',
        cancellation_reason: 'Tiempo de pago agotado (20 minutos)',
        mercado_pago_payment_id: String(paymentId)
      }).eq('id', order.id);
      return new Response('payment window expired', { status: 410, headers: corsHeaders(request) });
    }

    const statusMap: Record<string, string> = {
      approved: 'approved',
      rejected: 'rejected',
      cancelled: 'rejected',
      refunded: 'refunded',
      charged_back: 'refunded'
    };
    const paymentStatus = statusMap[payment.status] ?? 'pending';
    const updates: Record<string, unknown> = {
        payment_status: paymentStatus,
        mercado_pago_payment_id: String(paymentId)
    };
    if (paymentStatus === 'approved' && order.cancellation_reason === 'Tiempo de pago agotado (20 minutos)') {
      updates.status = 'pendiente';
      updates.cancellation_reason = null;
    }
    if (paymentStatus === 'rejected') {
      updates.status = 'cancelado';
      updates.cancellation_reason = 'El pago en línea fue rechazado. Crea un pedido nuevo.';
    }
    const { error: updateError } = await admin.from('orders')
      .update(updates)
      .eq('id', orderId);
    if (updateError) {
      console.error('Could not update Mercado Pago order', { orderId, paymentId, updateError });
      return new Response('database error', { status: 500, headers: corsHeaders(request) });
    }

    console.log('Mercado Pago order reconciled', { orderId, paymentId, paymentStatus });
    return new Response('ok', { status: 200, headers: corsHeaders(request) });
  } catch (error) {
    console.error('Mercado Pago webhook error', error);
    return new Response('error', { status: 500, headers: corsHeaders(request) });
  }
});
