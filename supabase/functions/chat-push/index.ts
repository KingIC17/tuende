// Avisos de mensagens novas nas Conversas (Web Push), 31 Oct 2026.
// A base de dados põe os avisos na fila (public.push_queue, trigger chat_notify) e chama esta função (pg_net).
// A função tira a fila (take_push_jobs, só com a chave de serviço) e envia a cada aparelho um aviso SEM conteúdo:
// o service worker da app mostra "Tem mensagens novas nas Conversas." na língua da pessoa. Nenhum texto de mensagem
// passa pelos serviços de avisos (Google, Apple, Mozilla, Microsoft).
// Assinatura VAPID (RFC 8292, ES256) com a chave guardada em public.push_settings.
// GET ?check=1 devolve um token de exemplo (para o domínio example.invalid) para verificar a assinatura com a chave pública.
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CONTACT = "mailto:contacto@tuende.app";
const PUSH_HOST = /^https:\/\/(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)\//;

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromB64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const utf8 = (s: string) => new TextEncoder().encode(s);

let cached: { pub: string; key: CryptoKey } | null = null;

async function signingKey(pub: string, priv: string) {
  if (cached?.pub === pub) return cached.key;
  const p = fromB64u(pub);
  const jwk = { kty: "EC", crv: "P-256", x: b64u(p.slice(1, 33)), y: b64u(p.slice(33, 65)), d: priv, ext: true };
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  cached = { pub, key };
  return key;
}

async function vapidToken(audience: string, pub: string, priv: string) {
  const head = b64u(utf8(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const body = b64u(utf8(JSON.stringify({ aud: audience, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: CONTACT })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await signingKey(pub, priv), utf8(`${head}.${body}`)));
  return `${head}.${body}.${b64u(sig)}`;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (url.searchParams.get("check") === "1") {
    const { data } = await db.from("push_settings").select("vapid_public, vapid_private").eq("id", 1).maybeSingle();
    if (!data) return Response.json({ ready: false });
    return Response.json({ ready: true, public: data.vapid_public, sample: await vapidToken("https://example.invalid", data.vapid_public, data.vapid_private) });
  }

  const { data: jobs, error } = await db.rpc("take_push_jobs");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const result = { sent: 0, gone: 0, failed: 0, statuses: [] as number[] };
  await Promise.all((jobs ?? []).map(async (job: { endpoint: string; vapid_public: string; vapid_private: string }) => {
    if (!PUSH_HOST.test(job.endpoint)) return;
    try {
      const token = await vapidToken(new URL(job.endpoint).origin, job.vapid_public, job.vapid_private);
      const res = await fetch(job.endpoint, {
        method: "POST",
        headers: { Authorization: `vapid t=${token}, k=${job.vapid_public}`, TTL: "86400", Urgency: "high", "Content-Length": "0" },
      });
      result.statuses.push(res.status);
      await res.body?.cancel();
      if (res.status === 404 || res.status === 410) {
        result.gone++;
        await db.rpc("drop_push", { sub_endpoint: job.endpoint });
      } else if (res.ok) result.sent++;
      else result.failed++;
    } catch {
      result.failed++;
    }
  }));
  return Response.json(result);
});
