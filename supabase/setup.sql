-- Tuende (antes ANGOLIVE): contas, lugares guardados, avaliações, comentários, fotos, vídeos, correções,
-- recomendações e sugestões de eventos.
-- Correr uma vez no Supabase: SQL Editor > New query > colar tudo > Run.
--
-- Como funciona:
--   * Contas: Supabase Auth com email e palavra-passe (Authentication > Sign In / Providers > Email).
--     O nome público de cada pessoa fica em user_metadata.display_name.
--   * Só quem tem conta pode avaliar, comentar, enviar fotos ou vídeos, corrigir ou acrescentar
--     informação e denunciar. O autor de cada envio é preenchido pela base de dados a partir da conta.
--   * Avaliações, comentários, fotos e vídeos ficam públicos logo que são enviados (status 'approved').
--     Para tirar algo do ar: Table Editor > reviews (ou submissions) > status = 'rejected'.
--   * As estrelas de cada local são a média das avaliações aprovadas (vista review_stats).
--     Cada conta só dá estrelas uma vez por local; comentários sem estrelas não têm limite.
--   * Cada "Denunciar" soma 1 a report_count (uma vez por conta); com 3 denúncias fica 'hidden'.
--   * Os lugares guardados ficam em favorites e são sincronizados entre dispositivos.
--   * "Apagar conta" na app apaga as fotos da pessoa e chama delete_my_account(), que apaga a conta
--     e, em cascata, os lugares guardados, avaliações, envios, denúncias e correções.
--   * Correções ficam em corrections; recomendações de lugares novos em recommendations (com fotos na
--     pasta privada recommendations); sugestões de eventos em event_suggestions. As recomendações e as
--     sugestões de eventos continuam abertas a todos, com ou sem conta.

-- Nome público da conta (ou a parte do email antes do @).
create function public.current_display_name() returns text
    language sql
    stable
    security definer
    set search_path = public
as $$
    select left(coalesce(nullif(trim(raw_user_meta_data ->> 'display_name'), ''), split_part(email, '@', 1)), 60)
      from auth.users
     where id = auth.uid();
$$;

-- Liga cada envio à conta que o fez e põe o nome público como autor (não pode ser falsificado).
create function public.set_contributor() returns trigger
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    new.user_id := auth.uid();
    new.author := coalesce(public.current_display_name(), 'Visitante');
    return new;
end;
$$;

-- Lugares guardados de cada conta.
create table public.favorites (
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    venue_id integer not null,
    created_at timestamptz not null default now(),
    primary key (user_id, venue_id)
);

alter table public.favorites enable row level security;

create policy "Cada conta vê os seus lugares guardados"
    on public.favorites for select
    to authenticated
    using (user_id = auth.uid());

create policy "Cada conta guarda lugares"
    on public.favorites for insert
    to authenticated
    with check (user_id = auth.uid());

create policy "Cada conta remove lugares guardados"
    on public.favorites for delete
    to authenticated
    using (user_id = auth.uid());

-- Fotos e vídeos dos visitantes.
create table public.submissions (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    venue_id integer not null,
    kind text not null check (kind in ('photo', 'video')),
    url text not null check (url like 'https://%' and char_length(url) <= 500),
    author text not null check (char_length(author) between 1 and 60),
    caption text check (char_length(caption) <= 200),
    status text not null default 'approved' check (status in ('pending', 'approved', 'rejected', 'hidden')),
    report_count integer not null default 0,
    created_at timestamptz not null default now()
);

create index submissions_venue_status_idx on public.submissions (venue_id, status, created_at desc);
create index submissions_user_idx on public.submissions (user_id);

create trigger submissions_contributor
    before insert on public.submissions
    for each row execute function public.set_contributor();

alter table public.submissions enable row level security;

create policy "Todos veem os envios aprovados; cada conta vê os seus"
    on public.submissions for select
    to anon, authenticated
    using (status = 'approved' or user_id = auth.uid());

create policy "Contas enviam fotos e vídeos, publicados logo"
    on public.submissions for insert
    to authenticated
    with check (user_id = auth.uid() and status = 'approved' and report_count = 0);

