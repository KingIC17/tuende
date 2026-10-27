// Agenda da semana por email (dupla confirmação), 27 Oct 2026.
// POST {email, lang, website}  -> guarda a inscrição e envia o email de confirmação (Resend, mail.tuende.app).
// POST {confirm: token}        -> confirma (o link do email abre tuende.app/?newsletter=<token> e a app chama isto;
//                                  assim os programas que abrem links nos emails não confirmam por engano).
// GET  ?status=1               -> {ready}: a app só mostra o formulário quando a chave do Resend está configurada.
// Segredo necessário (Supabase > Edge Functions > Secrets): RESEND_API_KEY, uma chave "Sending access" de mail.tuende.app.
// Os visitantes nunca leem a tabela; sem IP, sem cookies. Limites: 60 inscrições por hora no total, 1 email por endereço a cada 15 minutos.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SITE = "https://tuende.app/";
const FROM = "Tuende <nao-responder@mail.tuende.app>";
const ORIGINS = new Set(["https://tuende.app", "http://localhost:8000"]);
const LANGS = ["pt", "en", "fr", "es"] as const;
type Lang = typeof LANGS[number];
const KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

const TEXT: Record<Lang, { subject: string; hello: string; body: string; button: string; ignore: string; footer: string }> = {
  pt: {
    subject: "Confirme: Agenda da semana do Tuende",
    hello: "Olá!",
    body: "Pediu para receber a Agenda da semana do Tuende: um email por semana com os eventos e os lugares novos em Angola. Para confirmar, toque no botão.",
    button: "Confirmar inscrição",
    ignore: "Se não foi você, ignore este email: sem confirmação não recebe nada.",
    footer: "Tuende · tuende.app · Pode sair da lista em qualquer email.",
  },
  en: {
    subject: "Confirm: Tuende's weekly agenda",
    hello: "Hello!",
    body: "You asked to receive Tuende's weekly agenda: one email a week with events and new places in Angola. To confirm, tap the button.",
    button: "Confirm sign-up",
    ignore: "If this wasn't you, ignore this email: without confirmation you won't receive anything.",
    footer: "Tuende · tuende.app · You can leave the list from any email.",
  },
  fr: {
    subject: "Confirmez : l'agenda de la semaine de Tuende",
    hello: "Bonjour !",
    body: "Vous avez demandé à recevoir l'agenda de la semaine de Tuende : un e-mail par semaine avec les événements et les nouveaux lieux en Angola. Pour confirmer, touchez le bouton.",
    button: "Confirmer l'inscription",
    ignore: "Si ce n'était pas vous, ignorez cet e-mail : sans confirmation, vous ne recevrez rien.",
    footer: "Tuende · tuende.app · Vous pouvez quitter la liste depuis chaque e-mail.",
  },
  es: {
    subject: "Confirma: la agenda de la semana de Tuende",
    hello: "¡Hola!",
    body: "Pidió recibir la agenda de la semana de Tuende: un email por semana con los eventos y los lugares nuevos en Angola. Para confirmar, toque el botón.",
    button: "Confirmar suscripción",
    ignore: "Si no fue usted, ignore este email: sin confirmación no recibirá nada.",
    footer: "Tuende · tuende.app · Puede salir de la lista desde cualquier email.",
  },
};

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function emailHTML(t: typeof TEXT.pt, link: string) {
  return `<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta http-equiv="X-UA-Compatible" content="IE=edge"></head>
<body style="margin:0;padding:0;background-color:#F6F4F1;">
<table width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#F6F4F1" style="background-color:#F6F4F1;"><tr><td align="center" style="padding-top:24px;padding-bottom:24px;">
<table width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">
<tr><td bgcolor="#FFFFFF" style="background-color:#FFFFFF;border-radius:16px;padding-top:28px;padding-bottom:28px;padding-left:28px;padding-right:28px;">
<p style="margin:0;font-family:Arial,Helvetica,sans-serif;font-size:22px;line-height:28px;font-weight:bold;color:#C62828;">Tuende</p>
<p style="margin-top:20px;margin-bottom:0;font-family:Arial,Helvetica,sans-serif;font-size:17px;line-height:26px;color:#1C1C21;">${esc(t.hello)}</p>
<p style="margin-top:8px;margin-bottom:0;font-family:Arial,Helvetica,sans-serif;font-size:17px;line-height:26px;color:#1C1C21;">${esc(t.body)}</p>
<table cellpadding="0" cellspacing="0" border="0" style="margin-top:24px;"><tr><td bgcolor="#C62828" style="background-color:#C62828;border-radius:12px;">
<a href="${link}" style="display:inline-block;padding-top:14px;padding-bottom:14px;padding-left:22px;padding-right:22px;font-family:Arial,Helvetica,sans-serif;font-size:17px;line-height:20px;font-weight:bold;color:#FFFFFF;text-decoration:none;">${esc(t.button)}</a>
</td></tr></table>
<p style="margin-top:24px;margin-bottom:0;font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:21px;color:#5C5C66;">${esc(t.ignore)}</p>
</td></tr>
<tr><td style="padding-top:14px;"><p style="margin:0;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:19px;color:#5C5C66;text-align:center;">${esc(t.footer)}</p></td></tr>
</table></td></tr></table></body></html>`;
}

