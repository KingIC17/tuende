// Avisos das Conversas (Web Push), 31 Oct 2026; chamadas a 1 Nov 2026.
// A base de dados põe os avisos na fila (public.push_queue: chat_notify, ring_call, leave_call) e chama esta função (pg_net).
// A função tira a fila (take_push_jobs, só com a chave de serviço) e envia a cada aparelho:
//  - mensagens novas: um aviso SEM conteúdo; o service worker mostra "Tem mensagens novas nas Conversas." Nenhum texto
//    de mensagem passa pelos serviços de avisos (Google, Apple, Mozilla, Microsoft);
//  - chamadas (quem liga, voz ou vídeo, o grupo): um aviso cifrado de ponta a ponta para o aparelho (RFC 8291, aes128gcm),
//    que o serviço de avisos não consegue ler. Aparelhos sem chaves guardadas recebem o aviso sem conteúdo.
// Assinatura VAPID (RFC 8292, ES256) com a chave guardada em public.push_settings.
// GET ?check=1 devolve um token de exemplo (para o domínio example.invalid) para verificar a assinatura com a chave pública.
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CONTACT = "mailto:contacto@tuende.app";
const PUSH_HOST = /^https:\/\/(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)\//;

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromB64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const utf8 = (s: string) => new TextEncoder().encode(s);
const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

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

// HKDF (extract and expand) with SHA-256.
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, length: number) {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, length * 8));
}

// RFC 8291 (Message Encryption for Web Push) with RFC 8188 aes128gcm, one record.
// `fixed` is only for the test with the RFC's example values.
export async function encryptPush(uaPublicB64: string, authB64: string, plaintext: Uint8Array,
  fixed?: { salt: Uint8Array; asPublic: Uint8Array; asPrivateD: string }) {
  const uaPublic = fromB64u(uaPublicB64);
  const authSecret = fromB64u(authB64);
  let asPrivate: CryptoKey;
  let asPublic: Uint8Array;
  if (fixed) {
    asPublic = fixed.asPublic;
    asPrivate = await crypto.subtle.importKey("jwk", { kty: "EC", crv: "P-256", x: b64u(asPublic.slice(1, 33)), y: b64u(asPublic.slice(33, 65)), d: fixed.asPrivateD, ext: true },
      { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  } else {
    const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
    asPrivate = pair.privateKey;
    asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  }
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, asPrivate, 256));
  const ikm = await hkdf(authSecret, ecdhSecret, concat(utf8("WebPush: info\0"), uaPublic, asPublic), 32);
  const salt = fixed?.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, utf8("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, utf8("Content-Encoding: nonce\0"), 12);
  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, aes, concat(plaintext, new Uint8Array([2]))));
  const header = new Uint8Array(16 + 4 + 1 + asPublic.length);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, 4096);
  header[20] = asPublic.length;
  header.set(asPublic, 21);
  return concat(header, cipher);
}

type Job = { endpoint: string; kind: string; payload: Record<string, unknown> | null; p256dh: string | null; auth: string | null; vapid_public: string; vapid_private: string };

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
  await Promise.all((jobs ?? []).map(async (job: Job) => {
    if (!PUSH_HOST.test(job.endpoint)) return;
    const call = job.kind === "call" || job.kind === "call-end";
    const secret = call && job.payload && job.p256dh && job.auth;
    // A call that ended is only worth telling to a phone that can show who called.
    if (job.kind === "call-end" && !secret) return;
    try {
      const token = await vapidToken(new URL(job.endpoint).origin, job.vapid_public, job.vapid_private);
      const headers: Record<string, string> = {
        Authorization: `vapid t=${token}, k=${job.vapid_public}`,
        TTL: call ? "45" : "86400",
        Urgency: "high",
      };
      let body: Uint8Array | null = null;
      if (secret) {
        body = await encryptPush(job.p256dh!, job.auth!, utf8(JSON.stringify(job.payload)));
        headers["Content-Encoding"] = "aes128gcm";
        headers["Content-Type"] = "application/octet-stream";
        // The same topic for the ring and its end: a ring that was not delivered yet is replaced, not shown late.
        headers.Topic = `c${String(job.payload!.id ?? "").replace(/[^0-9a-f]/g, "").slice(0, 30)}`;
      } else {
        headers["Content-Length"] = "0";
      }
      const res = await fetch(job.endpoint, { method: "POST", headers, body });
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
