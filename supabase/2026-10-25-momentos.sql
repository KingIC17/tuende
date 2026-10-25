-- 25 de outubro de 2026: Momentos, o mural onde as pessoas contam onde estiveram (ideia do Dianping, adaptada ao Tuende).
-- Para aplicar: Supabase > SQL Editor > New query > colar tudo > Run. Pode correr-se mais de uma vez.
-- A app deteta sozinha esta novidade: antes de correr isto, a página Momentos diz "em breve" e nada mais muda.
--
-- O que muda:
--   1. posts: um momento tem texto, até 6 fotos (na pasta da própria conta, como as outras fotos) e um lugar:
--      um lugar do Tuende (venue_id) ou um nome escrito pela pessoa, com a localização opcional (só dentro de Angola).
--   2. post_comments: comentários debaixo de cada momento.
--   3. post_reactions: "gosto" (1) ou "não gosto" (-1), um por conta e por momento; as contagens são públicas, quem não.
--   4. Como nas avaliações: publica logo, o nome e a foto de perfil vêm da conta, o filtro de palavras recusa
--      texto ofensivo, 3 denúncias escondem o momento ou o comentário, e quem bloqueia alguém deixa de o ver.
--   5. Cada pessoa pode apagar os seus momentos e comentários; quem publicou pode apagar comentários no seu momento.
--   6. Ao apagar a conta, tudo isto é apagado em cascata (as fotos já são apagadas pela app, como hoje).
--   7. Etiquetas nos momentos (até 3, de uma lista fixa: comida, praia, natureza...), para filtrar o mural.
--   8. Seguir quem publica: a app nunca vê o id da conta; segue-se "o autor deste momento". Cada pessoa vê quem segue,
--      e os números de seguidores são públicos (quem segue quem, não).
--   9. Perfil e caixa de entrada: as minhas contagens (momentos, gostos recebidos, seguidores, avaliações, quantas
--      pessoas as minhas avaliações ajudaram) e as notificações (comentários, gostos por momento, seguidores novos).
--  10. Duas listas só para o dono (Table Editor; a app não lhes tem acesso):
--      «moderacao»: tudo o que foi denunciado (momentos, comentários, avaliações, fotos e vídeos), o mais recente primeiro.
--          Para esconder: abrir a tabela do tipo indicado (posts, post_comments, reviews ou submissions) e pôr status = 'hidden'.
--      «atualizacoes_de_donos»: o que os donos enviaram em «É o dono deste lugar?» (telefone, horário, preços, website,
--          fotos na pasta privada recommendations). Confirmar pelo contacto antes de mudar o lugar na app.
--
-- Para tirar algo do ar: Table Editor > posts (ou post_comments) > status = 'hidden'.

begin;

-- 1. Momentos
create table if not exists public.posts (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    author text not null default 'Visitante',
    author_avatar text,
    venue_id integer check (venue_id > 0),
    place_name text check (char_length(place_name) between 2 and 120),
    lat double precision check (lat between -18.5 and -4.0),
    lng double precision check (lng between 11.0 and 24.5),
    body text not null check (char_length(trim(body)) between 1 and 2000),
    photos text[] not null default '{}' check (coalesce(array_length(photos, 1), 0) <= 6),
    tags text[] not null default '{}',
    status text not null default 'approved' check (status in ('pending', 'approved', 'rejected', 'hidden')),
    report_count integer not null default 0,
    created_at timestamptz not null default now(),
    check (venue_id is not null or place_name is not null),
    check ((lat is null) = (lng is null))
);

-- Para quem já correu uma versão anterior deste ficheiro.
alter table public.posts add column if not exists tags text[] not null default '{}';
alter table public.posts drop constraint if exists posts_tags_check;
alter table public.posts add constraint posts_tags_check check (
    tags <@ array['comida', 'praia', 'natureza', 'cultura', 'noite', 'eventos', 'familia', 'barato', 'vista', 'passeio']::text[]
    and coalesce(array_length(tags, 1), 0) <= 3
);