function cors(req: Request) {
  const origin = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGINS.has(origin) ? origin : SITE.slice(0, -1),
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
    "Vary": "Origin",
  };
}

const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

// Network errors, 429 and 5xx are retried (respecting retry-after); other 4xx are not.
async function sendConfirmation(to: string, lang: Lang, token: string) {
  const t = TEXT[lang];
  const link = `${SITE}?newsletter=${token}`;
  const body = JSON.stringify({
    from: FROM, to: [to], subject: t.subject,
    html: emailHTML(t, link),
    text: `${t.hello}\n\n${t.body}\n\n${t.button}: ${link}\n\n${t.ignore}\n\n${t.footer}`,
    tags: [{ name: "type", value: "newsletter_confirm" }],
  });
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${KEY}`, "Content-Type": "application/json", "Idempotency-Key": `newsletter-confirm-${token}` },
        body,
      });
      if (r.ok) return true;
      if (r.status !== 429 && r.status < 500) { console.error("resend", r.status, await r.text()); return false; }
      const wait = Number(r.headers.get("retry-after")) * 1000 || 800 * 2 ** attempt;
      await new Promise((res) => setTimeout(res, Math.min(wait, 4000)));
    } catch (e) {
      console.error("resend network", e);
      await new Promise((res) => setTimeout(res, 800 * 2 ** attempt));
    }
  }
  return false;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method === "GET") return json(req, { ready: Boolean(KEY) });
  if (req.method !== "POST") return json(req, { error: "method" }, 405);

  let input: Record<string, unknown> = {};
  try { input = await req.json(); } catch { return json(req, { error: "bad_request" }, 400); }

  // Confirm a sign-up.
  if (typeof input.confirm === "string") {
    const token = input.confirm;
    if (!/^[0-9a-f]{32}$/.test(token)) return json(req, { ok: false, error: "invalid" }, 400);
    const { data, error } = await db.from("newsletter_signups").select("id, confirmed_at, lang").eq("token", token).maybeSingle();
    if (error) { console.error(error); return json(req, { ok: false, error: "server" }, 500); }
    if (!data) return json(req, { ok: false, error: "invalid" }, 404);
    if (!data.confirmed_at) await db.from("newsletter_signups").update({ confirmed_at: new Date().toISOString() }).eq("id", data.id);
    return json(req, { ok: true, lang: data.lang });
  }

  // New sign-up.
  if (!KEY) return json(req, { ok: false, error: "not_ready" }, 503);
  if (typeof input.website === "string" && input.website.trim()) return json(req, { ok: true }); // honeypot
  const email = String(input.email ?? "").trim().toLowerCase();
  const lang = (LANGS as readonly string[]).includes(String(input.lang)) ? (input.lang as Lang) : "pt";
  if (email.length < 6 || email.length > 254 || !/^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[a-z]{2,}$/.test(email)) {
    return json(req, { ok: false, error: "email" }, 400);
  }

  const hourAgo = new Date(Date.now() - 3600_000).toISOString();
  const { count } = await db.from("newsletter_signups").select("id", { count: "exact", head: true }).gte("sent_at", hourAgo);
  if ((count ?? 0) >= 60) return json(req, { ok: false, error: "busy" }, 429);

  const { data: existing } = await db.from("newsletter_signups").select("id, token, sent_at, confirmed_at").eq("email", email).maybeSingle();
  // Same answer whether or not the address was already there, so the form does not reveal who is on the list.
  if (existing?.confirmed_at) return json(req, { ok: true });
  if (existing?.sent_at && Date.now() - Date.parse(existing.sent_at) < 15 * 60_000) return json(req, { ok: true });

  let token = existing?.token as string | undefined;
  if (existing) {
    await db.from("newsletter_signups").update({ lang }).eq("id", existing.id);
  } else {
    const { data, error } = await db.from("newsletter_signups").insert({ email, lang }).select("token").single();
    if (error) { console.error(error); return json(req, { ok: false, error: "server" }, 500); }
    token = data.token;
  }
  const sent = await sendConfirmation(email, lang, token!);
  if (!sent) return json(req, { ok: false, error: "send" }, 502);
  await db.from("newsletter_signups").update({ sent_at: new Date().toISOString() }).eq("token", token!);
  return json(req, { ok: true });
});
