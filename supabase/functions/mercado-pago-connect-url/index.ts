import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';

function base64Url(bytes: Uint8Array) {
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(request) });
  if (request.method !== 'POST') return jsonResponse(request, { error: 'Método no permitido' }, 405);

  try {
    const authorization = request.headers.get('Authorization');
    if (!authorization) return jsonResponse(request, { error: 'Sesión requerida' }, 401);
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: authorization } }
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return jsonResponse(request, { error: 'Sesión inválida' }, 401);
    const { data: profile } = await userClient.from('profiles').select('role').eq('id', user.id).single();
    if (profile?.role !== 'negocio') return jsonResponse(request, { error: 'Cuenta de negocio requerida' }, 403);

    const clientId = Deno.env.get('MERCADO_PAGO_CLIENT_ID');
    const redirectUri = Deno.env.get('MERCADO_PAGO_REDIRECT_URI');
    if (!clientId || !redirectUri) throw new Error('Mercado Pago Marketplace no está configurado');

    const verifierBytes = crypto.getRandomValues(new Uint8Array(48));
    const verifier = base64Url(verifierBytes);
    const challenge = base64Url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
    const admin = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: stateRow, error } = await admin.from('mercado_pago_oauth_states')
      .insert({ restaurant_id: user.id, code_verifier: verifier })
      .select('state')
      .single();
    if (error || !stateRow) throw new Error('No se pudo iniciar la conexión');

    const url = new URL('https://auth.mercadopago.com/authorization');
    url.searchParams.set('client_id', clientId);
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('platform_id', 'mp');
    url.searchParams.set('state', stateRow.state);
    url.searchParams.set('redirect_uri', redirectUri);
    url.searchParams.set('code_challenge', challenge);
    url.searchParams.set('code_challenge_method', 'S256');
    return jsonResponse(request, { authorizationUrl: url.toString() });
  } catch (error) {
    return jsonResponse(request, { error: error instanceof Error ? error.message : 'Error interno' }, 500);
  }
});
