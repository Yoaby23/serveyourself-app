import { createClient } from 'npm:@supabase/supabase-js@2';

function redirect(appUrl: string, status: string) {
  return Response.redirect(`${appUrl}/admin.html?mercado_pago=${encodeURIComponent(status)}`, 302);
}

Deno.serve(async (request) => {
  const appUrl = Deno.env.get('APP_URL') ?? 'https://serveyourself-app.vercel.app';
  try {
    const url = new URL(request.url);
    const code = url.searchParams.get('code');
    const state = url.searchParams.get('state');
    if (!code || !state) return redirect(appUrl, 'error');

    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );
    const now = new Date().toISOString();
    const { data: stateRow } = await admin.from('mercado_pago_oauth_states')
      .update({ consumed_at: now })
      .eq('state', state)
      .is('consumed_at', null)
      .gt('expires_at', now)
      .select('restaurant_id, code_verifier')
      .single();
    if (!stateRow) return redirect(appUrl, 'invalid_state');

    const tokenResponse = await fetch('https://api.mercadopago.com/oauth/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        client_id: Deno.env.get('MERCADO_PAGO_CLIENT_ID'),
        client_secret: Deno.env.get('MERCADO_PAGO_CLIENT_SECRET'),
        grant_type: 'authorization_code',
        code,
        redirect_uri: Deno.env.get('MERCADO_PAGO_REDIRECT_URI'),
        code_verifier: stateRow.code_verifier
      })
    });
    const token = await tokenResponse.json();
    if (!tokenResponse.ok || !token.access_token || !token.user_id) return redirect(appUrl, 'token_error');

    const expiresAt = new Date(Date.now() + Number(token.expires_in ?? 0) * 1000).toISOString();
    const { error } = await admin.from('restaurant_payment_accounts').upsert({
      restaurant_id: stateRow.restaurant_id,
      provider_user_id: String(token.user_id),
      access_token: token.access_token,
      refresh_token: token.refresh_token ?? null,
      token_expires_at: expiresAt,
      connected_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    });
    if (error) return redirect(appUrl, 'save_error');

    const { error: profileError } = await admin.from('profiles')
      .update({ mercado_pago_connected: true, payment_online: true })
      .eq('id', stateRow.restaurant_id);
    if (profileError) {
      await admin.from('restaurant_payment_accounts').delete().eq('restaurant_id', stateRow.restaurant_id);
      return redirect(appUrl, 'save_error');
    }
    return redirect(appUrl, 'connected');
  } catch {
    return redirect(appUrl, 'error');
  }
});
