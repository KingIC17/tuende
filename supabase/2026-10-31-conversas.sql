-- 31 de outubro de 2026: listas de seguidores e Conversas (como no WhatsApp: a dois e em grupo).
--
-- Regras:
--   * Tudo passa por funções (security definer). Os visitantes nunca leem estas tabelas diretamente e cada pessoa é
--     identificada por um id público aleatório (public.people.public_id), nunca pelo id da conta.
--   * Conversas só entre amigos: pessoas que se seguem uma à outra (e que não se bloquearam).
--   * Fotos e vídeos ficam no balde privado "chat", numa pasta com o id da conversa; só quem está na conversa os envia
--     e os vê (a app pede links assinados).
--   * Mensagens com palavras da lista bloqueada são recusadas; no máximo 30 mensagens por minuto por conta.
--   * Denunciar esconde a mensagem para quem denunciou; com 2 denúncias fica escondida para todos. O dono vê as
--     denúncias na vista public.conversas_denunciadas (no painel do Supabase).
-- Pode correr-se mais de uma vez.

begin;

-- ---------------------------------------------------------------- Pessoas

create table if not exists public.people (
    user_id uuid primary key references auth.users (id) on delete cascade,
    public_id uuid not null unique default gen_random_uuid(),
    created_at timestamptz not null default now()
);
alter table public.people enable row level security;
revoke all on public.people from anon, authenticated;

create or replace function public.person_id(u uuid) returns uuid
    language plpgsql security definer set search_path = public as $$
declare
    p uuid;
begin
    if u is null then
        return null;
    end if;
    select public_id into p from public.people where user_id = u;
    if p is null then
        insert into public.people (user_id) values (u) on conflict (user_id) do nothing;
        select public_id into p from public.people where user_id = u;
    end if;
    return p;
end;
$$;

create or replace function public.person_user(p uuid) returns uuid
    language sql stable security definer set search_path = public as $$
    select user_id from public.people where public_id = p;
$$;

-- Nome e foto de uma conta (as mesmas regras de current_display_name e current_avatar).
create or replace function public.name_of(u uuid) returns text
    language sql stable security definer set search_path = public as $$
    select left(coalesce(nullif(trim(raw_user_meta_data ->> 'display_name'), ''), split_part(email, '@', 1)), 60)
      from auth.users where id = u;
$$;

create or replace function public.avatar_of(u uuid) returns text
    language sql stable security definer set search_path = public as $$
    select case
               when a ~ '^mask-[a-z-]{2,20}$' then a
               when a ~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/submissions/' || u::text || '/avatar-[0-9]+\.jpg$') then a
           end
      from (select raw_user_meta_data ->> 'avatar' as a from auth.users where id = u) s;
$$;

create or replace function public.is_blocked_between(a uuid, b uuid) returns boolean
    language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.blocks where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a));
$$;

create or replace function public.are_friends(a uuid, b uuid) returns boolean
    language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.follows where follower_id = a and followed_id = b)
       and exists (select 1 from public.follows where follower_id = b and followed_id = a)
       and not public.is_blocked_between(a, b);
$$;

