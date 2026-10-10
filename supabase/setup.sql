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

-- 10 de outubro de 2026: filtro de palavras (regra 1.2 da App Store para conteúdo publicado por utilizadores).
-- Comentários, legendas de fotos e vídeos e o nome público de quem publica são recusados se tiverem uma
-- palavra da lista. Continuam a ser publicados logo; só o que tiver palavras proibidas é recusado.
--
-- Para mudar a lista: Table Editor > blocked_words. Escreva cada palavra ou expressão em minúsculas, sem
-- acentos e com espaços entre palavras (ex.: "filho da puta"). A comparação é feita com palavras inteiras,
-- por isso "cona" não apanha "iconal".

-- Texto simplificado para comparar: minúsculas, sem acentos, números e símbolos trocados pelas letras
-- que costumam imitar (f0da, put@), só letras e espaços, e letras repetidas 3 ou mais vezes reduzidas a uma.
create or replace function public.normalize_for_filter(content text) returns text
    language sql
    immutable
as $$
    select trim(regexp_replace(regexp_replace(
               translate(lower(coalesce(content, '')),
                         'áàâãäéèêëíìîïóòôõöúùûüçñ0134578@$!|',
                         'aaaaaeeeeiiiiooooouuuucnoieastbasii'),
               '[^a-z]+', ' ', 'g'),
           '([a-z])\1{2,}', '\1', 'g'));
$$;

create table if not exists public.blocked_words (
    word text primary key check (word = public.normalize_for_filter(word) and word <> '')
);

-- Sem políticas: a lista não é lida pela app, só pelas funções abaixo e pelo Table Editor.
alter table public.blocked_words enable row level security;

insert into public.blocked_words (word)
select distinct public.normalize_for_filter(w)
  from unnest(array[
    -- Português
    'caralho', 'caralhos', 'foda', 'fodas', 'foda-se', 'fodase', 'foder', 'fode', 'fodes', 'fodido', 'fodida',
    'fodidos', 'fodidas', 'vai te foder', 'vai-te foder', 'puta', 'putas', 'putaria', 'putinha',
    'filho da puta', 'filha da puta', 'filhos da puta', 'filhodaputa', 'fdp', 'cabrão', 'cabrões',
    'cona', 'conas', 'cona da tua mãe', 'piroca', 'punheta', 'punheteiro', 'boceta', 'buceta', 'xoxota',
    'arrombado', 'arrombada', 'tomar no cu', 'cuzão', 'paneleiro', 'paneleiros', 'maricas', 'viado',
    'viadinho', 'sapatão', 'escarumba', 'escarumbas',
    -- English
    'fuck', 'fucks', 'fucking', 'fucked', 'fucker', 'fuckers', 'motherfucker', 'motherfuckers', 'cunt',
    'cunts', 'bitch', 'bitches', 'asshole', 'assholes', 'nigger', 'niggers', 'nigga', 'niggas', 'faggot',
    'faggots', 'fag', 'fags', 'retard', 'retards', 'whore', 'whores', 'slut', 'sluts', 'wanker', 'wankers',
    'twat', 'twats', 'kike', 'spic', 'chink', 'dickhead', 'shithead'
  ]) as w
on conflict do nothing;

-- Diz só se há uma palavra proibida (nunca qual), por isso a app pode perguntar antes de enviar.
create or replace function public.has_blocked_words(content text) returns boolean
    language sql
    stable
    security definer
    set search_path = public
as $$
    select exists (
        select 1
          from public.blocked_words b
         where ' ' || public.normalize_for_filter(content) || ' ' like '% ' || b.word || ' %'
    );
$$;

revoke all on function public.has_blocked_words(text) from public;
grant execute on function public.has_blocked_words(text) to anon, authenticated;