create index if not exists posts_status_created_idx on public.posts (status, created_at desc);
create index if not exists posts_venue_idx on public.posts (venue_id, status, created_at desc);
create index if not exists posts_user_idx on public.posts (user_id);

-- 2. Comentários
create table if not exists public.post_comments (
    id uuid primary key default gen_random_uuid(),
    post_id uuid not null references public.posts (id) on delete cascade,
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    author text not null default 'Visitante',
    author_avatar text,
    comment text not null check (char_length(trim(comment)) between 1 and 500),
    status text not null default 'approved' check (status in ('pending', 'approved', 'rejected', 'hidden')),
    report_count integer not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists post_comments_post_idx on public.post_comments (post_id, status, created_at);
create index if not exists post_comments_user_idx on public.post_comments (user_id);

-- 3. Gosto / não gosto
create table if not exists public.post_reactions (
    post_id uuid not null references public.posts (id) on delete cascade,
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    value smallint not null check (value in (-1, 1)),
    created_at timestamptz not null default now(),
    primary key (post_id, user_id)
);

-- As fotos de um momento só podem estar na pasta da própria conta (o mesmo sítio das outras fotos).
create or replace function public.check_post_photos() returns trigger
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    photo text;
begin
    foreach photo in array coalesce(new.photos, '{}') loop
        if photo !~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/submissions/' || auth.uid()::text || '/post-[0-9]+-[a-z0-9]+\.jpg$') then
            raise exception 'bad_photo' using errcode = 'P0001';
        end if;
    end loop;
    return new;
end;
$$;

-- O filtro de palavras passa a ler também o texto e o nome do lugar dos momentos (o resto fica igual).
create or replace function public.check_blocked_words() returns trigger
    language plpgsql
    security definer
    set search_path = public
as $$
declare
    new_text text := concat_ws(' ', to_jsonb(new) ->> 'comment', to_jsonb(new) ->> 'caption', to_jsonb(new) ->> 'body', to_jsonb(new) ->> 'place_name');
begin
    if tg_op = 'UPDATE'
       and new.author is not distinct from old.author
       and new_text is not distinct from concat_ws(' ', to_jsonb(old) ->> 'comment', to_jsonb(old) ->> 'caption', to_jsonb(old) ->> 'body', to_jsonb(old) ->> 'place_name') then
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

-- Os gatilhos correm por ordem alfabética: autor e foto de perfil primeiro, depois fotos e palavras.
drop trigger if exists posts_author_avatar on public.posts;
create trigger posts_author_avatar before insert on public.posts for each row execute function public.set_author_avatar();
drop trigger if exists posts_contributor on public.posts;
create trigger posts_contributor before insert on public.posts for each row execute function public.set_contributor();
drop trigger if exists posts_photos on public.posts;
create trigger posts_photos before insert on public.posts for each row execute function public.check_post_photos();
drop trigger if exists posts_words on public.posts;
create trigger posts_words before insert or update on public.posts for each row execute function public.check_blocked_words();

drop trigger if exists post_comments_author_avatar on public.post_comments;
create trigger post_comments_author_avatar before insert on public.post_comments for each row execute function public.set_author_avatar();
drop trigger if exists post_comments_contributor on public.post_comments;
create trigger post_comments_contributor before insert on public.post_comments for each row execute function public.set_contributor();
drop trigger if exists post_comments_words on public.post_comments;
create trigger post_comments_words before insert or update on public.post_comments for each row execute function public.check_blocked_words();

-- Regras de acesso
alter table public.posts enable row level security;
alter table public.post_comments enable row level security;
alter table public.post_reactions enable row level security;

grant select on public.posts, public.post_comments to anon, authenticated;
grant insert, delete on public.posts, public.post_comments to authenticated;
grant select, insert, update, delete on public.post_reactions to authenticated;

drop policy if exists "Todos veem os momentos (menos de quem bloquearam); cada conta vê os seus" on public.posts;
create policy "Todos veem os momentos (menos de quem bloquearam); cada conta vê os seus"
    on public.posts for select
    to anon, authenticated
    using (
        (status = 'approved' and not exists (
            select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = posts.user_id))
        or user_id = auth.uid()
    );

drop policy if exists "Contas publicam momentos, publicados logo" on public.posts;
create policy "Contas publicam momentos, publicados logo"
    on public.posts for insert
    to authenticated
    with check (user_id = auth.uid() and status = 'approved' and report_count = 0);

drop policy if exists "Cada conta apaga os seus momentos" on public.posts;
create policy "Cada conta apaga os seus momentos"
    on public.posts for delete
    to authenticated
    using (user_id = auth.uid());

drop policy if exists "Todos veem os comentários (menos de quem bloquearam); cada conta vê os seus" on public.post_comments;
create policy "Todos veem os comentários (menos de quem bloquearam); cada conta vê os seus"
    on public.post_comments for select
    to anon, authenticated
    using (
        (status = 'approved' and not exists (
            select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = post_comments.user_id))
        or user_id = auth.uid()
    );

drop policy if exists "Contas comentam momentos, publicado logo" on public.post_comments;
create policy "Contas comentam momentos, publicado logo"
    on public.post_comments for insert
    to authenticated
    with check (
        user_id = auth.uid() and status = 'approved' and report_count = 0
        and exists (select 1 from public.posts p where p.id = post_id and p.status = 'approved')
    );

drop policy if exists "Cada conta apaga os seus comentários; quem publicou apaga os do seu momento" on public.post_comments;
create policy "Cada conta apaga os seus comentários; quem publicou apaga os do seu momento"
    on public.post_comments for delete
    to authenticated
    using (
        user_id = auth.uid()
        or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid())
    );

