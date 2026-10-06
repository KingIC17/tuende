-- ANGOLIVE: comentários, avaliações, fotos, vídeos e sugestões de correção dos visitantes.
-- Correr uma vez no Supabase: SQL Editor > New query > colar tudo > Run.
--
-- Como funciona:
--   * Qualquer pessoa pode enviar um comentário com estrelas, uma foto ou um link de vídeo;
--     tudo fica com o estado 'pending'.
--   * Só aparecem na app as linhas com estado 'approved'. As estrelas de cada local são a média
--     dos comentários aprovados (vista review_stats).
--   * Para aprovar: Table Editor > reviews (ou submissions) > mudar status para 'approved' (ou 'rejected').
--   * Cada "Denunciar" soma 1 a report_count; com 3 denúncias fica 'hidden' automaticamente.
--   * Sugestões de "Adicionar ou corrigir um lugar" ficam em corrections (só visíveis no painel do Supabase).

create table public.submissions (
    id uuid primary key default gen_random_uuid(),
    venue_id integer not null,
    kind text not null check (kind in ('photo', 'video')),
    url text not null check (url like 'https://%' and char_length(url) <= 500),
    author text not null check (char_length(author) between 1 and 60),
    caption text check (char_length(caption) <= 200),
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'hidden')),
    report_count integer not null default 0,
    created_at timestamptz not null default now()
);

create index submissions_venue_status_idx on public.submissions (venue_id, status, created_at desc);

alter table public.submissions enable row level security;

create policy "Visitantes veem apenas envios aprovados"
    on public.submissions for select
    to anon, authenticated
    using (status = 'approved');

create policy "Visitantes podem enviar, sempre como pendente"
    on public.submissions for insert
    to anon, authenticated
    with check (status = 'pending' and report_count = 0);

create table public.reviews (
    id uuid primary key default gen_random_uuid(),
    venue_id integer not null,
    author text not null check (char_length(author) between 1 and 60),
    rating integer not null check (rating between 1 and 5),
    comment text not null check (char_length(comment) between 1 and 600),
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'hidden')),
    report_count integer not null default 0,
    created_at timestamptz not null default now()
);

create index reviews_venue_status_idx on public.reviews (venue_id, status, created_at desc);

alter table public.reviews enable row level security;

create policy "Visitantes veem apenas comentários aprovados"
    on public.reviews for select
    to anon, authenticated
    using (status = 'approved');

create policy "Visitantes podem comentar, sempre como pendente"
    on public.reviews for insert
    to anon, authenticated
    with check (status = 'pending' and report_count = 0);

-- Média e número de comentários aprovados por local (respeita as regras acima).
create view public.review_stats with (security_invoker = true) as
    select venue_id,
           round(avg(rating)::numeric, 1) as avg_rating,
           count(*)::integer as review_count
      from public.reviews
     where status = 'approved'
     group by venue_id;

grant select on public.review_stats to anon, authenticated;

create table public.reports (
    id bigint generated always as identity primary key,
    submission_id uuid references public.submissions (id) on delete cascade,
    review_id uuid references public.reviews (id) on delete cascade,
    reason text check (char_length(reason) <= 200),
    created_at timestamptz not null default now(),
    check ((submission_id is null) <> (review_id is null))
);

alter table public.reports enable row level security;

create policy "Visitantes podem denunciar"
    on public.reports for insert
    to anon, authenticated
    with check (true);

create function public.handle_report() returns trigger
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    if new.submission_id is not null then
        update public.submissions
           set report_count = report_count + 1,
               status = case when report_count + 1 >= 3 then 'hidden' else status end
         where id = new.submission_id;
    else
        update public.reviews
           set report_count = report_count + 1,
               status = case when report_count + 1 >= 3 then 'hidden' else status end
         where id = new.review_id;
    end if;
    return new;
end;
$$;

create trigger on_report
    after insert on public.reports
    for each row execute function public.handle_report();

-- Fotos: pasta pública, só JPEG até 5 MB (a app comprime antes de enviar).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('submissions', 'submissions', true, 5242880, array['image/jpeg']);

create policy "Visitantes podem enviar fotos"
    on storage.objects for insert
    to anon, authenticated
    with check (bucket_id = 'submissions');

-- Sugestões "Adicionar ou corrigir um lugar". Os visitantes só podem enviar; ler apenas no painel do Supabase.
create table public.corrections (
    id bigint generated always as identity primary key,
    kind text not null check (kind in ('fix', 'add')),
    venue_id integer,
    place_name text check (char_length(place_name) <= 120),
    message text not null check (char_length(message) between 1 and 1000),
    contact text check (char_length(contact) <= 120),
    status text not null default 'new' check (status in ('new', 'done', 'rejected')),
    created_at timestamptz not null default now()
);

alter table public.corrections enable row level security;

create policy "Visitantes podem sugerir correções"
    on public.corrections for insert
    to anon, authenticated
    with check (status = 'new');
