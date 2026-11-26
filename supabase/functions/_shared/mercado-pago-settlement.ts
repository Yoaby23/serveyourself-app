function amount(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value < 1e10
    ? Math.round(value * 100) / 100
    : null;
}

function total(values: (number | null)[]): number | null {
  if (!values.length || values.some(value => value === null)) return null;
  return amount(values.reduce<number>((sum, value) => sum + (value ?? 0), 0));
}

type Payment = {
  fee_details?: { type?: string; amount?: unknown; fee_payer?: string }[];
  charges_details?: { type?: string; name?: string; accounts?: { from?: string }; amounts?: { original?: unknown } }[];
  transaction_details?: { net_received_amount?: unknown };
  money_release_date?: string;
};

export function settlementFields(payment: Payment) {
  const fees = Array.isArray(payment.fee_details) ? payment.fee_details : [];
  const charges = Array.isArray(payment.charges_details) ? payment.charges_details : [];
  const fee = total(fees.filter(row => row?.type === 'mercadopago' && row.fee_payer === 'collector').map(row => amount(row.amount)));
  // Generic taxes_amount can contain non-VAT taxes. Store VAT only when explicitly identified.
  const vat = total(charges.filter(row => row?.type === 'tax' && row.accounts?.from === 'collector'
    && /(?:^|[^a-z])(?:iva|vat)(?:[^a-z]|$)/i.test(row.name ?? '')).map(row => amount(row.amounts?.original)));
  const net = amount(payment.transaction_details?.net_received_amount);
  const release = typeof payment.money_release_date === 'string' ? Date.parse(payment.money_release_date) : NaN;
  return {
    ...(fee === null ? {} : { provider_fee: fee }),
    ...(vat === null ? {} : { provider_vat: vat }),
    ...(net === null ? {} : { provider_net: net }),
    ...(Number.isFinite(release) ? { available_at: new Date(release).toISOString() } : {})
  };
}
