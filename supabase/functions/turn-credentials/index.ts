// Servidor de retransmissão (TURN) da Cloudflare para as chamadas das Conversas, 1 Nov 2026.
// Quando a rede de um telemóvel não deixa os dois aparelhos falarem diretamente, a chamada passa pela Cloudflare
// (cifrada de ponta a ponta pelo WebRTC; a Cloudflare não consegue ouvir nem ver).
// Dá credenciais que expiram ao fim de 24 horas, e só a quem tem sessão iniciada no Tuende.
// Precisa de dois segredos nas Edge Functions do Supabase (o dono cria-os na Cloudflare: Realtime > TURN Server > Create):
//   CF_TURN_KEY_ID e CF_TURN_KEY_API_TOKEN
// Sem eles responde { ready: false } e a app usa só STUN, como antes.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const reply = (data: unknown, status = 200) => Response.json(data, { status, headers: { ...CORS, "Cache-Control": "no-store" } });

// verify_jwt já confirmou a assinatura; aqui exige-se uma sessão de pessoa (não a chave pública da app).
function signedIn(req: Request) {
  try {
    const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const part = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(atob(part + "===".slice((part.length + 3) % 4)));
    return claims.role === "authenticated" && typeof claims.sub === "string";
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (!signedIn(req)) return reply({ ready: false, error: "not_signed_in" }, 401);
  const id = Deno.env.get("CF_TURN_KEY_ID");
  const token = Deno.env.get("CF_TURN_KEY_API_TOKEN");
  if (!id || !token) return reply({ ready: false });
  try {
    const res = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(id)}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ ttl: 86400 }),
    });
    if (!res.ok) return reply({ ready: false, status: res.status });
    const data = await res.json();
    return reply({ ready: true, iceServers: data.iceServers });
  } catch {
    return reply({ ready: false });
  }
});
