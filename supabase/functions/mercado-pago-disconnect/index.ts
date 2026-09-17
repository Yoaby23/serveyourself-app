import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(request) });
  if (request.method !== 'POST') return jsonResponse(request, { error: 'Método no permitido' }, 405);
  const authorization = request.headers.get('Authorization');
  if (!authorization) return jsonResponse(request, { error: 'Sesión requerida' }, 401);

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const client = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authorization } }
  });
  const { data: { user } } = await client.auth.getUser();
  if (!user) return jsonResponse(request, { error: 'Sesión inválida' }, 401);
  const admin = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { error: accountError } = await admin.from('restaurant_payment_accounts').delete().eq('restaurant_id', user.id);
  if (accountError) return jsonResponse(request, { error: 'No se pudo desconectar Mercado Pago' }, 500);
  const { error: profileError } = await admin.from('profiles')
    .update({ mercado_pago_connected: false, payment_online: false })
    .eq('id', user.id);
  if (profileError) return jsonResponse(request, { error: 'No se pudo actualizar el restaurante' }, 500);
  return jsonResponse(request, { disconnected: true });
});