-- Funções internas: só as outras funções as usam.
revoke execute on function public.person_id(uuid) from public, anon, authenticated;
revoke execute on function public.person_user(uuid) from public, anon, authenticated;
revoke execute on function public.name_of(uuid) from public, anon, authenticated;
revoke execute on function public.avatar_of(uuid) from public, anon, authenticated;
revoke execute on function public.is_blocked_between(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.are_friends(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- Seguidores, a seguir, amigos

-- list: 'followers' (quem me segue), 'following' (quem eu sigo) ou 'friends' (seguimo-nos um ao outro).
create or replace function public.my_people(list text)
    returns table (person uuid, name text, avatar text, i_follow boolean, follows_me boolean)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null then
        return;
    end if;
    return query
    select public.person_id(x.uid), public.name_of(x.uid), public.avatar_of(x.uid),
           exists (select 1 from public.follows f where f.follower_id = me and f.followed_id = x.uid),
           exists (select 1 from public.follows f where f.follower_id = x.uid and f.followed_id = me)
      from (
            select f.follower_id as uid from public.follows f where list = 'followers' and f.followed_id = me
            union
            select f.followed_id from public.follows f where list = 'following' and f.follower_id = me
            union
            select f.followed_id from public.follows f
             where list = 'friends' and f.follower_id = me
               and exists (select 1 from public.follows g where g.follower_id = f.followed_id and g.followed_id = me)
           ) x
     where not public.is_blocked_between(me, x.uid)
     order by 2;
end;
$$;

-- O id público de quem publicou um momento (para abrir o perfil ou enviar mensagem).
create or replace function public.person_of_post(post uuid) returns uuid
    language plpgsql security definer set search_path = public as $$
declare
    u uuid;
begin
    select user_id into u from public.posts where id = post and status = 'approved';
    return public.person_id(u);
end;
$$;

create or replace function public.person_profile(p uuid)
    returns table (person uuid, name text, avatar text, posts integer, followers integer, following integer,
                   i_follow boolean, follows_me boolean, is_me boolean)
    language plpgsql security definer set search_path = public as $$
declare
    u uuid := public.person_user(p);
    me uuid := auth.uid();
begin
    if u is null or (me is not null and public.is_blocked_between(me, u)) then
        return;
    end if;
    return query
    select p, public.name_of(u), public.avatar_of(u),
           (select count(*)::integer from public.posts x where x.user_id = u and x.status = 'approved'),
           (select count(*)::integer from public.follows f where f.followed_id = u),
           (select count(*)::integer from public.follows f where f.follower_id = u),
           exists (select 1 from public.follows f where f.follower_id = me and f.followed_id = u),
           exists (select 1 from public.follows f where f.follower_id = u and f.followed_id = me),
           coalesce(u = me, false);
end;
$$;

create or replace function public.person_posts(p uuid)
    returns table (id uuid, author text, author_avatar text, venue_id integer, place_name text, lat double precision, lng double precision,
                   body text, photos text[], tags text[], created_at timestamptz, status text)
    language sql stable security definer set search_path = public as $$
    select x.id, x.author, x.author_avatar, x.venue_id, x.place_name, x.lat, x.lng, x.body, x.photos, x.tags, x.created_at, x.status
      from public.posts x
     where x.user_id = public.person_user(p) and x.status = 'approved'
       and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = x.user_id)
     order by x.created_at desc
     limit 60;
$$;

-- Seguir ou deixar de seguir pelo id público. Responde 'following', 'not_following', 'self' ou 'not_found'.
create or replace function public.follow_person(p uuid, follow boolean) returns text
    language plpgsql security definer set search_path = public as $$
declare
    target uuid := public.person_user(p);
begin
    if auth.uid() is null then
        raise exception 'not_signed_in';
    end if;
    if target is null or public.is_blocked_between(auth.uid(), target) then
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

revoke execute on function public.my_people(text) from public, anon;
grant execute on function public.my_people(text) to authenticated;
revoke execute on function public.person_of_post(uuid) from public;
grant execute on function public.person_of_post(uuid) to anon, authenticated;
revoke execute on function public.person_profile(uuid) from public;
grant execute on function public.person_profile(uuid) to anon, authenticated;
revoke execute on function public.person_posts(uuid) from public;
grant execute on function public.person_posts(uuid) to anon, authenticated;
revoke execute on function public.follow_person(uuid, boolean) from public, anon;
grant execute on function public.follow_person(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------- Conversas

create table if not exists public.conversations (
    id uuid primary key default gen_random_uuid(),
    kind text not null check (kind in ('direct', 'group')),
    title text check (title is null or char_length(title) between 1 and 60),
    direct_key text unique,
    created_by uuid references auth.users (id) on delete set null,
    created_at timestamptz not null default now(),
    last_message_at timestamptz not null default now()
);
create index if not exists conversations_created_by_idx on public.conversations (created_by);

create table if not exists public.conversation_members (
    conversation_id uuid not null references public.conversations (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    role text not null default 'member' check (role in ('admin', 'member')),
    joined_at timestamptz not null default now(),
    last_read_at timestamptz not null default now(),
    primary key (conversation_id, user_id)
);
create index if not exists conversation_members_user_idx on public.conversation_members (user_id);

create table if not exists public.chat_messages (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references public.conversations (id) on delete cascade,
    -- Ao apagar a conta, as mensagens dessa pessoa também são apagadas.
    sender_id uuid references auth.users (id) on delete cascade,
    kind text not null check (kind in ('text', 'photo', 'video', 'location', 'place', 'event', 'moment', 'poll', 'game', 'system')),
    body text check (body is null or char_length(body) <= 2000),
    data jsonb not null default '{}'::jsonb check (pg_column_size(data) <= 16000),
    hidden boolean not null default false,
    created_at timestamptz not null default now()
);
create index if not exists chat_messages_conversation_idx on public.chat_messages (conversation_id, created_at desc);
create index if not exists chat_messages_sender_idx on public.chat_messages (sender_id);

create table if not exists public.chat_votes (
    message_id uuid not null references public.chat_messages (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    option smallint not null check (option between 0 and 9),
    created_at timestamptz not null default now(),
    primary key (message_id, user_id)
);
create index if not exists chat_votes_user_idx on public.chat_votes (user_id);

create table if not exists public.chat_game_answers (
    message_id uuid not null references public.chat_messages (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    question smallint not null check (question between 0 and 19),
    answer smallint not null check (answer between 0 and 9),
    correct boolean not null,
    created_at timestamptz not null default now(),
    primary key (message_id, user_id, question)
);
create index if not exists chat_game_answers_user_idx on public.chat_game_answers (user_id);

create table if not exists public.chat_reports (
    message_id uuid not null references public.chat_messages (id) on delete cascade,
    reporter_id uuid not null references auth.users (id) on delete cascade,
    reason text check (reason is null or char_length(reason) <= 300),
    created_at timestamptz not null default now(),
    primary key (message_id, reporter_id)
);
create index if not exists chat_reports_reporter_idx on public.chat_reports (reporter_id);

alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_votes enable row level security;
alter table public.chat_game_answers enable row level security;
alter table public.chat_reports enable row level security;
revoke all on public.conversations, public.conversation_members, public.chat_messages, public.chat_votes,
              public.chat_game_answers, public.chat_reports from anon, authenticated;

-- A outra pessoa de uma conversa a dois.
create or replace function public.direct_other(conv uuid, me uuid) returns uuid
    language sql stable security definer set search_path = public as $$
    select case when split_part(direct_key, ':', 1)::uuid = me then split_part(direct_key, ':', 2)::uuid
                else split_part(direct_key, ':', 1)::uuid end
      from public.conversations where id = conv and kind = 'direct';
$$;

create or replace function public.is_chat_member(conv uuid) returns boolean
    language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.conversation_members where conversation_id = conv and user_id = auth.uid());
$$;

-- Para as regras do balde "chat": a primeira pasta do ficheiro é o id da conversa.
create or replace function public.chat_path_member(object_name text) returns boolean
    language plpgsql stable security definer set search_path = public as $$
declare
    conv uuid;
begin
    begin
        conv := split_part(object_name, '/', 1)::uuid;
    exception when others then
        return false;
    end;
    return exists (select 1 from public.conversation_members where conversation_id = conv and user_id = auth.uid());
end;
$$;

revoke execute on function public.direct_other(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.is_chat_member(uuid) from public, anon, authenticated;
revoke execute on function public.chat_path_member(text) from public, anon;
grant execute on function public.chat_path_member(text) to authenticated;

-- Mensagem automática ("criou o grupo", "entrou", "saiu", "mudou o nome").
create or replace function public.chat_system(conv uuid, info jsonb) returns void
    language sql security definer set search_path = public as $$
    insert into public.chat_messages (conversation_id, sender_id, kind, data) values (conv, auth.uid(), 'system', info);
    update public.conversations set last_message_at = now() where id = conv;
$$;
revoke execute on function public.chat_system(uuid, jsonb) from public, anon, authenticated;

-- Abre (ou cria) a conversa a dois com um amigo. Erros: not_signed_in, not_found, not_friends, blocked.
create or replace function public.open_direct(p uuid) returns uuid
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    other uuid := public.person_user(p);
    k text;
    conv uuid;
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    if other is null or other = me then
        raise exception 'not_found';
    end if;
    if public.is_blocked_between(me, other) then
        raise exception 'blocked';
    end if;
    k := least(me, other)::text || ':' || greatest(me, other)::text;
    select id into conv from public.conversations where direct_key = k;
    if conv is null then
        if not public.are_friends(me, other) then
            raise exception 'not_friends';
        end if;
        insert into public.conversations (kind, direct_key, created_by) values ('direct', k, me)
            on conflict (direct_key) do nothing returning id into conv;
        if conv is null then
            select id into conv from public.conversations where direct_key = k;
        end if;
    end if;
    insert into public.conversation_members (conversation_id, user_id, role)
        values (conv, me, 'admin'), (conv, other, 'admin') on conflict do nothing;
    return conv;
end;
$$;

-- Cria um grupo com amigos (até 50 pessoas). Erros: not_signed_in, bad_title, blocked_words_text, no_people, too_many, not_friends.
create or replace function public.create_group(title text, people uuid[]) returns uuid
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    clean text := left(trim(coalesce(title, '')), 60);
    conv uuid;
    p uuid;
    u uuid;
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    if clean = '' then
        raise exception 'bad_title';
    end if;
    if public.has_blocked_words(clean) then
        raise exception 'blocked_words_text';
    end if;
    if coalesce(array_length(people, 1), 0) = 0 then
        raise exception 'no_people';
    end if;
    if array_length(people, 1) > 49 then
        raise exception 'too_many';
    end if;
    insert into public.conversations (kind, title, created_by) values ('group', clean, me) returning id into conv;
    insert into public.conversation_members (conversation_id, user_id, role) values (conv, me, 'admin');
    foreach p in array people loop
        u := public.person_user(p);
        if u is null or u = me or not public.are_friends(me, u) then
            raise exception 'not_friends';
        end if;
        insert into public.conversation_members (conversation_id, user_id) values (conv, u) on conflict do nothing;
    end loop;
    perform public.chat_system(conv, jsonb_build_object('event', 'created', 'title', clean));
    return conv;
end;
$$;

-- Acrescenta amigos a um grupo (quem administra o grupo).
create or replace function public.add_to_group(conv uuid, people uuid[]) returns void
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    p uuid;
    u uuid;
    names text[] := '{}';
begin
    if not exists (select 1 from public.conversation_members m join public.conversations c on c.id = m.conversation_id
                    where m.conversation_id = conv and m.user_id = me and m.role = 'admin' and c.kind = 'group') then
        raise exception 'not_allowed';
    end if;
    if (select count(*) from public.conversation_members where conversation_id = conv) + coalesce(array_length(people, 1), 0) > 50 then
        raise exception 'too_many';
    end if;
    foreach p in array coalesce(people, '{}') loop
        u := public.person_user(p);
        if u is null or not public.are_friends(me, u) then
            raise exception 'not_friends';
        end if;
        insert into public.conversation_members (conversation_id, user_id) values (conv, u) on conflict do nothing;
        names := names || public.name_of(u);
    end loop;
    if array_length(names, 1) > 0 then
        perform public.chat_system(conv, jsonb_build_object('event', 'added', 'names', to_jsonb(names)));
    end if;
end;
$$;

-- Sair de um grupo ou apagar uma conversa a dois da lista (volta a aparecer se a outra pessoa escrever).
create or replace function public.leave_conversation(conv uuid) returns void
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    k text;
begin
    select kind into k from public.conversations where id = conv;
    if k is null or not public.is_chat_member(conv) then
        return;
    end if;
    if k = 'group' then
        perform public.chat_system(conv, jsonb_build_object('event', 'left'));
    end if;
    delete from public.conversation_members where conversation_id = conv and user_id = me;
    if k = 'group' then
        -- Quem administra passa a ser quem está há mais tempo; um grupo vazio desaparece.
        if not exists (select 1 from public.conversation_members where conversation_id = conv and role = 'admin') then
            update public.conversation_members set role = 'admin'
             where conversation_id = conv
               and user_id = (select user_id from public.conversation_members where conversation_id = conv order by joined_at limit 1);
        end if;
        if not exists (select 1 from public.conversation_members where conversation_id = conv) then
            delete from public.conversations where id = conv;
        end if;
    elsif not exists (select 1 from public.conversation_members where conversation_id = conv) then
        delete from public.conversations where id = conv;
    end if;
end;
$$;

create or replace function public.rename_group(conv uuid, title text) returns void
    language plpgsql security definer set search_path = public as $$
declare
    clean text := left(trim(coalesce(title, '')), 60);
begin
    if clean = '' then
        raise exception 'bad_title';
    end if;
    if not exists (select 1 from public.conversations where id = conv and kind = 'group') or not public.is_chat_member(conv) then
        raise exception 'not_allowed';
    end if;
    if public.has_blocked_words(clean) then
        raise exception 'blocked_words_text';
    end if;
    update public.conversations set title = clean where id = conv;
    perform public.chat_system(conv, jsonb_build_object('event', 'renamed', 'title', clean));
end;
$$;

-- Enviar uma mensagem. Tipos: text, photo, video (data.path na pasta da conversa), location (data.lat, data.lng),
-- place (data.id), event (data.id), moment (data.post), poll (data.question, data.options) e game (data.questions).
create or replace function public.send_message(conv uuid, kind text, body text default null, data jsonb default '{}'::jsonb)
    returns table (id uuid, created_at timestamptz)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    c public.conversations;
    other uuid;
    txt text := nullif(left(trim(coalesce(body, '')), 2000), '');
    d jsonb := coalesce(data, '{}'::jsonb);
    q jsonb;
    o jsonb;
    new_id uuid;
    new_at timestamptz;
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    select * into c from public.conversations where conversations.id = conv;
    if c.id is null then
        raise exception 'not_found';
    end if;
    if c.kind = 'direct' then
        other := public.direct_other(conv, me);
        if other is null or not (me = split_part(c.direct_key, ':', 1)::uuid or me = split_part(c.direct_key, ':', 2)::uuid) then
            raise exception 'not_allowed';
        end if;
        if public.is_blocked_between(me, other) then
            raise exception 'blocked';
        end if;
        -- Quem tinha apagado a conversa volta a vê-la.
        insert into public.conversation_members (conversation_id, user_id, role)
            values (conv, me, 'admin'), (conv, other, 'admin') on conflict do nothing;
    elsif not public.is_chat_member(conv) then
        raise exception 'not_allowed';
    end if;
    if (select count(*) from public.chat_messages m where m.sender_id = me and m.created_at > now() - interval '1 minute') >= 30 then
        raise exception 'too_fast';
    end if;
    if txt is not null and public.has_blocked_words(txt) then
        raise exception 'blocked_words_text';
    end if;

    if kind = 'text' then
        if txt is null then
            raise exception 'empty';
        end if;
        d := '{}'::jsonb;
    elsif kind in ('photo', 'video') then
        if coalesce(d ->> 'path', '') not like conv::text || '/%' or char_length(d ->> 'path') > 200 then
            raise exception 'bad_media';
        end if;
        d := jsonb_build_object('path', d ->> 'path', 'w', (d ->> 'w')::integer, 'h', (d ->> 'h')::integer);
        txt := left(txt, 500);
    elsif kind = 'location' then
        if (d ->> 'lat') is null or (d ->> 'lng') is null
           or (d ->> 'lat')::double precision not between -90 and 90 or (d ->> 'lng')::double precision not between -180 and 180 then
            raise exception 'bad_location';
        end if;
        d := jsonb_build_object('lat', (d ->> 'lat')::double precision, 'lng', (d ->> 'lng')::double precision,
                                'label', left(coalesce(d ->> 'label', ''), 120));
    elsif kind = 'place' then
        if (d ->> 'id')::integer is null or (d ->> 'id')::integer <= 0 then
            raise exception 'bad_place';
        end if;
        d := jsonb_build_object('id', (d ->> 'id')::integer);
    elsif kind = 'event' then
        if coalesce(d ->> 'id', '') !~ '^[a-z0-9-]{2,80}$' then
            raise exception 'bad_event';
        end if;
        d := jsonb_build_object('id', d ->> 'id');
    elsif kind = 'moment' then
        if not exists (select 1 from public.posts p where p.id = (d ->> 'post')::uuid and (p.status = 'approved' or p.user_id = me)) then
            raise exception 'bad_moment';
        end if;
        d := jsonb_build_object('post', d ->> 'post');
    elsif kind = 'poll' then
        if char_length(trim(coalesce(d ->> 'question', ''))) not between 1 and 140
           or coalesce(jsonb_typeof(d -> 'options'), '') <> 'array' or jsonb_array_length(d -> 'options') not between 2 and 6 then
            raise exception 'bad_poll';
        end if;
        for o in select * from jsonb_array_elements(d -> 'options') loop
            if char_length(trim(coalesce(o ->> 'label', ''))) not between 1 and 80 then
                raise exception 'bad_poll';
            end if;
            if public.has_blocked_words(o ->> 'label') then
                raise exception 'blocked_words_text';
            end if;
        end loop;
        if public.has_blocked_words(d ->> 'question') then
            raise exception 'blocked_words_text';
        end if;
    elsif kind = 'game' then
        if coalesce(jsonb_typeof(d -> 'questions'), '') <> 'array' or jsonb_array_length(d -> 'questions') not between 1 and 10 then
            raise exception 'bad_game';
        end if;
        for q in select * from jsonb_array_elements(d -> 'questions') loop
            if coalesce(jsonb_typeof(q -> 'options'), '') <> 'array' or jsonb_array_length(q -> 'options') not between 2 and 4
               or (q ->> 'answer') is null
               or (q ->> 'answer')::integer not between 0 and jsonb_array_length(q -> 'options') - 1 then
                raise exception 'bad_game';
            end if;
        end loop;
    else
        raise exception 'bad_kind';
    end if;

    insert into public.chat_messages (conversation_id, sender_id, kind, body, data)
        values (conv, me, kind, txt, d) returning chat_messages.id, chat_messages.created_at into new_id, new_at;
    update public.conversations set last_message_at = new_at where conversations.id = conv;
    update public.conversation_members set last_read_at = new_at where conversation_id = conv and user_id = me;
    return query select new_id, new_at;
end;
$$;

-- A lista de conversas, com a última mensagem e quantas faltam ler.
create or replace function public.my_conversations()
    returns table (id uuid, kind text, title text, avatar text, person uuid, members integer, last_kind text, last_body text,
                   last_data jsonb, last_mine boolean, last_sender text, last_at timestamptz, unread integer)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null then
        return;
    end if;
    return query
    select c.id, c.kind,
           case when c.kind = 'group' then c.title else public.name_of(public.direct_other(c.id, me)) end,
           case when c.kind = 'direct' then public.avatar_of(public.direct_other(c.id, me)) end,
           case when c.kind = 'direct' then public.person_id(public.direct_other(c.id, me)) end,
           (select count(*)::integer from public.conversation_members x where x.conversation_id = c.id),
           lm.kind, left(lm.body, 140), lm.data, lm.sender_id = me, public.name_of(lm.sender_id),
           coalesce(lm.created_at, c.created_at),
           (select count(*)::integer from public.chat_messages m
             where m.conversation_id = c.id and m.created_at > cm.last_read_at and m.sender_id is distinct from me
               and m.kind <> 'system' and not m.hidden)
      from public.conversation_members cm
      join public.conversations c on c.id = cm.conversation_id
      left join lateral (
            select m.kind, m.body, m.data, m.sender_id, m.created_at
              from public.chat_messages m
             where m.conversation_id = c.id and not m.hidden
               and not exists (select 1 from public.blocks b where b.blocker_id = me and b.blocked_id = m.sender_id)
             order by m.created_at desc
             limit 1
           ) lm on true
     where cm.user_id = me
     order by coalesce(lm.created_at, c.created_at) desc;
end;
$$;

-- Mensagens de uma conversa: as últimas (lim), as mais novas do que newer_than ou as mais antigas do que older_than.
create or replace function public.conversation_messages(conv uuid, newer_than timestamptz default null, older_than timestamptz default null, lim integer default 60)
    returns table (id uuid, sender uuid, sender_name text, sender_avatar text, mine boolean, kind text, body text, data jsonb, created_at timestamptz)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null or not public.is_chat_member(conv) then
        return;
    end if;
    return query
    select m.id, public.person_id(m.sender_id), public.name_of(m.sender_id), public.avatar_of(m.sender_id),
           m.sender_id = me, m.kind, m.body, m.data, m.created_at
      from (
            select * from public.chat_messages x
             where x.conversation_id = conv and not x.hidden
               and (newer_than is null or x.created_at > newer_than)
               and (older_than is null or x.created_at < older_than)
               and not exists (select 1 from public.blocks b where b.blocker_id = me and b.blocked_id = x.sender_id)
               and not exists (select 1 from public.chat_reports r where r.message_id = x.id and r.reporter_id = me)
             order by x.created_at desc
             limit least(greatest(coalesce(lim, 60), 1), 200)
           ) m
     order by m.created_at;
end;
$$;

-- Votos e respostas dos jogos (para atualizar os cartões enquanto a conversa está aberta).
create or replace function public.chat_states(conv uuid)
    returns table (message_id uuid, votes jsonb, my_vote smallint, scores jsonb, my_answers jsonb)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null or not public.is_chat_member(conv) then
        return;
    end if;
    return query
    select m.id,
           case when m.kind = 'poll' then
               (select coalesce(jsonb_object_agg(v.option::text, v.n), '{}'::jsonb)
                  from (select cv.option, count(*) as n from public.chat_votes cv where cv.message_id = m.id group by cv.option) v) end,
           case when m.kind = 'poll' then (select cv.option from public.chat_votes cv where cv.message_id = m.id and cv.user_id = me) end,
           case when m.kind = 'game' then
               (select coalesce(jsonb_agg(jsonb_build_object('name', public.name_of(a.user_id), 'me', a.user_id = me, 'right', a.r, 'done', a.n)
                                          order by a.r desc, a.n desc), '[]'::jsonb)
                  from (select ga.user_id, count(*) filter (where ga.correct) as r, count(*) as n
                          from public.chat_game_answers ga where ga.message_id = m.id group by ga.user_id) a) end,
           case when m.kind = 'game' then
               (select coalesce(jsonb_agg(jsonb_build_object('q', ga.question, 'a', ga.answer, 'ok', ga.correct) order by ga.question), '[]'::jsonb)
                  from public.chat_game_answers ga where ga.message_id = m.id and ga.user_id = me) end
      from public.chat_messages m
     where m.conversation_id = conv and m.kind in ('poll', 'game') and not m.hidden
     order by m.created_at desc
     limit 100;
end;
$$;

-- Votar numa opção (votar outra vez na mesma tira o voto).
create or replace function public.vote_poll(msg uuid, choice integer) returns void
    language plpgsql security definer set search_path = public as $$
declare
    m public.chat_messages;
begin
    select * into m from public.chat_messages where id = msg and kind = 'poll' and not hidden;
    if m.id is null or not public.is_chat_member(m.conversation_id) then
        raise exception 'not_allowed';
    end if;
    if choice < 0 or choice >= jsonb_array_length(m.data -> 'options') then
        raise exception 'bad_choice';
    end if;
    if exists (select 1 from public.chat_votes where message_id = msg and user_id = auth.uid() and option = choice) then
        delete from public.chat_votes where message_id = msg and user_id = auth.uid();
    else
        insert into public.chat_votes (message_id, user_id, option) values (msg, auth.uid(), choice)
            on conflict (message_id, user_id) do update set option = excluded.option, created_at = now();
    end if;
end;
$$;

-- Responder a uma pergunta de um jogo (conta a primeira resposta). Devolve se acertou.
create or replace function public.answer_game(msg uuid, q integer, choice integer) returns boolean
    language plpgsql security definer set search_path = public as $$
declare
    m public.chat_messages;
    right_answer integer;
    ok boolean;
begin
    select * into m from public.chat_messages where id = msg and kind = 'game' and not hidden;
    if m.id is null or not public.is_chat_member(m.conversation_id) then
        raise exception 'not_allowed';
    end if;
    if q < 0 or q >= jsonb_array_length(m.data -> 'questions') then
        raise exception 'bad_question';
    end if;
    right_answer := (m.data -> 'questions' -> q ->> 'answer')::integer;
    insert into public.chat_game_answers (message_id, user_id, question, answer, correct)
        values (msg, auth.uid(), q, choice, choice = right_answer) on conflict do nothing;
    select correct into ok from public.chat_game_answers where message_id = msg and user_id = auth.uid() and question = q;
    return ok;
end;
$$;

create or replace function public.mark_conversation_read(conv uuid) returns void
    language sql security definer set search_path = public as $$
    update public.conversation_members set last_read_at = now() where conversation_id = conv and user_id = auth.uid();
$$;

create or replace function public.chat_unread_total() returns integer
    language sql stable security definer set search_path = public as $$
    select count(*)::integer
      from public.conversation_members cm
      join public.chat_messages m on m.conversation_id = cm.conversation_id
     where cm.user_id = auth.uid() and m.created_at > cm.last_read_at and m.sender_id is distinct from auth.uid()
       and m.kind <> 'system' and not m.hidden
       and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = m.sender_id);
$$;

-- Fotos e vídeos que a pessoa enviou, para a app os apagar antes de apagar a conta.
create or replace function public.my_chat_files() returns setof text
    language sql stable security definer set search_path = public as $$
    select m.data ->> 'path'
      from public.chat_messages m
     where m.sender_id = auth.uid() and m.kind in ('photo', 'video') and m.data ? 'path';
$$;

-- Nome do grupo e quem está nele.
create or replace function public.conversation_info(conv uuid)
    returns table (kind text, title text, i_admin boolean, members jsonb)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null or not public.is_chat_member(conv) then
        return;
    end if;
    return query
    select c.kind,
           case when c.kind = 'group' then c.title else public.name_of(public.direct_other(c.id, me)) end,
           exists (select 1 from public.conversation_members x where x.conversation_id = conv and x.user_id = me and x.role = 'admin'),
           (select coalesce(jsonb_agg(jsonb_build_object('person', public.person_id(x.user_id), 'name', public.name_of(x.user_id),
                                                         'avatar', public.avatar_of(x.user_id), 'admin', x.role = 'admin', 'me', x.user_id = me)
                                      order by x.joined_at), '[]'::jsonb)
              from public.conversation_members x where x.conversation_id = conv)
      from public.conversations c where c.id = conv;
end;
$$;

create or replace function public.report_chat_message(msg uuid, reason text default null) returns void
    language plpgsql security definer set search_path = public as $$
declare
    conv uuid;
begin
    select conversation_id into conv from public.chat_messages where id = msg;
    if conv is null or not public.is_chat_member(conv) then
        raise exception 'not_allowed';
    end if;
    insert into public.chat_reports (message_id, reporter_id, reason) values (msg, auth.uid(), left(reason, 300)) on conflict do nothing;
    if (select count(*) from public.chat_reports where message_id = msg) >= 2 then
        update public.chat_messages set hidden = true where id = msg;
    end if;
end;
$$;

-- Bloquear alguém a partir de uma conversa ou do perfil: deixam de se seguir e de se ver.
create or replace function public.block_person(p uuid) returns void
    language plpgsql security definer set search_path = public as $$
declare
    target uuid := public.person_user(p);
begin
    if auth.uid() is null or target is null or target = auth.uid() then
        return;
    end if;
    insert into public.blocks (blocker_id, blocked_id) values (auth.uid(), target) on conflict do nothing;
    delete from public.follows where (follower_id = auth.uid() and followed_id = target) or (follower_id = target and followed_id = auth.uid());
end;
$$;

do $$
declare
    f text;
begin
    foreach f in array array[
        'open_direct(uuid)', 'create_group(text, uuid[])', 'add_to_group(uuid, uuid[])', 'leave_conversation(uuid)',
        'rename_group(uuid, text)', 'send_message(uuid, text, text, jsonb)', 'my_conversations()',
        'conversation_messages(uuid, timestamptz, timestamptz, integer)', 'chat_states(uuid)', 'vote_poll(uuid, integer)',
        'answer_game(uuid, integer, integer)', 'mark_conversation_read(uuid)', 'chat_unread_total()', 'conversation_info(uuid)',
        'report_chat_message(uuid, text)', 'block_person(uuid)', 'my_chat_files()'
    ] loop
        execute format('revoke execute on function public.%s from public, anon', f);
        execute format('grant execute on function public.%s to authenticated', f);
    end loop;
end;
$$;

-- ---------------------------------------------------------------- Fotos e vídeos das conversas

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat', 'chat', false, 26214400, array['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/quicktime', 'video/webm'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Conversas: enviar fotos e vídeos" on storage.objects;
create policy "Conversas: enviar fotos e vídeos" on storage.objects for insert to authenticated
    with check (bucket_id = 'chat' and public.chat_path_member(name));
drop policy if exists "Conversas: ver fotos e vídeos" on storage.objects;
create policy "Conversas: ver fotos e vídeos" on storage.objects for select to authenticated
    using (bucket_id = 'chat' and public.chat_path_member(name));
drop policy if exists "Conversas: apagar as próprias fotos e vídeos" on storage.objects;
create policy "Conversas: apagar as próprias fotos e vídeos" on storage.objects for delete to authenticated
    using (bucket_id = 'chat' and owner_id = (select auth.uid())::text);

-- ---------------------------------------------------------------- Para o dono: mensagens denunciadas

create or replace view public.conversas_denunciadas with (security_invoker = true) as
    select r.created_at as denunciado, m.created_at as enviado, m.kind as tipo, m.body as texto, m.data as dados,
           (select count(*) from public.chat_reports x where x.message_id = m.id) as denuncias, m.hidden as escondida,
           r.reason as motivo, m.id as mensagem, m.conversation_id as conversa
      from public.chat_reports r
      join public.chat_messages m on m.id = r.message_id
     order by r.created_at desc;
revoke all on public.conversas_denunciadas from anon, authenticated;

-- ---------------------------------------------------------------- Teste (tudo é desfeito no fim)

do $$
declare
    uid uuid := (select id from auth.users order by created_at limit 1);
begin
    if uid is null then
        return;
    end if;
    begin
        perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
        set local role authenticated;
        perform * from public.my_people('followers');
        perform * from public.my_people('following');
        perform * from public.my_people('friends');
        perform * from public.my_conversations();
        perform public.chat_unread_total();
        raise exception using errcode = 'TT001', message = 'teste ok';
    exception when sqlstate 'TT001' then
        null;
    end;
    reset role;
end;
$$;

commit;
