-- 31 de outubro de 2026 (2.ª parte): Conversas em tempo real, avisos no telemóvel, mensagens de voz e apagar mensagens.
--
-- Regras:
--   * Tempo real: quando uma conversa muda (mensagem nova, apagada ou escondida, voto, resposta a um jogo), a base de dados
--     envia um sinal (Supabase Realtime, canal privado "inbox:<id da conta>") a cada pessoa da conversa. O sinal só diz
--     qual conversa mudou; a app vai buscar o resto pelas funções de sempre. Cada pessoa só pode ouvir o seu canal.
--   * Avisos (Web Push): quem os liga guarda o endereço de envio do navegador (Google, Apple, Mozilla ou Microsoft).
--     Uma mensagem nova põe um aviso na fila para quem não está a ler essa conversa (no máximo 1 aviso a cada 2 minutos
--     por aparelho); a função chat-push envia-o. O aviso não leva o texto da mensagem.
--     A chave privada VAPID fica na tabela push_settings (não está neste ficheiro nem no repositório).
--   * Mensagens de voz: tipo "audio", ficheiro no balde privado "chat" (até 2 minutos na app, 5 no máximo aqui).
--   * Apagar: só quem enviou; a mensagem desaparece para todos (o texto é apagado; o caminho do ficheiro fica guardado
--     até a app o apagar, para que apagar a conta também o remova).
-- Pode correr-se mais de uma vez.

begin;

-- ---------------------------------------------------------------- Mensagens de voz e apagar mensagens

alter table public.chat_messages drop constraint if exists chat_messages_kind_check;
alter table public.chat_messages add constraint chat_messages_kind_check
    check (kind in ('text', 'photo', 'video', 'audio', 'location', 'place', 'event', 'moment', 'poll', 'game', 'system'));

update storage.buckets
   set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/quicktime', 'video/webm',
                                  'audio/mp4', 'audio/webm', 'audio/ogg', 'audio/mpeg', 'audio/aac']
 where id = 'chat';

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

    insert into public.chat_messages (conversation_id, sender_id, kind, body, data)
        values (conv, me, kind, txt, d) returning chat_messages.id, chat_messages.created_at into new_id, new_at;
    update public.conversations set last_message_at = new_at where conversations.id = conv;
    update public.conversation_members set last_read_at = new_at where conversation_id = conv and user_id = me;
    return query select new_id, new_at;
end;
$$;

-- Fotos, vídeos e mensagens de voz que a pessoa enviou (também as apagadas), para a app os apagar antes de apagar a conta.
create or replace function public.my_chat_files() returns setof text
    language sql stable security definer set search_path = public as $$
    select m.data ->> 'path'
      from public.chat_messages m
     where m.sender_id = auth.uid() and m.kind in ('photo', 'video', 'audio') and m.data ? 'path';
$$;

-- Apagar uma mensagem própria para todos. Devolve o caminho do ficheiro (foto, vídeo ou voz) para a app o apagar.
create or replace function public.delete_message(msg uuid) returns text
    language plpgsql security definer set search_path = public as $$
declare
    m public.chat_messages;
    path text;
begin
    select * into m from public.chat_messages where id = msg;
    if m.id is null or m.sender_id is distinct from auth.uid() or m.kind = 'system' then
        raise exception 'not_allowed';
    end if;
    path := case when m.kind in ('photo', 'video', 'audio') then m.data ->> 'path' end;
    delete from public.chat_votes where message_id = msg;
    delete from public.chat_game_answers where message_id = msg;
    update public.chat_messages
       set hidden = true, body = null,
           data = case when path is null then '{}'::jsonb else jsonb_build_object('path', path) end
     where id = msg;
    return path;
end;
$$;

-- Votos e respostas dos jogos e, com gone = true, as mensagens que deixaram de existir (apagadas ou escondidas por
-- denúncias), para a app as tirar do ecrã.
drop function if exists public.chat_states(uuid);
create function public.chat_states(conv uuid)
    returns table (message_id uuid, votes jsonb, my_vote smallint, scores jsonb, my_answers jsonb, gone boolean)
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    if me is null or not public.is_chat_member(conv) then
        return;
    end if;
    return query
    (select m.id,
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
                  from public.chat_game_answers ga where ga.message_id = m.id and ga.user_id = me) end,
           false
      from public.chat_messages m
     where m.conversation_id = conv and m.kind in ('poll', 'game') and not m.hidden
     order by m.created_at desc
     limit 100)
    union all
    (select m.id, null::jsonb, null::smallint, null::jsonb, null::jsonb, true
       from public.chat_messages m
      where m.conversation_id = conv and m.hidden and m.created_at > now() - interval '30 days'
      order by m.created_at desc
      limit 200);
end;
$$;

revoke execute on function public.chat_states(uuid) from public, anon;
grant execute on function public.chat_states(uuid) to authenticated;
revoke execute on function public.delete_message(uuid) from public, anon;
grant execute on function public.delete_message(uuid) to authenticated;

-- ---------------------------------------------------------------- Avisos no telemóvel (Web Push)

create extension if not exists pg_net with schema extensions;