drop policy if exists "Cada conta vê as suas reações" on public.post_reactions;
create policy "Cada conta vê as suas reações" on public.post_reactions for select to authenticated using (user_id = auth.uid());
drop policy if exists "Contas reagem a momentos" on public.post_reactions;
create policy "Contas reagem a momentos" on public.post_reactions for insert to authenticated
    with check (user_id = auth.uid() and exists (select 1 from public.posts p where p.id = post_id and p.status = 'approved'));
drop policy if exists "Contas mudam a reação" on public.post_reactions;
create policy "Contas mudam a reação" on public.post_reactions for update to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "Contas retiram a reação" on public.post_reactions;
create policy "Contas retiram a reação" on public.post_reactions for delete to authenticated using (user_id = auth.uid());

-- Contagens públicas (só números, nunca quem): gosto, não gosto e comentários de cada momento.
create or replace function public.post_counts(post_ids uuid[])
    returns table (post_id uuid, likes integer, dislikes integer, comments integer)
    language sql stable security definer set search_path = public as $$
    select p.id,
           (select count(*)::integer from public.post_reactions r where r.post_id = p.id and r.value = 1),
           (select count(*)::integer from public.post_reactions r where r.post_id = p.id and r.value = -1),
           (select count(*)::integer from public.post_comments c where c.post_id = p.id and c.status = 'approved')
      from public.posts p
     where p.id = any (post_ids[1:60]) and p.status = 'approved';
$$;
revoke execute on function public.post_counts(uuid[]) from public;
grant execute on function public.post_counts(uuid[]) to anon, authenticated;

-- 4. Denúncias (uma por conta e por conteúdo; 3 escondem)
create table if not exists public.post_reports (
    id bigint generated always as identity primary key,
    reporter_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    post_id uuid references public.posts (id) on delete cascade,
    comment_id uuid references public.post_comments (id) on delete cascade,
    created_at timestamptz not null default now(),
    check ((post_id is null) <> (comment_id is null)),
    unique (reporter_id, post_id),
    unique (reporter_id, comment_id)
);
alter table public.post_reports enable row level security;
grant insert on public.post_reports to authenticated;
drop policy if exists "Contas denunciam momentos e comentários" on public.post_reports;
create policy "Contas denunciam momentos e comentários" on public.post_reports for insert to authenticated
    with check (reporter_id = auth.uid());

