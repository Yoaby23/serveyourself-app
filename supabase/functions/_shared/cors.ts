function parseOrigin(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value.trim());
    const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    return url.protocol === 'https:' || (local && url.protocol === 'http:') ? url.origin : null;
  } catch {
    return null;
  }
}

export function appOrigin(): string | null {
  const configured = parseOrigin(Deno.env.get('APP_URL'));
  if (configured) return configured;
  const backend = parseOrigin(Deno.env.get('SUPABASE_URL'));
  return backend === 'https://spbgledcjwtqmlqdlpyx.supabase.co'
    ? 'https://serveyourself-app.vercel.app'
    : null;
}

export function corsHeaders(request: Request): Record<string, string> {
  const requestedOrigin = request.headers.get('origin');
  const origins = [appOrigin(), ...(Deno.env.get('APP_ALLOWED_ORIGINS') ?? '').split(',').map(parseOrigin)];
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Vary': 'Origin'
  };
  if (requestedOrigin && origins.includes(requestedOrigin)) headers['Access-Control-Allow-Origin'] = requestedOrigin;
  return headers;
}

export function jsonResponse(request: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(request), 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
  });
}
