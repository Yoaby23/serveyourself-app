import { createClient } from 'npm:@supabase/supabase-js@2.118.0';
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
  // Stop new checkout while existing payments and refunds still use this connection.
  const { data: restaurant, error } = await admin.from('profiles')
    .update({ payment_online: false })
    .eq('id', user.id)
    .eq('role', 'negocio')
    .select('id')
    .maybeSingle();
  if (error) return jsonResponse(request, { error: 'No se pudieron pausar los pagos en línea' }, 500);
  if (!restaurant) return jsonResponse(request, { error: 'Cuenta de negocio requerida' }, 403);
  return jsonResponse(request, { paused: true });
});
