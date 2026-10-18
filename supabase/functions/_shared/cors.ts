export function corsHeaders(request: Request) {
  const requestedOrigin = request.headers.get('origin');
  const appOrigin = new URL(Deno.env.get('APP_URL') ?? 'https://serveyourself-app.vercel.app').origin;
  const isLocal = requestedOrigin ? /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(requestedOrigin) : false;
  const origin = requestedOrigin === appOrigin || isLocal ? requestedOrigin : appOrigin;
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Vary': 'Origin'
  };
}

export function jsonResponse(request: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(request), 'Content-Type': 'application/json' }
  });
}