-- Avaliações (estrelas) e comentários. Pode haver só estrelas, só comentário ou os dois.
create table public.reviews (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    venue_id integer not null,
    author text not null check (char_length(author) between 1 and 60),
    rating integer check (rating between 1 and 5),
    comment text check (char_length(comment) between 1 and 600),
    status text not null default 'approved' check (status in ('pending', 'approved', 'rejected', 'hidden')),
    report_count integer not null default 0,
    created_at timestamptz not null default now(),
    check (rating is not null or comment is not null)
);

create index reviews_venue_status_idx on public.reviews (venue_id, status, created_at desc);
create index reviews_user_idx on public.reviews (user_id);
-- Estrelas: uma vez por conta e por local.
create unique index reviews_one_rating_per_account on public.reviews (venue_id, user_id) where rating is not null;

create trigger reviews_contributor
    before insert on public.reviews
    for each row execute function public.set_contributor();

alter table public.reviews enable row level security;

create policy "Todos veem as avaliações aprovadas; cada conta vê as suas"
    on public.reviews for select
    to anon, authenticated
    using (status = 'approved' or user_id = auth.uid());

create policy "Contas avaliam e comentam, publicado logo"
    on public.reviews for insert
    to authenticated
    with check (user_id = auth.uid() and status = 'approved' and report_count = 0);

-- Média e número de avaliações com estrelas aprovadas por local.
create view public.review_stats with (security_invoker = true) as
    select venue_id,
           round(avg(rating)::numeric, 1) as avg_rating,
           count(rating)::integer as review_count
      from public.reviews
     where status = 'approved' and rating is not null
     group by venue_id;

grant select on public.review_stats to anon, authenticated;

-- Denúncias: uma por conta e por conteúdo.
create table public.reports (
    id bigint generated always as identity primary key,
    reporter_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    submission_id uuid references public.submissions (id) on delete cascade,
    review_id uuid references public.reviews (id) on delete cascade,
    reason text check (char_length(reason) <= 200),
    created_at timestamptz not null default now(),
    check ((submission_id is null) <> (review_id is null)),
    unique (reporter_id, submission_id),
    unique (reporter_id, review_id)
);

alter table public.reports enable row level security;

create policy "Contas podem denunciar"
    on public.reports for insert
    to authenticated
    with check (reporter_id = auth.uid());

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
-- Cada conta só escreve, lista e apaga dentro da sua pasta (o nome da pasta é o id da conta).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('submissions', 'submissions', true, 5242880, array['image/jpeg']);

