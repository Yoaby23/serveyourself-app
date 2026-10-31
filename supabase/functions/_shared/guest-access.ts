export async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}
export function validGuestToken(token: unknown): token is string {
  return typeof token === 'string' && /^[a-f0-9]{64}$/.test(token);
}
export async function guestOrderId(admin: any, token: unknown): Promise<number | null> {
  if (!validGuestToken(token)) return null;
  const { data, error } = await admin.from('guest_checkout_requests').select('order_id,created_at')
    .eq('token_hash', await sha256(token)).maybeSingle();
  if (error) throw new Error('No se pudo consultar el pedido');
  if (!data || Date.now() - Date.parse(data.created_at) > 7 * 86400000) return null;
  return data.order_id;
}