create or replace function public.handle_post_report() returns trigger
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    if new.post_id is not null then
        update public.posts
           set report_count = report_count + 1,
               status = case when report_count + 1 >= 3 then 'hidden' else status end
         where id = new.post_id;
    else
        update public.post_comments
           set report_count = report_count + 1,
               status = case when report_count + 1 >= 3 then 'hidden' else status end
         where id = new.comment_id;
    end if;
    return new;
end;
$$;

drop trigger if exists on_post_report on public.post_reports;
create trigger on_post_report after insert on public.post_reports for each row execute function public.handle_post_report();

-- Bloquear quem publicou um momento ou um comentário (responde 'blocked', 'self' ou 'not_found', como block_author).
create or replace function public.block_post_author(post uuid default null, comment uuid default null) returns text
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
    if post is not null then
        select user_id into target from public.posts where id = post;
    elsif comment is not null then
        select user_id into target from public.post_comments where id = comment;
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
revoke all on function public.block_post_author(uuid, uuid) from public, anon;
grant execute on function public.block_post_author(uuid, uuid) to authenticated;

-- Mudar o nome ou a foto de perfil também atualiza os momentos e comentários.
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
    update public.posts
       set author = coalesce(public.current_display_name(), author), author_avatar = public.current_avatar()
     where user_id = auth.uid();
    update public.post_comments
       set author = coalesce(public.current_display_name(), author), author_avatar = public.current_avatar()
     where user_id = auth.uid();
$$;
revoke all on function public.sync_my_profile() from public, anon;
grant execute on function public.sync_my_profile() to authenticated;

-- 7-9. Seguir, perfil e caixa de entrada
create table if not exists public.follows (
    follower_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    followed_id uuid not null references auth.users (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (follower_id, followed_id),
    check (follower_id <> followed_id)
);
create index if not exists follows_followed_idx on public.follows (followed_id);
alter table public.follows enable row level security;
grant select, delete on public.follows to authenticated;
drop policy if exists "Cada conta vê quem segue" on public.follows;
create policy "Cada conta vê quem segue" on public.follows for select to authenticated using (follower_id = auth.uid());
drop policy if exists "Cada conta deixa de seguir" on public.follows;
create policy "Cada conta deixa de seguir" on public.follows for delete to authenticated using (follower_id = auth.uid());

-- Seguir (follow = true) ou deixar de seguir quem publicou um momento. Responde 'following', 'not_following', 'self' ou 'not_found'.
create or replace function public.follow_author(post uuid, follow boolean default true) returns text
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
    select user_id into target from public.posts where id = post and status = 'approved';
    if target is null then
        return 'not_found';
    end if;
    if target = auth.uid() then
        return 'self';
    end if;
    if follow then
        insert into public.follows (follower_id, followed_id) values (auth.uid(), target) on conflict do nothing;
        return 'following';
    end if;
    delete from public.follows where follower_id = auth.uid() and followed_id = target;
    return 'not_following';
end;
$$;
revoke all on function public.follow_author(uuid, boolean) from public, anon;
grant execute on function public.follow_author(uuid, boolean) to authenticated;

-- Perfil público de quem publicou um momento: nome, foto, número de momentos e de seguidores.
create or replace function public.author_profile(post uuid)
    returns table (author text, author_avatar text, posts integer, followers integer, following boolean, is_me boolean)
    language sql stable security definer set search_path = public as $$
    select p.author, p.author_avatar,
           (select count(*)::integer from public.posts x where x.user_id = p.user_id and x.status = 'approved'),
           (select count(*)::integer from public.follows f where f.followed_id = p.user_id),
           exists (select 1 from public.follows f where f.followed_id = p.user_id and f.follower_id = auth.uid()),
           coalesce(p.user_id = auth.uid(), false)
      from public.posts p
     where p.id = post and p.status = 'approved';
$$;
revoke execute on function public.author_profile(uuid) from public;
grant execute on function public.author_profile(uuid) to anon, authenticated;

-- Os momentos de quem publicou um momento (sem os de quem a pessoa bloqueou).
create or replace function public.author_posts(post uuid)
    returns table (id uuid, author text, author_avatar text, venue_id integer, place_name text, lat double precision, lng double precision,
                   body text, photos text[], tags text[], created_at timestamptz, status text)
    language sql stable security definer set search_path = public as $$
    select x.id, x.author, x.author_avatar, x.venue_id, x.place_name, x.lat, x.lng, x.body, x.photos, x.tags, x.created_at, x.status
      from public.posts x
      join public.posts p on p.id = post and p.status = 'approved'
     where x.user_id = p.user_id and x.status = 'approved'
       and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = x.user_id)
     order by x.created_at desc
     limit 60;
