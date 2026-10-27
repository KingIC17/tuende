-- 27 de outubro de 2026: Agenda da semana por email (dupla confirmação).
-- Só a função "newsletter" (Edge Function, service role) lê ou escreve esta tabela; os visitantes nunca lhe tocam.
-- Antes de cada envio, as inscrições confirmadas são copiadas para o segmento "Agenda da semana (confirmados)" no Resend,
-- e é o Resend que trata do "sair da lista" em cada email.
-- Para aplicar: Supabase > SQL Editor > New query > colar tudo > Run. Pode correr-se mais de uma vez.

create table if not exists public.newsletter_signups (
    id uuid primary key default gen_random_uuid(),
    email text not null check (char_length(email) between 6 and 254),
    lang text not null default 'pt' check (lang in ('pt', 'en', 'fr', 'es')),
    token text not null unique default replace(gen_random_uuid()::text, '-', ''),
    created_at timestamptz not null default now(),
    sent_at timestamptz,
    confirmed_at timestamptz,
    synced_at timestamptz
);
create unique index if not exists newsletter_signups_email_idx on public.newsletter_signups (lower(email));
create index if not exists newsletter_signups_sent_idx on public.newsletter_signups (sent_at);
alter table public.newsletter_signups enable row level security;
revoke all on public.newsletter_signups from anon, authenticated;
comment on table public.newsletter_signups is 'Agenda da semana por email (dupla confirmação). Só a função newsletter (service role) acede.';