create policy "Contas enviam fotos para a sua pasta"
    on storage.objects for insert
    to authenticated
    with check (bucket_id = 'submissions' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Contas veem a sua pasta"
    on storage.objects for select
    to authenticated
    using (bucket_id = 'submissions' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Contas apagam as suas fotos"
    on storage.objects for delete
    to authenticated
    using (bucket_id = 'submissions' and (storage.foldername(name))[1] = auth.uid()::text);

-- "Corrigir ou acrescentar informação" a um lugar. Só com conta; ler no painel do Supabase.
create table public.corrections (
    id bigint generated always as identity primary key,
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    author text not null check (char_length(author) between 1 and 60),
    kind text not null check (kind in ('fix', 'add')),
    venue_id integer,
    place_name text check (char_length(place_name) <= 120),
    message text not null check (char_length(message) between 1 and 1000),
    contact text check (char_length(contact) <= 120),
    status text not null default 'new' check (status in ('new', 'done', 'rejected')),
    created_at timestamptz not null default now()
);

create trigger corrections_contributor
    before insert on public.corrections
    for each row execute function public.set_contributor();

alter table public.corrections enable row level security;

create policy "Cada conta vê as suas correções"
    on public.corrections for select
    to authenticated
    using (user_id = auth.uid());

create policy "Contas sugerem correções"
    on public.corrections for insert
    to authenticated
    with check (user_id = auth.uid() and status = 'new');

-- "Apagar conta": apaga a conta de quem chama e, em cascata, tudo o que está ligado a ela.
create function public.delete_my_account() returns void
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    delete from auth.users where id = auth.uid();
end;
$$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- "Recomendar um lugar". Os visitantes só podem enviar; ler e aprovar no painel do Supabase.
create table public.recommendations (
    id bigint generated always as identity primary key,
    name text not null check (char_length(name) between 1 and 120),
    category text not null check (char_length(category) <= 40),
    city text not null check (char_length(city) between 1 and 80),
    address text check (char_length(address) <= 200),
    phone text check (char_length(phone) <= 40),
    email text check (char_length(email) <= 120),
    website text check (char_length(website) <= 300),
    press_link text check (char_length(press_link) <= 300),
    social_links jsonb not null default '[]'::jsonb check (jsonb_typeof(social_links) = 'array' and jsonb_array_length(social_links) <= 5 and pg_column_size(social_links) <= 3000),
    other_link jsonb check (other_link is null or pg_column_size(other_link) <= 600),
    reason text check (char_length(reason) <= 500),
    relationship text not null default 'visitor' check (relationship in ('visitor', 'owner')),
    contact text check (char_length(contact) <= 120),
    photos jsonb not null default '[]'::jsonb check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 5 and pg_column_size(photos) <= 1000),
    status text not null default 'new' check (status in ('new', 'approved', 'rejected')),
    created_at timestamptz not null default now()
);

alter table public.recommendations enable row level security;

create policy "Visitantes podem recomendar lugares"
    on public.recommendations for insert
    to anon, authenticated
    with check (status = 'new');

-- Fotos das recomendações: pasta privada (só o dono as vê no painel), só JPEG até 5 MB.
-- Ao aprovar um lugar, copiar as fotos escolhidas para a app à mão.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('recommendations', 'recommendations', false, 5242880, array['image/jpeg']);

create policy "Visitantes podem enviar fotos de recomendações"
    on storage.objects for insert
    to anon, authenticated
    with check (bucket_id = 'recommendations' and storage.extension(name) = 'jpg');

-- "Sugerir um evento" (página Agenda). Os visitantes só podem enviar; ler no painel do Supabase.
create table public.event_suggestions (
    id bigint generated always as identity primary key,
    name text not null check (char_length(name) between 1 and 120),
    start_date date not null,
    end_date date check (end_date is null or end_date >= start_date),
    city text not null check (char_length(city) between 1 and 80),
    venue text check (char_length(venue) <= 160),
    link text check (char_length(link) <= 300),
    details text check (char_length(details) <= 800),
    contact text check (char_length(contact) <= 120),
    status text not null default 'new' check (status in ('new', 'added', 'rejected')),
    created_at timestamptz not null default now()
);

alter table public.event_suggestions enable row level security;

create policy "Visitantes podem sugerir eventos"
    on public.event_suggestions for insert
    to anon, authenticated
    with check (status = 'new');

-- Fotos de perfil (outubro de 2026): uma máscara angolana desenhada ou uma foto da própria conta.

alter table public.reviews add column if not exists author_avatar text;
alter table public.submissions add column if not exists author_avatar text;

-- Foto de perfil da conta: uma das máscaras da app ou uma foto na pasta da própria conta. Tudo o resto é ignorado.
create or replace function public.current_avatar() returns text
    language sql
    stable
    security definer
    set search_path = public
as $$
    select case
               when a ~ '^mask-[a-z-]{2,20}$' then a
               when a ~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/submissions/' || auth.uid()::text || '/avatar-[0-9]+\.jpg$') then a
           end
      from (select raw_user_meta_data ->> 'avatar' as a from auth.users where id = auth.uid()) s;
$$;

-- Põe a foto de perfil em cada envio novo (não pode ser falsificada pela app).
create or replace function public.set_author_avatar() returns trigger
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    new.author_avatar := public.current_avatar();
    return new;
end;
$$;

drop trigger if exists reviews_author_avatar on public.reviews;
create trigger reviews_author_avatar
    before insert on public.reviews
    for each row execute function public.set_author_avatar();

drop trigger if exists submissions_author_avatar on public.submissions;
create trigger submissions_author_avatar
    before insert on public.submissions
    for each row execute function public.set_author_avatar();

-- Depois de mudar o nome ou a foto de perfil, a app chama isto para atualizar o que a pessoa já publicou.
create or replace function public.sync_my_profile() returns void
    language sql
    security definer
    set search_path = public
as $$
    update public.reviews
       set author = coalesce(public.current_display_name(), author), author_avatar = public.current_avatar()
     where user_id = auth.uid();
    update public.submissions
       set author = coalesce(public.current_display_name(), author), author_avatar = public.current_avatar()
     where user_id = auth.uid();
$$;

revoke all on function public.sync_my_profile() from public, anon;
grant execute on function public.sync_my_profile() to authenticated;
