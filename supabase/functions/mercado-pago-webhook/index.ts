import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { getValidMercadoPagoToken } from '../_shared/mercado-pago.ts';

Deno.serve(async (request) => {
  try {
    const url = new URL(request.url);
    const body = request.method === 'POST' ? await request.json().catch(() => ({})) : {};
    const paymentId = url.searchParams.get('data.id') ?? body?.data?.id;
    const orderId = url.searchParams.get('order_id');
    if (!paymentId || !orderId) return new Response('ignored', { status: 200 });

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );
    const { data: order } = await admin.from('orders')
      .select('id, restaurant_id, total, payment_method')
      .eq('id', orderId)
      .single();
    if (!order || order.payment_method !== 'mercado_pago') return new Response('order not found', { status: 404 });
    const accessToken = await getValidMercadoPagoToken(admin, order.restaurant_id);
    const paymentResponse = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, {
      headers: { Authorization: `Bearer ${accessToken}` }
    });
    if (!paymentResponse.ok) return new Response('invalid payment', { status: 400 });
    const payment = await paymentResponse.json();
    if (String(payment.external_reference) !== String(order.id)) return new Response('reference mismatch', { status: 409 });
    if (Math.abs(Number(order.total) - Number(payment.transaction_amount)) > 0.01) {
      return new Response('amount mismatch', { status: 409 });
    }

    const statusMap: Record<string, string> = {
      approved: 'approved',
      rejected: 'rejected',
      cancelled: 'rejected',
      refunded: 'refunded'
    };
    await admin.from('orders')
      .update({
        payment_status: statusMap[payment.status] ?? 'pending',
        mercado_pago_payment_id: String(paymentId)
      })
      .eq('id', orderId);

    return new Response('ok', { status: 200 });
  } catch {
    return new Response('error', { status: 500 });
  }
});