$$;
revoke execute on function public.author_posts(uuid) from public;
grant execute on function public.author_posts(uuid) to anon, authenticated;

-- O separador "Seguindo": momentos de quem a pessoa segue.
create or replace function public.following_posts()
    returns table (id uuid, author text, author_avatar text, venue_id integer, place_name text, lat double precision, lng double precision,
                   body text, photos text[], tags text[], created_at timestamptz, status text)
    language sql stable security definer set search_path = public as $$
    select x.id, x.author, x.author_avatar, x.venue_id, x.place_name, x.lat, x.lng, x.body, x.photos, x.tags, x.created_at, x.status
      from public.posts x
      join public.follows f on f.followed_id = x.user_id and f.follower_id = auth.uid()
     where x.status = 'approved'
       and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = x.user_id)
     order by x.created_at desc
     limit 60;
$$;
revoke execute on function public.following_posts() from public, anon;
grant execute on function public.following_posts() to authenticated;

-- As minhas contagens para o perfil. "Ajudou" conta os votos "útil" nas minhas avaliações (se as avaliações detalhadas
-- de 2026-10-25-avaliacoes-detalhadas.sql já estiverem ativas; antes disso dá 0).
create or replace function public.my_stats()
    returns table (n_posts integer, n_likes integer, n_followers integer, n_following integer, n_reviews integer, n_helpful integer)
    language plpgsql stable security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    helped integer := 0;
