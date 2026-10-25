-- 25 de outubro de 2026: avaliações mais completas e contagens por lugar (ideias do Dianping, adaptadas ao Tuende).
-- Para aplicar: Supabase > SQL Editor > New query > colar tudo > Run. Pode correr-se mais de uma vez.
-- A app deteta sozinha estas novidades: antes de correr isto, tudo continua a funcionar como hoje.
--
-- O que muda:
--   1. Avaliações: três notas opcionais (sabor/qualidade, ambiente, atendimento), quanto gastou por pessoa (Kz)
--      e até 5 etiquetas de uma lista fixa (ex.: "boa vista", "reservar antes").
--   2. review_stats ganha as médias das três notas e a mediana do gasto por pessoa; review_tag_counts conta as etiquetas.
--   3. Votos "útil" nas avaliações (uma vez por conta), com contagem pública.
--   4. "Já fui" (passaporte) guardado na conta, para quem tem sessão iniciada.
--   5. Contagens públicas por lugar: quantas pessoas já foram e quantas o guardaram (só números, nunca quem).
--   6. Nível de quem contribui: número de avaliações e fotos aprovadas por conta (só números).

begin;

-- 1. Avaliações
alter table public.reviews add column if not exists taste smallint check (taste between 1 and 5);
alter table public.reviews add column if not exists ambience smallint check (ambience between 1 and 5);
alter table public.reviews add column if not exists service smallint check (service between 1 and 5);
alter table public.reviews add column if not exists spend integer check (spend between 0 and 5000000);
alter table public.reviews add column if not exists tags text[] check (
    tags <@ array['vista', 'familias', 'reservar', 'musica', 'esplanada', 'estacionamento', 'acessivel', 'wifi', 'calmo',
                  'grupos', 'romantico', 'rapido', 'bom_preco', 'caro', 'limpo', 'simpatico', 'autentico', 'fotos', 'espera']::text[]
    and coalesce(array_length(tags, 1), 0) <= 5
);

-- 2. Médias e etiquetas (as colunas novas ficam no fim, como o Postgres exige)
create or replace view public.review_stats with (security_invoker = true) as
    select venue_id,
           round(avg(rating)::numeric, 1) as avg_rating,
           count(rating)::integer as review_count,
           round(avg(taste)::numeric, 1) as avg_taste,
           round(avg(ambience)::numeric, 1) as avg_ambience,
           round(avg(service)::numeric, 1) as avg_service,
           (percentile_cont(0.5) within group (order by spend))::integer as median_spend,
           count(spend)::integer as spend_count
      from public.reviews
     where status = 'approved' and rating is not null
     group by venue_id;

grant select on public.review_stats to anon, authenticated;

create or replace view public.review_tag_counts with (security_invoker = true) as
    select r.venue_id, tag, count(*)::integer as n
      from public.reviews r, unnest(r.tags) as tag
     where r.status = 'approved'
     group by r.venue_id, tag;

grant select on public.review_tag_counts to anon, authenticated;

-- 3. Votos "útil"
create table if not exists public.review_votes (
    review_id uuid not null references public.reviews (id) on delete cascade,
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (review_id, user_id)
);
alter table public.review_votes enable row level security;
drop policy if exists "Cada conta vê os seus votos" on public.review_votes;
create policy "Cada conta vê os seus votos" on public.review_votes for select to authenticated using (user_id = auth.uid());
drop policy if exists "Contas votam útil" on public.review_votes;
create policy "Contas votam útil" on public.review_votes for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "Contas retiram o voto" on public.review_votes;
create policy "Contas retiram o voto" on public.review_votes for delete to authenticated using (user_id = auth.uid());

create or replace function public.review_helpful_counts(venue integer)
    returns table (review_id uuid, n integer)
    language sql stable security definer set search_path = public as $$
    select v.review_id, count(*)::integer
      from public.review_votes v
      join public.reviews r on r.id = v.review_id
     where r.venue_id = venue and r.status = 'approved'
     group by v.review_id;
$$;
revoke execute on function public.review_helpful_counts(integer) from public;
grant execute on function public.review_helpful_counts(integer) to anon, authenticated;

-- 4. "Já fui" na conta
create table if not exists public.visits (
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    venue_id integer not null,
    created_at timestamptz not null default now(),
    primary key (user_id, venue_id)
);
alter table public.visits enable row level security;
drop policy if exists "Cada conta vê as suas visitas" on public.visits;
create policy "Cada conta vê as suas visitas" on public.visits for select to authenticated using (user_id = auth.uid());
drop policy if exists "Cada conta marca visitas" on public.visits;
create policy "Cada conta marca visitas" on public.visits for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "Cada conta desmarca visitas" on public.visits;
create policy "Cada conta desmarca visitas" on public.visits for delete to authenticated using (user_id = auth.uid());

-- 5. Contagens públicas por lugar (só números)
create or replace function public.venue_counts()
    returns table (venue_id integer, visits integer, saves integer)
    language sql stable security definer set search_path = public as $$
    select x.venue_id, sum(x.v)::integer, sum(x.s)::integer
      from (select venue_id, 1 as v, 0 as s from public.visits
            union all
            select venue_id, 0, 1 from public.favorites) x
     group by x.venue_id;
$$;
revoke execute on function public.venue_counts() from public;
grant execute on function public.venue_counts() to anon, authenticated;

-- 6. Nível de quem contribui (só números): recebe ids de avaliações, nunca expõe o id da conta.
create or replace function public.review_author_counts(review_ids uuid[])
    returns table (review_id uuid, reviews integer, photos integer)
    language sql stable security definer set search_path = public as $$
    select a.id,
           (select count(*)::integer from public.reviews r where r.user_id = a.user_id and r.status = 'approved'),
           (select count(*)::integer from public.submissions s where s.user_id = a.user_id and s.status = 'approved')
      from public.reviews a
     where a.id = any (review_ids[1:50]) and a.status = 'approved';
$$;
revoke execute on function public.review_author_counts(uuid[]) from public;
grant execute on function public.review_author_counts(uuid[]) to anon, authenticated;

commit;
