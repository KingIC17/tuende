-- 31 de outubro de 2026 (4.ª parte): mensagens fixadas, pessoas em comum nos pedidos e chamadas de voz e vídeo.
--
--   * Fixar: cada conversa tem no máximo uma mensagem fixada (conversations.pinned_message), mostrada no topo.
--     Qualquer pessoa que aceitou a conversa pode fixar ou tirar; fixar deixa uma linha "X fixou uma mensagem".
--   * Pessoas em comum (person_mutuals): quantas das pessoas que eu sigo seguem esta pessoa, com até 3 nomes,
--     para ajudar a decidir se aceito um pedido.
--   * Chamadas (só a dois, entre quem aceitou a conversa): ring_call avisa a outra pessoa pelo seu canal privado
--     (inbox:<id>); a ligação de áudio e vídeo vai diretamente entre os dois aparelhos (WebRTC), combinada pelo canal
--     privado da conversa (conv:<id>). Nada do som ou da imagem passa pela base de dados nem fica guardado; fica só uma
--     mensagem "call" com o tipo e a duração. Funciona com a app aberta.
-- Pode correr-se mais de uma vez.

begin;

alter table public.conversations add column if not exists pinned_message uuid references public.chat_messages (id) on delete set null;
alter table public.conversations add column if not exists pinned_by uuid references auth.users (id) on delete set null;
create index if not exists conversations_pinned_idx on public.conversations (pinned_message) where pinned_message is not null;
create index if not exists conversations_pinned_by_idx on public.conversations (pinned_by) where pinned_by is not null;

alter table public.chat_messages drop constraint if exists chat_messages_kind_check;
alter table public.chat_messages add constraint chat_messages_kind_check
    check (kind in ('text', 'photo', 'video', 'audio', 'location', 'place', 'event', 'moment', 'poll', 'game', 'call', 'system'));

-- ---------------------------------------------------------------- Mensagem fixada

create or replace function public.pin_message(msg uuid) returns void
    language plpgsql security definer set search_path = public as $$
declare
    m public.chat_messages;
begin
    select * into m from public.chat_messages x where x.id = msg and not x.hidden and x.kind <> 'system';
    if m.id is null or not public.is_active_member(m.conversation_id) then
        raise exception 'not_allowed';
    end if;
    update public.conversations c set pinned_message = msg, pinned_by = auth.uid() where c.id = m.conversation_id;
    perform public.chat_system(m.conversation_id, jsonb_build_object('event', 'pinned'));
end;
$$;

create or replace function public.unpin_message(conv uuid) returns void
    language plpgsql security definer set search_path = public as $$
begin
    if not public.is_active_member(conv) then
        raise exception 'not_allowed';
    end if;
    update public.conversations c set pinned_message = null, pinned_by = null where c.id = conv;
end;
$$;

drop function if exists public.conversation_info(uuid);
create function public.conversation_info(conv uuid)
    returns table (kind text, title text, i_admin boolean, members jsonb, pinned jsonb)
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
           end,
           (select jsonb_build_object('id', pm.id, 'kind', pm.kind, 'body', left(coalesce(pm.body, pm.data ->> 'question', ''), 140),
                                      'name', public.name_of(pm.sender_id), 'mine', pm.sender_id = me)
              from public.chat_messages pm where pm.id = c.pinned_message and not pm.hidden)
      from public.conversations c where c.id = conv;
end;
$$;

-- Fixar ou tirar: sinal "info" para cada pessoa da conversa (a app volta a ler o topo da conversa).
create or replace function public.chat_conv_notify() returns trigger
    language plpgsql security definer set search_path = public as $$
declare
    u uuid;
begin
    for u in select cm.user_id from public.conversation_members cm where cm.conversation_id = new.id loop
        begin
            perform realtime.send(jsonb_build_object('c', new.id, 'k', 'info'), 'chat', 'inbox:' || u::text, true);
        exception when others then
            null;
        end;
    end loop;
    return null;
end;
$$;
revoke execute on function public.chat_conv_notify() from public, anon, authenticated;
drop trigger if exists conversations_notify on public.conversations;
create trigger conversations_notify after update of pinned_message on public.conversations
    for each row when (new.pinned_message is distinct from old.pinned_message) execute function public.chat_conv_notify();