begin
    if me is null then
        return;
    end if;
    if to_regclass('public.review_votes') is not null then
        execute 'select count(*)::integer from public.review_votes v join public.reviews r on r.id = v.review_id
                  where r.user_id = $1 and v.user_id <> $1 and r.status = ''approved''' into helped using me;
    end if;
    return query select
        (select count(*)::integer from public.posts p where p.user_id = me and p.status = 'approved'),
        (select count(*)::integer from public.post_reactions r join public.posts p on p.id = r.post_id where p.user_id = me and r.value = 1 and r.user_id <> me),
        (select count(*)::integer from public.follows f where f.followed_id = me),
        (select count(*)::integer from public.follows f where f.follower_id = me),
        (select count(*)::integer from public.reviews r where r.user_id = me and r.status = 'approved'),
        helped;
end;
$$;
revoke execute on function public.my_stats() from public, anon;
grant execute on function public.my_stats() to authenticated;

-- Caixa de entrada: comentários de outras pessoas nos meus momentos, gostos (só o número, por momento) e seguidores novos.
create or replace function public.my_notifications()
    returns table (kind text, post_id uuid, actor text, actor_avatar text, snippet text, n integer, created_at timestamptz)
    language sql stable security definer set search_path = public as $$
    select * from (
        select 'comment'::text, c.post_id, c.author, c.author_avatar, left(c.comment, 140), 1, c.created_at
          from public.post_comments c
          join public.posts p on p.id = c.post_id
         where p.user_id = auth.uid() and c.user_id <> auth.uid() and c.status = 'approved'
           and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = c.user_id)
        union all
        select 'like'::text, r.post_id, null::text, null::text, left(p.body, 80), count(*)::integer, max(r.created_at)
          from public.post_reactions r
          join public.posts p on p.id = r.post_id
         where p.user_id = auth.uid() and r.value = 1 and r.user_id <> auth.uid()
         group by r.post_id, p.body
        union all
        select 'follow'::text,
               (select x.id from public.posts x where x.user_id = f.follower_id and x.status = 'approved' order by x.created_at desc limit 1),
               (select left(coalesce(nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''), split_part(u.email, '@', 1)), 60) from auth.users u where u.id = f.follower_id),
               (select case when u.raw_user_meta_data ->> 'avatar' ~ '^mask-[a-z-]{2,20}$' then u.raw_user_meta_data ->> 'avatar' end from auth.users u where u.id = f.follower_id),
               null::text, 1, f.created_at
          from public.follows f
         where f.followed_id = auth.uid()
           and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = f.follower_id)
    ) items
    order by 7 desc
    limit 50;
$$;
revoke execute on function public.my_notifications() from public, anon;
grant execute on function public.my_notifications() to authenticated;

-- 10. Listas para o dono
create or replace view public.moderacao with (security_invoker = true) as
    select 'momento (posts)'::text as tipo, p.id::text as id, p.author as autor, left(p.body, 200) as texto, p.report_count as denuncias, p.status as estado, p.created_at as criado
      from public.posts p where p.report_count > 0
    union all
    select 'comentário (post_comments)', c.id::text, c.author, left(c.comment, 200), c.report_count, c.status, c.created_at
      from public.post_comments c where c.report_count > 0
    union all
    select 'avaliação (reviews)', r.id::text, r.author, left(coalesce(r.comment, ''), 200), r.report_count, r.status, r.created_at
      from public.reviews r where r.report_count > 0
    union all
    select 'foto ou vídeo (submissions)', s.id::text, s.author, coalesce(s.caption, s.url), s.report_count, s.status, s.created_at
      from public.submissions s where s.report_count > 0
    order by criado desc;
revoke all on public.moderacao from anon, authenticated;

create or replace view public.atualizacoes_de_donos with (security_invoker = true) as
    select id, created_at as recebido, name as lugar, other_link ->> 'url' as no_tuende, contact as contacto, phone as telefone,
           email, website, reason as dados, photos as fotos, status as estado
      from public.recommendations
     where relationship = 'owner' and reason like 'ATUALIZAÇÃO do lugar #%'
     order by created_at desc;
revoke all on public.atualizacoes_de_donos from anon, authenticated;

-- As funções de gatilho não se chamam pela API (como em 2026-10-20-endurecer-funcoes.sql).
revoke execute on function public.check_post_photos() from public, anon, authenticated;
revoke execute on function public.check_blocked_words() from public, anon, authenticated;
revoke execute on function public.handle_post_report() from public, anon, authenticated;

-- Teste: uma conta existente publica um momento e um comentário, e tudo é logo desfeito.
-- Se algo falhar, dá erro e nada fica aplicado.
do $$
declare
    uid uuid := (select id from auth.users order by created_at limit 1);
    new_post uuid;
begin
    if uid is null then
        return;
    end if;
    begin
        perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
        set local role authenticated;
        insert into public.posts (venue_id, body, tags) values (1, 'teste de permissões', array['comida']) returning id into new_post;
        insert into public.post_comments (post_id, comment) values (new_post, 'teste de permissões');
        insert into public.post_reactions (post_id, value) values (new_post, 1);
        perform * from public.my_stats();
        perform * from public.my_notifications();
        perform * from public.following_posts();
        perform * from public.author_profile(new_post);
        perform * from public.author_posts(new_post);
        raise exception using errcode = 'TT001', message = 'teste ok';
    exception when sqlstate 'TT001' then
        null; -- O momento de teste foi aceite (gatilhos e regras correram) e já foi desfeito.
    end;
    reset role;
end;
$$;

commit;
