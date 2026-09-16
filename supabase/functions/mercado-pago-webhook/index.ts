import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (request) => {
  try {
    const url = new URL(request.url);
    const body = request.method === 'POST' ? await request.json().catch(() => ({})) : {};
    const paymentId = url.searchParams.get('data.id') ?? body?.data?.id;
    if (!paymentId) return new Response('ignored', { status: 200 });

    const accessToken = Deno.env.get('MERCADO_PAGO_ACCESS_TOKEN')!;
    const paymentResponse = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, {
      headers: { Authorization: `Bearer ${accessToken}` }
    });
    if (!paymentResponse.ok) return new Response('invalid payment', { status: 400 });
    const payment = await paymentResponse.json();
    const orderId = payment.external_reference;
    if (!orderId) return new Response('missing reference', { status: 400 });

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );
    const { data: order } = await admin.from('orders')
      .select('id, total, payment_method')
      .eq('id', orderId)
      .single();
    if (!order || order.payment_method !== 'mercado_pago') return new Response('order not found', { status: 404 });
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
      .update({ payment_status: statusMap[payment.status] ?? 'pending' })
      .eq('id', orderId);

    return new Response('ok', { status: 200 });
  } catch {
    return new Response('error', { status: 500 });
  }
});