-- ---------------------------------------------------------------- Pessoas em comum

create or replace function public.person_mutuals(p uuid) returns table (total integer, names jsonb)
    language plpgsql security definer set search_path = public as $$
declare
    u uuid := public.person_user(p);
    me uuid := auth.uid();
begin
    if me is null or u is null or u = me then
        return;
    end if;
    return query
    select count(*)::integer, coalesce(jsonb_agg(x.n order by x.rn) filter (where x.rn <= 3), '[]'::jsonb)
      from (select public.name_of(f.follower_id) as n, row_number() over (order by f.created_at desc) as rn
              from public.follows f
              join public.follows mine on mine.follower_id = me and mine.followed_id = f.follower_id
             where f.followed_id = u and f.follower_id <> me and not public.is_blocked_between(me, f.follower_id)) x;
end;
$$;

-- ---------------------------------------------------------------- Chamadas

-- A outra pessoa de uma conversa a dois, se as duas aceitaram a conversa e não há bloqueio (senão: nulo).
create or replace function public.call_peer(conv uuid) returns uuid
    language plpgsql stable security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    other uuid;
begin
    if me is null or not exists (select 1 from public.conversations c where c.id = conv and c.kind = 'direct') then
        return null;
    end if;
    other := public.direct_other(conv, me);
    if other is null or public.is_blocked_between(me, other)
       or not exists (select 1 from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = me and cm.status = 'active')
       or not exists (select 1 from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = other and cm.status = 'active') then
        return null;
    end if;
    return other;
end;
$$;
revoke execute on function public.call_peer(uuid) from public, anon, authenticated;

-- Tocar: avisa a outra pessoa (canal inbox:<id>) com o nome, a foto e se é vídeo. Devolve o id da chamada.
create or replace function public.ring_call(conv uuid, video boolean default false) returns uuid
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    other uuid := public.call_peer(conv);
    call_id uuid := gen_random_uuid();
begin
    if other is null then
        raise exception 'not_allowed';
    end if;
    perform realtime.send(jsonb_build_object('c', conv, 'k', 'call', 'what', 'ring', 'id', call_id, 'video', coalesce(video, false),
                                             'from', public.name_of(me), 'av', public.avatar_of(me), 'p', public.person_id(me)),
                          'chat', 'inbox:' || other::text, true);
    return call_id;
end;
$$;

-- Cancelar (quem liga desistiu), recusar ou "ocupado".
create or replace function public.call_signal(conv uuid, call uuid, what text) returns void
    language plpgsql security definer set search_path = public as $$
declare
    other uuid := public.call_peer(conv);
begin
    if other is null or what not in ('cancel', 'decline', 'busy') then
        raise exception 'not_allowed';
    end if;
    perform realtime.send(jsonb_build_object('c', conv, 'k', 'call', 'what', what, 'id', call), 'chat', 'inbox:' || other::text, true);
end;
$$;

-- ---------------------------------------------------------------- Mensagens: tipo "call" (registo da chamada)

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
    elsif kind = 'call' then
        -- Registo de uma chamada (só em conversas a dois): de voz ou vídeo e quanto durou (0 = não atendida).
        if c.kind <> 'direct' then
            raise exception 'bad_kind';
        end if;
        d := jsonb_build_object('video', coalesce((d ->> 'video')::boolean, false),
                                'dur', least(greatest(coalesce((d ->> 'dur')::numeric, 0), 0), 86400)::integer);
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

do $$
declare
    f text;
begin
    foreach f in array array[
        'pin_message(uuid)', 'unpin_message(uuid)', 'conversation_info(uuid)', 'person_mutuals(uuid)',
        'ring_call(uuid, boolean)', 'call_signal(uuid, uuid, text)', 'send_message(uuid, text, text, jsonb, uuid)'
    ] loop
        execute format('revoke execute on function public.%s from public, anon', f);
        execute format('grant execute on function public.%s to authenticated', f);
    end loop;
end;
$$;

commit;
