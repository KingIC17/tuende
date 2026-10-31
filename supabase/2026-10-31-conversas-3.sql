-- 31 de outubro de 2026 (3.ª parte): Conversas como no Instagram.
--
--   * Nome de utilizador (@nome): único, 3 a 20 caracteres (a-z, 0-9, ponto e _), sem nomes reservados (tuende, admin...);
--     pode mudar-se à vontade nas primeiras 24 horas e depois uma vez a cada 30 dias. Procura só pelo nome exato.
--     "Quem me pode encontrar": toda a gente ou só quem tem o link do perfil (o link usa o id público aleatório).
--   * Mensagens: qualquer pessoa pode escrever a qualquer pessoa (exceto bloqueios). Se quem recebe não segue quem
--     escreve, a conversa chega como pedido (conversation_members.status = 'request'): até ser aceite, quem escreve
--     só pode mandar 1 mensagem de texto, não vê "Visto" e não há avisos no telemóvel. No máximo 20 pedidos novos por
--     dia por pessoa. "Quem me pode enviar mensagens": toda a gente ou só quem eu sigo.
--   * Grupos: pode juntar-se quem aceitaria uma mensagem sua; quem não segue quem o juntou recebe o grupo como pedido.
--   * "Visto" (last_read_at de quem aceitou e tem os recibos de leitura ligados; quem os desliga também não os vê),
--     "a escrever" (canal privado "conv:<id>" do Realtime, nada fica guardado), respostas a uma mensagem (reply_to),
--     reações (ícones do Tuende: heart, up, haha, check, star; uma por pessoa e mensagem) e procura dentro da conversa.
-- Pode correr-se mais de uma vez.

begin;

-- ---------------------------------------------------------------- Pessoas: nome de utilizador e privacidade

alter table public.people add column if not exists username text;
alter table public.people add column if not exists username_first_at timestamptz;
alter table public.people add column if not exists username_changed_at timestamptz;
alter table public.people add column if not exists discoverable boolean not null default true;
alter table public.people add column if not exists dm_policy text not null default 'everyone';
alter table public.people add column if not exists read_receipts boolean not null default true;
alter table public.people drop constraint if exists people_username_check;
alter table public.people add constraint people_username_check
    check (username is null or (username ~ '^[a-z0-9][a-z0-9._]{1,18}[a-z0-9]$' and username !~ '\.\.'));
alter table public.people drop constraint if exists people_dm_policy_check;
alter table public.people add constraint people_dm_policy_check check (dm_policy in ('everyone', 'following'));
create unique index if not exists people_username_key on public.people (username);

-- Estado de cada pessoa numa conversa: 'active' (aceitou) ou 'request' (pedido por aceitar).
alter table public.conversation_members add column if not exists status text not null default 'active';
alter table public.conversation_members drop constraint if exists conversation_members_status_check;
alter table public.conversation_members add constraint conversation_members_status_check check (status in ('active', 'request'));

create or replace function public.is_following(a uuid, b uuid) returns boolean
    language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.follows f where f.follower_id = a and f.followed_id = b);
$$;

create or replace function public.username_of(u uuid) returns text
    language sql stable security definer set search_path = public as $$
    select p.username from public.people p where p.user_id = u;
$$;

-- Nomes que ninguém pode usar (para ninguém se fazer passar pelo Tuende).
create or replace function public.username_reserved(n text) returns boolean
    language sql immutable set search_path = public as $$
    select n ~ '(tuende|angolive|admin|suporte|support|moderador|moderator|oficial|official)'
        or n = any (array['kamba', 'root', 'system', 'sistema', 'staff', 'equipa', 'team', 'help', 'ajuda', 'contacto',
                          'contact', 'info', 'null', 'undefined', 'api', 'www', 'app', 'conversas', 'momentos']);
$$;

-- a pode começar uma conversa com b? (sem bloqueio; b aceita toda a gente, segue a, ou já aceitou uma conversa com a)
create or replace function public.dm_allowed(a uuid, b uuid) returns boolean
    language sql stable security definer set search_path = public as $$
    select a is not null and b is not null and a <> b and not public.is_blocked_between(a, b)
       and (coalesce((select p.dm_policy from public.people p where p.user_id = b), 'everyone') = 'everyone'
            or public.is_following(b, a)
            or exists (select 1 from public.conversations c
                         join public.conversation_members cm on cm.conversation_id = c.id and cm.user_id = b and cm.status = 'active'
                        where c.direct_key = least(a, b)::text || ':' || greatest(a, b)::text));
$$;