-- Recusa o envio. Ao mudar só o estado ou as denúncias, não volta a verificar (para se poder esconder
-- um comentário antigo sem erro).
create or replace function public.check_blocked_words() returns trigger
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    new_text text := concat_ws(' ', to_jsonb(new) ->> 'comment', to_jsonb(new) ->> 'caption');
begin
    if tg_op = 'UPDATE'
       and new.author is not distinct from old.author
       and new_text is not distinct from concat_ws(' ', to_jsonb(old) ->> 'comment', to_jsonb(old) ->> 'caption') then
        return new;
    end if;
    if public.has_blocked_words(new.author) then
        raise exception 'blocked_words_name' using errcode = 'P0001';
    end if;
    if public.has_blocked_words(new_text) then
        raise exception 'blocked_words_text' using errcode = 'P0001';
    end if;
    return new;
end;
$$;

-- O nome "words" faz o gatilho correr depois de o autor ser preenchido (os gatilhos correm por ordem alfabética).
drop trigger if exists reviews_words on public.reviews;
create trigger reviews_words
    before insert or update on public.reviews
    for each row execute function public.check_blocked_words();

drop trigger if exists submissions_words on public.submissions;
create trigger submissions_words
    before insert or update on public.submissions
    for each row execute function public.check_blocked_words();

-- Para ver se já há algo publicado com palavras da lista (não muda nada):
-- select 'reviews' as tabela, id, author, comment from public.reviews
--  where status = 'approved' and (public.has_blocked_words(comment) or public.has_blocked_words(author))
-- union all
-- select 'submissions', id, author, caption from public.submissions
--  where status = 'approved' and (public.has_blocked_words(caption) or public.has_blocked_words(author));

-- 10 de outubro de 2026: bloquear pessoas (regra 1.2 da App Store para conteúdo publicado por utilizadores).
-- Quem tem conta pode bloquear o autor de um comentário, foto ou vídeo: deixa de ver tudo o que essa pessoa
-- publica. A pessoa bloqueada não é avisada e continua a ver o que publicou. Desbloquear: na Conta da app.
--
-- Para afastar alguém do Tuende inteiro (não só para uma pessoa): Authentication > Users > a conta > Ban user.

begin;

create table if not exists public.blocks (
    blocker_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    blocked_id uuid not null references auth.users (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (blocker_id, blocked_id),
    check (blocker_id <> blocked_id)
);

alter table public.blocks enable row level security;

-- Cada conta vê e apaga só os seus bloqueios. Bloquear faz-se com block_author(), que nunca mostra o id da outra pessoa.
create policy "Cada conta vê os seus bloqueios"
    on public.blocks for select
    to authenticated
    using (blocker_id = auth.uid());

create policy "Cada conta desbloqueia"
    on public.blocks for delete
    to authenticated
    using (blocker_id = auth.uid());

-- Bloqueia o autor de um comentário ou de um envio. Responde 'blocked', 'self' (é a própria pessoa) ou 'not_found'.
create or replace function public.block_author(review uuid default null, submission uuid default null) returns text
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    target uuid;
begin
    if auth.uid() is null then
        raise exception 'not_signed_in' using errcode = 'P0001';
    end if;
    if review is not null then
        select user_id into target from public.reviews where id = review;
    elsif submission is not null then
        select user_id into target from public.submissions where id = submission;
    end if;
    if target is null then
        return 'not_found';
    end if;
    if target = auth.uid() then
        return 'self';
    end if;
    insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), target) on conflict do nothing;
    return 'blocked';
end;
$$;

revoke all on function public.block_author(uuid, uuid) from public, anon;
grant execute on function public.block_author(uuid, uuid) to authenticated;

-- Quem bloqueou deixa de ver as publicações da pessoa bloqueada (as estrelas dela também deixam de contar para si).
drop policy if exists "Todos veem as avaliações aprovadas; cada conta vê as suas" on public.reviews;
create policy "Todos veem as avaliações aprovadas (menos de quem bloquearam); cada conta vê as suas"
    on public.reviews for select
    to anon, authenticated
    using (
        (status = 'approved' and not exists (
            select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = reviews.user_id))
        or user_id = auth.uid()
    );

drop policy if exists "Todos veem os envios aprovados; cada conta vê os seus" on public.submissions;
create policy "Todos veem os envios aprovados (menos de quem bloquearam); cada conta vê os seus"
    on public.submissions for select
    to anon, authenticated
    using (
        (status = 'approved' and not exists (
            select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = submissions.user_id))
        or user_id = auth.uid()
    );

commit;
