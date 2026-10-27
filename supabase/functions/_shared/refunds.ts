import { getValidMercadoPagoToken } from './mercado-pago.ts';

// Persist the intent before contacting the provider. Both manual retries and webhooks
// can finish the same operation after a timeout, without creating a second refund.
export async function refundOrder(admin: any, order: any, paymentId: string, reason: string, actorId: string | null = null) {
  const { data: operation, error: beginError } = await admin.rpc('begin_order_refund', {
    p_order_id: order.id, p_payment_id: paymentId, p_reason: reason, p_actor_id: actorId
  });
  if (beginError) throw beginError;
  if (operation.status === 'completed') return { refunded: true, refundId: operation.refund_id ?? null };
  const token = await getValidMercadoPagoToken(admin, order.restaurant_id);
  const paymentResponse = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}`, { headers: { Authorization: `Bearer ${token}` } });
  if (!paymentResponse.ok) throw new Error('No fue posible verificar el pago. El reembolso sigue pendiente; reintenta.');
  const payment = await paymentResponse.json();
  if (String(payment.external_reference) !== String(order.id) || payment.currency_id !== 'MXN' || Math.abs(Number(payment.transaction_amount) - Number(order.total)) > 0.01) throw new Error('El pago no corresponde al pedido');
  let refundId = null;
  if (payment.status !== 'refunded' && payment.status !== 'charged_back') {
    if (payment.status !== 'approved') throw new Error('El pago no está aprobado. Reintenta la conciliación antes de reembolsar.');
    const response = await fetch(`https://api.mercadopago.com/v1/payments/${paymentId}/refunds`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-Idempotency-Key': `refund-order-${order.id}` },
      body: '{}'
    });
    const refund = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error('No se confirmó el reembolso. Conservamos la solicitud para reintentar sin duplicarlo.');
    // A provider may accept an operation without completing it synchronously.
    if (refund.status !== 'approved') throw new Error('Mercado Pago está procesando el reembolso. Reintenta la verificación.');
    refundId = refund.id ? String(refund.id) : null;
  }
  const { data, error } = await admin.rpc('finish_order_refund', { p_order_id: order.id, p_refund_id: refundId });
  if (error) throw new Error('El reembolso fue confirmado, pero falta sincronizarlo. Reintenta para completar el registro.');
  return data;
}