create table if not exists public.push_subscriptions (
    endpoint text primary key check (char_length(endpoint) <= 1000),
    user_id uuid not null references auth.users (id) on delete cascade,
    lang text not null default 'pt' check (lang in ('pt', 'en', 'fr', 'es')),
    created_at timestamptz not null default now(),
    last_push_at timestamptz
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);

create table if not exists public.push_queue (
    id bigint generated always as identity primary key,
    endpoint text not null,
    lang text not null default 'pt',
    created_at timestamptz not null default now()
);

create table if not exists public.push_settings (
    id integer primary key default 1 check (id = 1),
    vapid_public text not null,
    vapid_private text not null
);

alter table public.push_subscriptions enable row level security;
alter table public.push_queue enable row level security;
alter table public.push_settings enable row level security;
revoke all on public.push_subscriptions, public.push_queue, public.push_settings from anon, authenticated;

-- Só serviços de avisos conhecidos (assim ninguém usa a função de envio para chamar outros sites).
create or replace function public.push_endpoint_ok(e text) returns boolean
    language sql immutable set search_path = public as $$
    select coalesce(char_length(e) <= 1000 and e ~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/', false);
$$;

-- Ligar os avisos neste aparelho (até 10 aparelhos por conta).
create or replace function public.save_push(sub_endpoint text, sub_lang text default 'pt') returns void
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    l text := case when sub_lang in ('pt', 'en', 'fr', 'es') then sub_lang else 'pt' end;
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    if not public.push_endpoint_ok(sub_endpoint) then
        raise exception 'bad_endpoint';
    end if;
    insert into public.push_subscriptions as s (endpoint, user_id, lang) values (sub_endpoint, me, l)
        on conflict (endpoint) do update set user_id = me, lang = l;
    delete from public.push_subscriptions s
     where s.user_id = me
       and s.endpoint not in (select x.endpoint from public.push_subscriptions x where x.user_id = me order by x.created_at desc limit 10);
end;
$$;

create or replace function public.delete_push(sub_endpoint text) returns void
    language sql security definer set search_path = public as $$
    delete from public.push_subscriptions where endpoint = sub_endpoint and user_id = auth.uid();
$$;

-- Para a função chat-push (só com a chave de serviço): tira os avisos da fila.
create or replace function public.take_push_jobs()
    returns table (endpoint text, lang text, vapid_public text, vapid_private text)
    language sql security definer set search_path = public as $$
    with taken as (
        delete from public.push_queue q
         where q.id in (select q2.id from public.push_queue q2 order by q2.id limit 500)
        returning q.endpoint, q.lang, q.created_at
    )
    select distinct on (t.endpoint) t.endpoint, t.lang, s.vapid_public, s.vapid_private
      from taken t cross join public.push_settings s
     where t.created_at > now() - interval '1 hour' and public.push_endpoint_ok(t.endpoint);
$$;

-- Para a função chat-push: o serviço de avisos disse que o endereço já não existe.
create or replace function public.drop_push(sub_endpoint text) returns void
    language sql security definer set search_path = public as $$
    delete from public.push_subscriptions where endpoint = sub_endpoint;
$$;

revoke execute on function public.push_endpoint_ok(text) from public, anon, authenticated;
revoke execute on function public.save_push(text, text) from public, anon;
grant execute on function public.save_push(text, text) to authenticated;
revoke execute on function public.delete_push(text) from public, anon;
grant execute on function public.delete_push(text) to authenticated;
revoke execute on function public.take_push_jobs() from public, anon, authenticated;
grant execute on function public.take_push_jobs() to service_role;
revoke execute on function public.drop_push(text) from public, anon, authenticated;
grant execute on function public.drop_push(text) to service_role;

-- ---------------------------------------------------------------- Tempo real

-- Cada pessoa só ouve o seu próprio canal "inbox:<id da conta>".
drop policy if exists "Conversas: avisos em tempo real" on realtime.messages;
create policy "Conversas: avisos em tempo real" on realtime.messages for select to authenticated
    using (realtime.messages.extension = 'broadcast' and (select realtime.topic()) = 'inbox:' || (select auth.uid())::text);

-- Quando uma conversa muda: sinal em tempo real para cada pessoa da conversa e, numa mensagem nova, aviso no
-- telemóvel para quem não a está a ler.
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
revoke execute on function public.chat_notify() from public, anon, authenticated;

drop trigger if exists chat_messages_notify on public.chat_messages;
create trigger chat_messages_notify after insert on public.chat_messages
    for each row execute function public.chat_notify();
drop trigger if exists chat_messages_gone_notify on public.chat_messages;
create trigger chat_messages_gone_notify after update of hidden on public.chat_messages
    for each row when (new.hidden and not old.hidden) execute function public.chat_notify();
drop trigger if exists chat_votes_notify on public.chat_votes;
create trigger chat_votes_notify after insert or update or delete on public.chat_votes
    for each row execute function public.chat_notify();
drop trigger if exists chat_game_answers_notify on public.chat_game_answers;
create trigger chat_game_answers_notify after insert on public.chat_game_answers
    for each row execute function public.chat_notify();

commit;
