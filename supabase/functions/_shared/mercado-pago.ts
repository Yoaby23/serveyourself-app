// deno-lint-ignore-file no-explicit-any
export async function getValidMercadoPagoToken(admin: any, restaurantId: string) {
  const { data: account, error } = await admin
    .from('restaurant_payment_accounts')
    .select('access_token, refresh_token, token_expires_at')
    .eq('restaurant_id', restaurantId)
    .single();

  if (error || !account) throw new Error('El restaurante no tiene Mercado Pago conectado');
  const expiresAt = account.token_expires_at ? new Date(account.token_expires_at).getTime() : 0;
  if (!expiresAt || expiresAt > Date.now() + 5 * 60 * 1000) return account.access_token;
  if (!account.refresh_token) throw new Error('La conexión de Mercado Pago expiró');

  const response = await fetch('https://api.mercadopago.com/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      client_id: Deno.env.get('MERCADO_PAGO_CLIENT_ID'),
      client_secret: Deno.env.get('MERCADO_PAGO_CLIENT_SECRET'),
      grant_type: 'refresh_token',
      refresh_token: account.refresh_token
    })
  });
  const token = await response.json();
  if (!response.ok || !token.access_token) throw new Error('No se pudo renovar Mercado Pago');

  await admin.from('restaurant_payment_accounts').update({
    access_token: token.access_token,
    refresh_token: token.refresh_token ?? account.refresh_token,
    token_expires_at: new Date(Date.now() + Number(token.expires_in ?? 0) * 1000).toISOString(),
    updated_at: new Date().toISOString()
  }).eq('restaurant_id', restaurantId);

  return token.access_token;
}