revoke execute on function public.is_following(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.username_of(uuid) from public, anon, authenticated;
revoke execute on function public.username_reserved(text) from public, anon, authenticated;
revoke execute on function public.dm_allowed(uuid, uuid) from public, anon, authenticated;

-- O meu nome de utilizador e as minhas escolhas de privacidade.
create or replace function public.my_chat_profile()
    returns table (person uuid, username text, discoverable boolean, dm_policy text, read_receipts boolean, next_change timestamptz)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null then
        return;
    end if;
    perform public.person_id(me);
    return query
    select p.public_id, p.username, p.discoverable, p.dm_policy, p.read_receipts,
           case when p.username is null or p.username_first_at > now() - interval '24 hours'
                     or p.username_changed_at < now() - interval '30 days' then null
                else p.username_changed_at + interval '30 days' end
      from public.people p where p.user_id = me;
end;
$$;

-- Escolher ou mudar o nome de utilizador. Erros: bad_username, reserved_username, blocked_words_text, username_taken,
-- username_too_soon.
create or replace function public.set_username(uname text) returns text
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    clean text := lower(regexp_replace(trim(coalesce(uname, '')), '^@', ''));
    cur public.people;
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    if clean !~ '^[a-z0-9][a-z0-9._]{1,18}[a-z0-9]$' or clean ~ '\.\.' then
        raise exception 'bad_username';
    end if;
    if public.username_reserved(clean) then
        raise exception 'reserved_username';
    end if;
    if public.has_blocked_words(regexp_replace(clean, '[._]', ' ', 'g')) then
        raise exception 'blocked_words_text';
    end if;
    perform public.person_id(me);
    select * into cur from public.people p where p.user_id = me for update;
    if cur.username = clean then
        return clean;
    end if;
    if cur.username is not null and cur.username_first_at < now() - interval '24 hours'
       and cur.username_changed_at > now() - interval '30 days' then
        raise exception 'username_too_soon';
    end if;
    if exists (select 1 from public.people x where x.username = clean and x.user_id <> me) then
        raise exception 'username_taken';
    end if;
    update public.people p
       set username = clean, username_changed_at = now(), username_first_at = coalesce(p.username_first_at, now())
     where p.user_id = me;
    return clean;
exception when unique_violation then
    raise exception 'username_taken';
end;
$$;

-- Uma sugestão livre a partir do nome público (ex.: "Ana Luísa" -> ana.luisa ou ana.luisa27).
create or replace function public.suggest_username() returns text
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    base text;
    cand text;
    i integer := 0;
begin
    if me is null then
        return null;
    end if;
    base := translate(lower(coalesce(public.name_of(me), '')), 'áàâãäåéèêëíìîïóòôõöúùûüçñ', 'aaaaaaeeeeiiiiooooouuuucn');
    base := regexp_replace(base, '[^a-z0-9]+', '.', 'g');
    base := regexp_replace(base, '^[._]+|[._]+$', '', 'g');
    base := regexp_replace(left(base, 16), '[._]+$', '');
    if char_length(base) < 3 or public.username_reserved(base) then
        base := 'viajante';
    end if;
    cand := base;
    loop
        if cand ~ '^[a-z0-9][a-z0-9._]{1,18}[a-z0-9]$' and cand !~ '\.\.' and not public.username_reserved(cand)
           and not exists (select 1 from public.people x where x.username = cand) then
            return cand;
        end if;
        i := i + 1;
        exit when i > 25;
        cand := base || (10 + floor(random() * 990))::integer::text;
    end loop;
    return null;
end;
$$;

create or replace function public.set_chat_privacy(find_me boolean default null, messages text default null, receipts boolean default null)
    returns void
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    perform public.person_id(me);
    update public.people p
       set discoverable = coalesce(find_me, p.discoverable),
           dm_policy = case when messages in ('everyone', 'following') then messages else p.dm_policy end,
           read_receipts = coalesce(receipts, p.read_receipts)
     where p.user_id = me;
end;
$$;

-- Procurar alguém pelo nome de utilizador exato (só quem aceita ser encontrado).
create or replace function public.find_person(uname text)
    returns table (person uuid, name text, avatar text, username text, i_follow boolean, follows_me boolean)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    clean text := lower(regexp_replace(trim(coalesce(uname, '')), '^@', ''));
begin
    if me is null or char_length(clean) < 3 then
        return;
    end if;
    return query
    select public.person_id(p.user_id), public.name_of(p.user_id), public.avatar_of(p.user_id), p.username,
           public.is_following(me, p.user_id), public.is_following(p.user_id, me)
      from public.people p
     where p.username = clean and (p.discoverable or p.user_id = me) and not public.is_blocked_between(me, p.user_id);
end;
$$;

drop function if exists public.my_people(text);
create function public.my_people(list text)
    returns table (person uuid, name text, avatar text, username text, i_follow boolean, follows_me boolean)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null then
        return;
    end if;
    return query
    select public.person_id(x.uid), public.name_of(x.uid), public.avatar_of(x.uid), public.username_of(x.uid),
           public.is_following(me, x.uid), public.is_following(x.uid, me)
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

drop function if exists public.person_profile(uuid);
create function public.person_profile(p uuid)
    returns table (person uuid, name text, avatar text, username text, posts integer, followers integer, following integer,
                   i_follow boolean, follows_me boolean, is_me boolean, can_message boolean)
    language plpgsql security definer set search_path = public as $$
declare
    u uuid := public.person_user(p);
    me uuid := auth.uid();
begin
    if u is null or (me is not null and public.is_blocked_between(me, u)) then
        return;
    end if;
    return query
    select p, public.name_of(u), public.avatar_of(u), public.username_of(u),
           (select count(*)::integer from public.posts x where x.user_id = u and x.status = 'approved'),
           (select count(*)::integer from public.follows f where f.followed_id = u),
           (select count(*)::integer from public.follows f where f.follower_id = u),
           coalesce(public.is_following(me, u), false),
           coalesce(public.is_following(u, me), false),
           coalesce(u = me, false),
           coalesce(public.dm_allowed(me, u), false);
end;
$$;

-- ---------------------------------------------------------------- Pedidos, respostas e reações


alter table public.chat_messages add column if not exists reply_to uuid references public.chat_messages (id) on delete set null;
create index if not exists chat_messages_reply_idx on public.chat_messages (reply_to) where reply_to is not null;

create table if not exists public.chat_reactions (
    message_id uuid not null references public.chat_messages (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    reaction text not null check (reaction in ('heart', 'up', 'haha', 'check', 'star')),
    created_at timestamptz not null default now(),
    primary key (message_id, user_id)
);
create index if not exists chat_reactions_user_idx on public.chat_reactions (user_id);
alter table public.chat_reactions enable row level security;
revoke all on public.chat_reactions from anon, authenticated;

create or replace function public.is_active_member(conv uuid) returns boolean
    language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.conversation_members
                    where conversation_id = conv and user_id = auth.uid() and status = 'active');
$$;
revoke execute on function public.is_active_member(uuid) from public, anon, authenticated;

-- Abre a conversa a dois (ou cria-a). A outra pessoa só entra quando receber a primeira mensagem.
-- Erros: not_signed_in, not_found, blocked, dm_closed.
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
    select c.id into conv from public.conversations c where c.direct_key = k;
    if conv is null then
        if not public.dm_allowed(me, other) then
            raise exception 'dm_closed';
        end if;
        insert into public.conversations (kind, direct_key, created_by) values ('direct', k, me)
            on conflict (direct_key) do nothing returning id into conv;
        if conv is null then
            select c.id into conv from public.conversations c where c.direct_key = k;
        end if;
    end if;
    insert into public.conversation_members (conversation_id, user_id, role, status)
        values (conv, me, 'admin', 'active') on conflict do nothing;
    return conv;
end;
$$;

-- Um grupo com pessoas que aceitariam uma mensagem sua; quem não o segue recebe o grupo como pedido.
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
    insert into public.conversation_members (conversation_id, user_id, role, status) values (conv, me, 'admin', 'active');
    foreach p in array people loop
        u := public.person_user(p);
        if u is null or u = me or not public.dm_allowed(me, u) then
            raise exception 'dm_closed';
        end if;
        insert into public.conversation_members (conversation_id, user_id, status)
            values (conv, u, case when public.is_following(u, me) then 'active' else 'request' end) on conflict do nothing;
    end loop;
    perform public.chat_system(conv, jsonb_build_object('event', 'created', 'title', clean));
    return conv;
end;
$$;

create or replace function public.add_to_group(conv uuid, people uuid[]) returns void
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    p uuid;
    u uuid;
    names text[] := '{}';
begin
    if not exists (select 1 from public.conversation_members m join public.conversations c on c.id = m.conversation_id
                    where m.conversation_id = conv and m.user_id = me and m.role = 'admin' and m.status = 'active' and c.kind = 'group') then
        raise exception 'not_allowed';
    end if;
    if (select count(*) from public.conversation_members x where x.conversation_id = conv) + coalesce(array_length(people, 1), 0) > 50 then
        raise exception 'too_many';
    end if;
    foreach p in array coalesce(people, '{}') loop
        u := public.person_user(p);
        if u is null or not public.dm_allowed(me, u) then
            raise exception 'dm_closed';
        end if;
        insert into public.conversation_members (conversation_id, user_id, status)
            values (conv, u, case when public.is_following(u, me) then 'active' else 'request' end) on conflict do nothing;
        names := names || public.name_of(u);
    end loop;
    if array_length(names, 1) > 0 then
        perform public.chat_system(conv, jsonb_build_object('event', 'added', 'names', to_jsonb(names)));
    end if;
end;
$$;

-- Sair de um grupo, apagar uma conversa da lista ou recusar um pedido (sem aviso a ninguém).
create or replace function public.leave_conversation(conv uuid) returns void
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    k text;
    st text;
begin
    select c.kind into k from public.conversations c where c.id = conv;
    select cm.status into st from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = me;
    if k is null or st is null then
        return;
    end if;
    if k = 'group' and st = 'active' then
        perform public.chat_system(conv, jsonb_build_object('event', 'left'));
    end if;
    delete from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = me;
    if k = 'group' then
        if not exists (select 1 from public.conversation_members x where x.conversation_id = conv and x.role = 'admin') then
            update public.conversation_members x set role = 'admin'
             where x.conversation_id = conv
               and x.user_id = (select y.user_id from public.conversation_members y where y.conversation_id = conv
                                 order by (y.status = 'active') desc, y.joined_at limit 1);
        end if;
    end if;
    if not exists (select 1 from public.conversation_members x where x.conversation_id = conv) then
        delete from public.conversations c where c.id = conv;
    end if;
end;
$$;

create or replace function public.accept_request(conv uuid) returns void
    language sql security definer set search_path = public as $$
    update public.conversation_members set status = 'active', last_read_at = now()
     where conversation_id = conv and user_id = auth.uid() and status = 'request';
$$;

create or replace function public.rename_group(conv uuid, title text) returns void
    language plpgsql security definer set search_path = public as $$
declare
    clean text := left(trim(coalesce(title, '')), 60);
begin
    if clean = '' then
        raise exception 'bad_title';
    end if;
    if not exists (select 1 from public.conversations c where c.id = conv and c.kind = 'group') or not public.is_active_member(conv) then
        raise exception 'not_allowed';
    end if;
    if public.has_blocked_words(clean) then
        raise exception 'blocked_words_text';
    end if;
    update public.conversations c set title = clean where c.id = conv;
    perform public.chat_system(conv, jsonb_build_object('event', 'renamed', 'title', clean));
end;
$$;

-- Enviar uma mensagem (reply = a mensagem a que responde). Num pedido ainda por aceitar: só 1 mensagem de texto.
-- Erros novos: dm_closed, too_many_requests, request_text_only, request_wait.
drop function if exists public.send_message(uuid, text, text, jsonb);
create or replace function public.send_message(conv uuid, kind text, body text default null, data jsonb default '{}'::jsonb, reply uuid default null)
    returns table (id uuid, created_at timestamptz)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    c public.conversations;
    other uuid;
    my_status text;
    other_status text;
    other_joined timestamptz;
    txt text := nullif(left(trim(coalesce(body, '')), 2000), '');
    d jsonb := coalesce(data, '{}'::jsonb);
    q jsonb;
    o jsonb;
    reply_id uuid := reply;
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
    select cm.status into my_status from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = me;
    if c.kind = 'direct' then
        if not (me = split_part(c.direct_key, ':', 1)::uuid or me = split_part(c.direct_key, ':', 2)::uuid) then
            raise exception 'not_allowed';
        end if;
        other := public.direct_other(conv, me);
        if public.is_blocked_between(me, other) then
            raise exception 'blocked';
        end if;
        if my_status is null then
            insert into public.conversation_members (conversation_id, user_id, role, status) values (conv, me, 'admin', 'active');
        elsif my_status = 'request' then
            -- Responder a um pedido é aceitá-lo.
            update public.conversation_members cm set status = 'active', last_read_at = now()
             where cm.conversation_id = conv and cm.user_id = me;
        end if;
        select cm.status, cm.joined_at into other_status, other_joined
          from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = other;
        if other_status is null then
            if not public.dm_allowed(me, other) then
                raise exception 'dm_closed';
            end if;
            other_status := case when public.is_following(other, me)
                                      or exists (select 1 from public.chat_messages m where m.conversation_id = conv
                                                    and m.sender_id = other and m.kind <> 'system')
                                 then 'active' else 'request' end;
            if other_status = 'request'
               and (select count(*) from public.conversation_members r join public.conversations rc on rc.id = r.conversation_id
                     where rc.kind = 'direct' and rc.created_by = me and r.user_id <> me and r.status = 'request'
                       and r.joined_at > now() - interval '1 day') >= 20 then
                raise exception 'too_many_requests';
            end if;
            insert into public.conversation_members (conversation_id, user_id, role, status) values (conv, other, 'admin', other_status);
            other_joined := now();
        end if;
        if other_status = 'request' then
            if kind <> 'text' then
                raise exception 'request_text_only';
            end if;
            if exists (select 1 from public.chat_messages m where m.conversation_id = conv and m.sender_id = me
                          and m.kind <> 'system' and m.created_at >= other_joined) then
                raise exception 'request_wait';
            end if;
        end if;
    else
        if my_status is null then
            raise exception 'not_allowed';
        end if;
        if my_status = 'request' then
            update public.conversation_members cm set status = 'active', last_read_at = now()
             where cm.conversation_id = conv and cm.user_id = me;
        end if;
    end if;
    if (select count(*) from public.chat_messages m where m.sender_id = me and m.created_at > now() - interval '1 minute') >= 30 then
        raise exception 'too_fast';
    end if;
    if txt is not null and public.has_blocked_words(txt) then
        raise exception 'blocked_words_text';
    end if;
    if reply_id is not null and not exists (select 1 from public.chat_messages r where r.id = reply_id and r.conversation_id = conv) then
        reply_id := null;
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
    elsif kind = 'audio' then
        if coalesce(d ->> 'path', '') not like conv::text || '/%' or char_length(d ->> 'path') > 200 then
            raise exception 'bad_media';
        end if;
        d := jsonb_build_object('path', d ->> 'path', 'dur', least(greatest(coalesce((d ->> 'dur')::numeric, 0), 0), 300)::integer);
        txt := null;
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

    insert into public.chat_messages (conversation_id, sender_id, kind, body, data, reply_to)
        values (conv, me, kind, txt, d, reply_id) returning chat_messages.id, chat_messages.created_at into new_id, new_at;
    update public.conversations set last_message_at = new_at where conversations.id = conv;
    update public.conversation_members cm set last_read_at = new_at where cm.conversation_id = conv and cm.user_id = me;
    return query select new_id, new_at;
end;
$$;

-- A lista: conversas aceites e pedidos (status), com o @nome da outra pessoa nas conversas a dois.
drop function if exists public.my_conversations();
create function public.my_conversations()
    returns table (id uuid, kind text, title text, avatar text, person uuid, username text, members integer, status text,
                   last_kind text, last_body text, last_data jsonb, last_mine boolean, last_sender text, last_at timestamptz, unread integer)
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
           case when c.kind = 'direct' then public.username_of(public.direct_other(c.id, me)) end,
           (select count(*)::integer from public.conversation_members x where x.conversation_id = c.id),
           cm.status,
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
     where cm.user_id = me and (c.created_by = me or lm.created_at is not null)
     order by coalesce(lm.created_at, c.created_at) desc;
end;
$$;

-- Mensagens, com a mensagem a que cada uma responde.
drop function if exists public.conversation_messages(uuid, timestamptz, timestamptz, integer);
create function public.conversation_messages(conv uuid, newer_than timestamptz default null, older_than timestamptz default null, lim integer default 60)
    returns table (id uuid, sender uuid, sender_name text, sender_avatar text, mine boolean, kind text, body text, data jsonb,
                   created_at timestamptz, reply_to uuid, reply_kind text, reply_body text, reply_name text, reply_mine boolean)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null or not public.is_chat_member(conv) then
        return;
    end if;
    return query
    select m.id, public.person_id(m.sender_id), public.name_of(m.sender_id), public.avatar_of(m.sender_id),
           m.sender_id = me, m.kind, m.body, m.data, m.created_at, m.reply_to,
           case when r.id is null then null when r.hidden then 'gone' else r.kind end,
           case when r.id is null or r.hidden then null else left(coalesce(r.body, r.data ->> 'question', ''), 140) end,
           case when r.id is null then null else public.name_of(r.sender_id) end,
           case when r.id is null then null else r.sender_id = me end
      from (
            select * from public.chat_messages x
             where x.conversation_id = conv and not x.hidden
               and (newer_than is null or x.created_at > newer_than)
               and (older_than is null or x.created_at < older_than)
               and not exists (select 1 from public.blocks b where b.blocker_id = me and b.blocked_id = x.sender_id)
               and not exists (select 1 from public.chat_reports rp where rp.message_id = x.id and rp.reporter_id = me)
             order by x.created_at desc
             limit least(greatest(coalesce(lim, 60), 1), 200)
           ) m
      left join public.chat_messages r on r.id = m.reply_to
     order by m.created_at;
end;
$$;

-- Estados: votos, jogos, reações, mensagens que desapareceram (gone) e, numa linha sem message_id, quem já leu até
-- onde (reads), se a outra pessoa ainda não aceitou (pending) e o meu estado (my_status).
drop function if exists public.chat_states(uuid);
create function public.chat_states(conv uuid)
    returns table (message_id uuid, votes jsonb, my_vote smallint, scores jsonb, my_answers jsonb, gone boolean,
                   reactions jsonb, my_reaction text, reactors jsonb, reads jsonb, pending boolean, my_status text)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    k text;
    st text;
    other uuid;
    receipts boolean;
begin
    if me is null or not public.is_chat_member(conv) then
        return;
    end if;
    select c.kind into k from public.conversations c where c.id = conv;
    select cm.status into st from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = me;
    receipts := coalesce((select p.read_receipts from public.people p where p.user_id = me), true);
    if k = 'direct' then
        other := public.direct_other(conv, me);
    end if;
    return query
    (select m.id,
           case when m.kind = 'poll' and not m.hidden then
               (select coalesce(jsonb_object_agg(v.option::text, v.n), '{}'::jsonb)
                  from (select cv.option, count(*) as n from public.chat_votes cv where cv.message_id = m.id group by cv.option) v) end,
           case when m.kind = 'poll' and not m.hidden then (select cv.option from public.chat_votes cv where cv.message_id = m.id and cv.user_id = me) end,
           case when m.kind = 'game' and not m.hidden then
               (select coalesce(jsonb_agg(jsonb_build_object('name', public.name_of(a.user_id), 'me', a.user_id = me, 'right', a.r, 'done', a.n)
                                          order by a.r desc, a.n desc), '[]'::jsonb)
                  from (select ga.user_id, count(*) filter (where ga.correct) as r, count(*) as n
                          from public.chat_game_answers ga where ga.message_id = m.id group by ga.user_id) a) end,
           case when m.kind = 'game' and not m.hidden then
               (select coalesce(jsonb_agg(jsonb_build_object('q', ga.question, 'a', ga.answer, 'ok', ga.correct) order by ga.question), '[]'::jsonb)
                  from public.chat_game_answers ga where ga.message_id = m.id and ga.user_id = me) end,
           m.hidden,
           case when not m.hidden then
               (select jsonb_object_agg(rr.reaction, rr.n) from (select cr.reaction, count(*) as n from public.chat_reactions cr
                                                                   where cr.message_id = m.id group by cr.reaction) rr) end,
           (select cr.reaction from public.chat_reactions cr where cr.message_id = m.id and cr.user_id = me),
           case when not m.hidden then
               (select jsonb_agg(jsonb_build_object('name', public.name_of(cr.user_id), 'r', cr.reaction, 'me', cr.user_id = me) order by cr.created_at)
                  from public.chat_reactions cr where cr.message_id = m.id) end,
           null::jsonb, null::boolean, null::text
      from public.chat_messages m
     where m.conversation_id = conv
       and ((m.kind in ('poll', 'game') and not m.hidden)
            or (m.hidden and m.created_at > now() - interval '30 days')
            or (not m.hidden and exists (select 1 from public.chat_reactions cr where cr.message_id = m.id)))
     order by m.created_at desc
     limit 300)
    union all
    select null::uuid, null::jsonb, null::smallint, null::jsonb, null::jsonb, false, null::jsonb, null::text, null::jsonb,
           case when receipts and st = 'active' then
               (select coalesce(jsonb_agg(jsonb_build_object('person', public.person_id(cm.user_id), 'name', public.name_of(cm.user_id), 'at', cm.last_read_at)), '[]'::jsonb)
                  from public.conversation_members cm
                  left join public.people pp on pp.user_id = cm.user_id
                 where cm.conversation_id = conv and cm.user_id <> me and cm.status = 'active' and coalesce(pp.read_receipts, true))
           else '[]'::jsonb end,
           case when k = 'direct' then
               coalesce((select cm.status <> 'active' from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = other), true)
           else false end,
           st;
end;
$$;

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
           exists (select 1 from public.conversation_members x where x.conversation_id = conv and x.user_id = me and x.role = 'admin' and x.status = 'active'),
           case when c.kind = 'direct' then
               (select jsonb_agg(jsonb_build_object('person', public.person_id(u.uid), 'name', public.name_of(u.uid), 'avatar', public.avatar_of(u.uid),
                                                    'username', public.username_of(u.uid), 'admin', true, 'me', u.uid = me))
                  from (values (split_part(c.direct_key, ':', 1)::uuid), (split_part(c.direct_key, ':', 2)::uuid)) as u(uid))
           else
               (select coalesce(jsonb_agg(jsonb_build_object('person', public.person_id(x.user_id), 'name', public.name_of(x.user_id),
                                                             'avatar', public.avatar_of(x.user_id), 'username', public.username_of(x.user_id),
                                                             'admin', x.role = 'admin', 'me', x.user_id = me, 'pending', x.status = 'request')
                                          order by x.joined_at), '[]'::jsonb)
                  from public.conversation_members x where x.conversation_id = conv)
           end
      from public.conversations c where c.id = conv;
end;
$$;

-- Votar e jogar só depois de aceitar.
create or replace function public.vote_poll(msg uuid, choice integer) returns void
    language plpgsql security definer set search_path = public as $$
declare
    m public.chat_messages;
begin
    select * into m from public.chat_messages where id = msg and kind = 'poll' and not hidden;
    if m.id is null or not public.is_active_member(m.conversation_id) then
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

create or replace function public.answer_game(msg uuid, q integer, choice integer) returns boolean
    language plpgsql security definer set search_path = public as $$
declare
    m public.chat_messages;
    right_answer integer;
    ok boolean;
begin
    select * into m from public.chat_messages where id = msg and kind = 'game' and not hidden;
    if m.id is null or not public.is_active_member(m.conversation_id) then
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

-- Reagir (tocar outra vez na mesma reação tira-a). Devolve a reação que ficou.
create or replace function public.react_message(msg uuid, reaction text default null) returns text
    language plpgsql security definer set search_path = public as $$
declare
    m public.chat_messages;
    cur text;
begin
    select * into m from public.chat_messages x where x.id = msg and not x.hidden and x.kind <> 'system';
    if m.id is null or not public.is_active_member(m.conversation_id) then
        raise exception 'not_allowed';
    end if;
    select cr.reaction into cur from public.chat_reactions cr where cr.message_id = msg and cr.user_id = auth.uid();
    if reaction is null or reaction = '' or cur = reaction then
        delete from public.chat_reactions cr where cr.message_id = msg and cr.user_id = auth.uid();
        return null;
    end if;
    if reaction not in ('heart', 'up', 'haha', 'check', 'star') then
        raise exception 'bad_reaction';
    end if;
    insert into public.chat_reactions as cr (message_id, user_id, reaction) values (msg, auth.uid(), reaction)
        on conflict (message_id, user_id) do update set reaction = excluded.reaction, created_at = now();
    return reaction;
end;
$$;

-- Procurar dentro de uma conversa (texto, legendas e perguntas das votações), sem distinguir acentos.
create or replace function public.search_conversation(conv uuid, q text)
    returns table (id uuid, created_at timestamptz, kind text, snippet text, sender_name text, mine boolean)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    needle text := translate(lower(trim(coalesce(q, ''))), 'áàâãäåéèêëíìîïóòôõöúùûüçñ', 'aaaaaaeeeeiiiiooooouuuucn');
begin
    if me is null or not public.is_chat_member(conv) or char_length(needle) < 2 then
        return;
    end if;
    needle := replace(replace(replace(left(needle, 80), '\', '\\'), '%', '\%'), '_', '\_');
    return query
    select m.id, m.created_at, m.kind, left(coalesce(m.body, m.data ->> 'question', ''), 200), public.name_of(m.sender_id), m.sender_id = me
      from public.chat_messages m
     where m.conversation_id = conv and not m.hidden and m.kind in ('text', 'photo', 'video', 'poll')
       and translate(lower(coalesce(m.body, '') || ' ' || coalesce(m.data ->> 'question', '')), 'áàâãäåéèêëíìîïóòôõöúùûüçñ', 'aaaaaaeeeeiiiiooooouuuucn')
           like '%' || needle || '%'
       and not exists (select 1 from public.blocks b where b.blocker_id = me and b.blocked_id = m.sender_id)
     order by m.created_at desc
     limit 50;
end;
$$;

-- Contadores para os pontos e números: mensagens por ler (conversas aceites) e pedidos à espera.
create or replace function public.chat_badges() returns table (unread integer, requests integer)
    language sql stable security definer set search_path = public as $$
    select (select count(*)::integer
              from public.conversation_members cm
              join public.chat_messages m on m.conversation_id = cm.conversation_id
             where cm.user_id = auth.uid() and cm.status = 'active' and m.created_at > cm.last_read_at
               and m.sender_id is distinct from auth.uid() and m.kind <> 'system' and not m.hidden
               and not exists (select 1 from public.blocks b where b.blocker_id = auth.uid() and b.blocked_id = m.sender_id)),
           (select count(*)::integer
              from public.conversation_members cm
             where cm.user_id = auth.uid() and cm.status = 'request'
               and exists (select 1 from public.chat_messages m where m.conversation_id = cm.conversation_id
                              and m.sender_id is distinct from auth.uid() and not m.hidden));
$$;

create or replace function public.chat_unread_total() returns integer
    language sql stable security definer set search_path = public as $$
    select unread from public.chat_badges();
$$;

-- ---------------------------------------------------------------- Tempo real: "a escrever", "Visto" e avisos

-- Canal privado "conv:<id>": só quem aceitou a conversa ouve e envia o sinal "a escrever".
create or replace function public.chat_topic_ok(topic text) returns boolean
    language plpgsql stable security definer set search_path = public as $$
declare
    conv uuid;
begin
    if topic is null or topic not like 'conv:%' then
        return false;
    end if;
    begin
        conv := substr(topic, 6)::uuid;
    exception when others then
        return false;
    end;
    return exists (select 1 from public.conversation_members cm
                    where cm.conversation_id = conv and cm.user_id = auth.uid() and cm.status = 'active');
end;
$$;

drop policy if exists "Conversas: ouvir quem está a escrever" on realtime.messages;
create policy "Conversas: ouvir quem está a escrever" on realtime.messages for select to authenticated
    using (realtime.messages.extension = 'broadcast' and public.chat_topic_ok((select realtime.topic())));
drop policy if exists "Conversas: avisar que está a escrever" on realtime.messages;
create policy "Conversas: avisar que está a escrever" on realtime.messages for insert to authenticated
    with check (realtime.messages.extension = 'broadcast' and public.chat_topic_ok((select realtime.topic())));

-- Mudanças nas conversas: sinal para cada pessoa; avisos no telemóvel só para quem aceitou a conversa.
create or replace function public.chat_notify() returns trigger
    language plpgsql security definer set search_path = public as $$
declare
    conv uuid;
    what text;
    u uuid;
    queued integer := 0;
    is_message boolean := tg_table_name = 'chat_messages';
    new_message boolean := false;
begin
    -- (Cada campo só é lido na tabela que o tem: o plpgsql não para a meio de um "and".)
    if is_message then
        conv := new.conversation_id;
        what := case when tg_op = 'INSERT' then 'new' else 'gone' end;
        if tg_op = 'INSERT' then
            new_message := new.kind <> 'system';
        end if;
    elsif tg_op = 'DELETE' then
        select m.conversation_id into conv from public.chat_messages m where m.id = old.message_id;
        what := 'state';
    else
        select m.conversation_id into conv from public.chat_messages m where m.id = new.message_id;
        what := 'state';
    end if;
    if conv is null then
        return null;
    end if;
    for u in select cm.user_id from public.conversation_members cm where cm.conversation_id = conv loop
        begin
            perform realtime.send(jsonb_build_object('c', conv, 'k', what), 'chat', 'inbox:' || u::text, true);
        exception when others then
            null;
        end;
    end loop;
    if new_message then
        with picked as (
            update public.push_subscriptions s set last_push_at = now()
              from public.conversation_members cm
             where cm.conversation_id = conv and cm.user_id = s.user_id and cm.status = 'active'
               and s.user_id is distinct from new.sender_id
               and cm.last_read_at < now() - interval '30 seconds'
               and (s.last_push_at is null or s.last_push_at < now() - interval '2 minutes')
               and not exists (select 1 from public.blocks b where b.blocker_id = s.user_id and b.blocked_id = new.sender_id)
            returning s.endpoint, s.lang
        )
        insert into public.push_queue (endpoint, lang) select p.endpoint, p.lang from picked p;
        get diagnostics queued = row_count;
        if queued > 0 then
            begin
                perform net.http_post(url := 'https://dbwymcfmputeaggeeqfo.supabase.co/functions/v1/chat-push', body := '{}'::jsonb);
            exception when others then
                null;
            end;
        end if;
    end if;
    return null;
end;
$$;

-- Alguém leu ou aceitou: sinal "read" para as outras pessoas (para o "Visto" e para desbloquear quem esperava).
create or replace function public.chat_member_notify() returns trigger
    language plpgsql security definer set search_path = public as $$
declare
    u uuid;
begin
    if new.status = 'active' and old.status = 'active'
       and not coalesce((select p.read_receipts from public.people p where p.user_id = new.user_id), true) then
        return null;
    end if;
    for u in select cm.user_id from public.conversation_members cm
              where cm.conversation_id = new.conversation_id and cm.user_id <> new.user_id and cm.status = 'active' loop
        begin
            perform realtime.send(jsonb_build_object('c', new.conversation_id, 'k', 'read'), 'chat', 'inbox:' || u::text, true);
        exception when others then
            null;
        end;
    end loop;
    return null;
end;
$$;

drop trigger if exists conversation_members_notify on public.conversation_members;
create trigger conversation_members_notify after update of last_read_at, status on public.conversation_members
    for each row when (new.status = 'active' and (new.last_read_at is distinct from old.last_read_at or new.status is distinct from old.status))
    execute function public.chat_member_notify();
drop trigger if exists chat_reactions_notify on public.chat_reactions;
create trigger chat_reactions_notify after insert or update or delete on public.chat_reactions
    for each row execute function public.chat_notify();

revoke execute on function public.chat_notify() from public, anon, authenticated;
revoke execute on function public.chat_member_notify() from public, anon, authenticated;

-- ---------------------------------------------------------------- Permissões

do $$
declare
    f text;
begin
    foreach f in array array[
        'my_chat_profile()', 'set_username(text)', 'suggest_username()', 'set_chat_privacy(boolean, text, boolean)', 'find_person(text)',
        'my_people(text)', 'open_direct(uuid)', 'create_group(text, uuid[])', 'add_to_group(uuid, uuid[])', 'leave_conversation(uuid)',
        'accept_request(uuid)', 'rename_group(uuid, text)', 'send_message(uuid, text, text, jsonb, uuid)', 'my_conversations()',
        'conversation_messages(uuid, timestamptz, timestamptz, integer)', 'chat_states(uuid)', 'conversation_info(uuid)',
        'vote_poll(uuid, integer)', 'answer_game(uuid, integer, integer)', 'react_message(uuid, text)',
        'search_conversation(uuid, text)', 'chat_badges()', 'chat_unread_total()', 'chat_topic_ok(text)'
    ] loop
        execute format('revoke execute on function public.%s from public, anon', f);
        execute format('grant execute on function public.%s to authenticated', f);
    end loop;
end;
$$;
revoke execute on function public.person_profile(uuid) from public;
grant execute on function public.person_profile(uuid) to anon, authenticated;

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
        perform * from public.my_chat_profile();
        perform public.suggest_username();
        perform * from public.find_person('ninguem.aqui');
        perform * from public.my_people('following');
        perform * from public.my_conversations();
        perform * from public.chat_badges();
        raise exception using errcode = 'TT001', message = 'teste ok';
    exception when sqlstate 'TT001' then
        null;
    end;
    reset role;
end;
$$;

commit;
