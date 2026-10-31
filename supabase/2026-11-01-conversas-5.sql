-- Conversas, parte 5 (1 de novembro de 2026): chamadas de grupo, tocar com a app fechada e servidor de retransmissão.
--
-- 1. public.chat_calls: uma linha por chamada (quem ligou, voz ou vídeo, quando foi atendida e quando acabou) e quem
--    está nela agora (present: conta -> último sinal de vida, a cada 30 s). Até 4 pessoas por chamada.
-- 2. ring_call toca a todas as pessoas ativas da conversa (a dois ou em grupo): pelo canal privado inbox:<id> e por
--    um aviso cifrado (Web Push) para quem tem a app fechada. join_call, call_alive e leave_call guardam quem está.
--    Quando sai a última pessoa, a própria base de dados escreve o registo da chamada na conversa (tipo, duração,
--    quantas pessoas) e avisa os outros aparelhos ("ended"), que fecham o aviso de chamada.
-- 3. Avisos: push_subscriptions guarda as chaves públicas do aparelho (p256dh, auth) para cifrar o aviso de chamada;
--    push_queue ganha o tipo (msg, call, call-end) e o conteúdo. As mensagens continuam a ir SEM conteúdo.
-- 4. chat_notify: o registo de uma chamada já não manda o aviso genérico "mensagens novas" (o aviso da chamada chega).
-- A função chat-push cifra os avisos de chamada (RFC 8291); a função turn-credentials dá o servidor de retransmissão.
--
-- Executar depois de 2026-10-31-conversas-4.sql. Pode correr-se de novo.

begin;

-- ---------------------------------------------------------------- 1. Chamadas

create table if not exists public.chat_calls (
    id uuid primary key default gen_random_uuid(),
    conversation_id uuid not null references public.conversations (id) on delete cascade,
    started_by uuid references auth.users (id) on delete set null,
    video boolean not null default false,
    started_at timestamptz not null default now(),
    answered_at timestamptz,
    ended_at timestamptz,
    peak integer not null default 1,
    present jsonb not null default '{}'::jsonb,
    joined uuid[] not null default '{}'
);
create index if not exists chat_calls_conversation_idx on public.chat_calls (conversation_id, started_at desc);
create index if not exists chat_calls_started_by_idx on public.chat_calls (started_by);
alter table public.chat_calls enable row level security;
revoke all on public.chat_calls from anon, authenticated;

-- ---------------------------------------------------------------- 2. Avisos com conteúdo cifrado (só chamadas)

alter table public.push_subscriptions add column if not exists p256dh text;
alter table public.push_subscriptions add column if not exists auth text;
alter table public.push_subscriptions drop constraint if exists push_subscriptions_keys_check;
alter table public.push_subscriptions add constraint push_subscriptions_keys_check
    check ((p256dh is null or p256dh ~ '^[A-Za-z0-9_-]{80,100}$') and (auth is null or auth ~ '^[A-Za-z0-9_-]{16,32}$'));
alter table public.push_queue add column if not exists kind text not null default 'msg';
alter table public.push_queue add column if not exists payload jsonb;
alter table public.push_queue drop constraint if exists push_queue_kind_check;
alter table public.push_queue add constraint push_queue_kind_check check (kind in ('msg', 'call', 'call-end'));

-- Ligar os avisos neste aparelho, agora com as chaves do aparelho (até 10 aparelhos por conta).
drop function if exists public.save_push(text, text);
create or replace function public.save_push(sub_endpoint text, sub_lang text default 'pt', sub_p256dh text default null, sub_auth text default null)
    returns void
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    l text := case when sub_lang in ('pt', 'en', 'fr', 'es') then sub_lang else 'pt' end;
    k1 text := case when sub_p256dh ~ '^[A-Za-z0-9_-]{80,100}$' then sub_p256dh end;
    k2 text := case when sub_auth ~ '^[A-Za-z0-9_-]{16,32}$' then sub_auth end;
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    if not public.push_endpoint_ok(sub_endpoint) then
        raise exception 'bad_endpoint';
    end if;
    insert into public.push_subscriptions as s (endpoint, user_id, lang, p256dh, auth) values (sub_endpoint, me, l, k1, k2)
        on conflict (endpoint) do update set user_id = me, lang = l,
            p256dh = coalesce(excluded.p256dh, s.p256dh), auth = coalesce(excluded.auth, s.auth);
    delete from public.push_subscriptions s
     where s.user_id = me
       and s.endpoint not in (select x.endpoint from public.push_subscriptions x where x.user_id = me order by x.created_at desc limit 10);
end;
$$;

-- Para a função chat-push (só com a chave de serviço): tira os avisos da fila. Os de chamada só valem 50 segundos.
drop function if exists public.take_push_jobs();
create function public.take_push_jobs()
    returns table (endpoint text, lang text, kind text, payload jsonb, p256dh text, auth text, vapid_public text, vapid_private text)
    language sql security definer set search_path = public as $$
    with taken as (
        delete from public.push_queue q
         where q.id in (select q2.id from public.push_queue q2 order by q2.id limit 500)
        returning q.endpoint, q.lang, q.kind, q.payload, q.created_at
    )
    select distinct on (t.endpoint, t.kind, coalesce(t.payload ->> 'id', ''))
           t.endpoint, t.lang, t.kind, t.payload, ps.p256dh, ps.auth, s.vapid_public, s.vapid_private
      from taken t
      cross join public.push_settings s
      left join public.push_subscriptions ps on ps.endpoint = t.endpoint
     where public.push_endpoint_ok(t.endpoint)
       and t.created_at > now() - case when t.kind = 'msg' then interval '1 hour' else interval '50 seconds' end;
$$;

-- ---------------------------------------------------------------- 3. Ajudas internas

-- As outras pessoas ativas de uma conversa a quem se pode ligar (eu também tenho de estar ativo; sem bloqueios).
create or replace function public.call_targets(conv uuid, me uuid) returns setof uuid
    language sql stable security definer set search_path = public as $$
    select cm.user_id from public.conversation_members cm
     where cm.conversation_id = conv and cm.user_id <> me and cm.status = 'active'
       and exists (select 1 from public.conversation_members x where x.conversation_id = conv and x.user_id = me and x.status = 'active')
       and not public.is_blocked_between(me, cm.user_id);
$$;

-- Quantas pessoas deram sinal de vida nos últimos 70 segundos.
create or replace function public.call_live(p jsonb) returns integer
    language sql stable set search_path = public as $$
    select count(*)::integer from jsonb_each_text(coalesce(p, '{}'::jsonb)) e
     where e.value ~ '^[0-9.]+$' and e.value::numeric > extract(epoch from now()) - 70;
$$;

-- Chamadas de uma conversa onde já ninguém dá sinal de vida (a app fechou a meio): dão-se por acabadas.
create or replace function public.close_stale_calls(conv uuid) returns void
    language sql security definer set search_path = public as $$
    update public.chat_calls k set ended_at = now()
     where k.conversation_id = conv and k.ended_at is null and public.call_live(k.present) = 0;
$$;

-- Avisa todas as pessoas ativas da conversa (canal inbox:<id>): "update" (entrou ou saiu alguém) ou "ended".
create or replace function public.call_tell(conv uuid, call_id uuid, what text, n integer) returns void
    language plpgsql security definer set search_path = public as $$
declare
    u uuid;
begin
    for u in select cm.user_id from public.conversation_members cm where cm.conversation_id = conv and cm.status = 'active' loop
        begin
            perform realtime.send(jsonb_build_object('c', conv, 'k', 'call', 'what', what, 'id', call_id, 'n', n), 'chat', 'inbox:' || u::text, true);
        exception when others then
            null;
        end;
    end loop;
end;
$$;

-- ---------------------------------------------------------------- 4. Tocar, entrar, continuar, sair

create or replace function public.ring_call(conv uuid, video boolean default false) returns uuid
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    c public.conversations;
    new_call uuid;
    who uuid;
    queued integer := 0;
    nm text;
    gname text;
    vid boolean := coalesce(video, false);
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    select * into c from public.conversations where conversations.id = conv;
    if c.id is null or not exists (select 1 from public.call_targets(conv, me)) then
        raise exception 'not_allowed';
    end if;
    perform public.close_stale_calls(conv);
    if exists (select 1 from public.chat_calls k where k.conversation_id = conv and k.ended_at is null) then
        raise exception 'call_active';
    end if;
    if exists (select 1 from public.chat_calls k where k.started_by = me and k.started_at > now() - interval '5 seconds') then
        raise exception 'too_fast';
    end if;
    insert into public.chat_calls (conversation_id, started_by, video, present, joined)
        values (conv, me, vid, jsonb_build_object(me::text, extract(epoch from now())), array[me])
        returning chat_calls.id into new_call;
    nm := public.name_of(me);
    gname := case when c.kind = 'group' then c.title end;
    for who in select * from public.call_targets(conv, me) loop
        begin
            perform realtime.send(jsonb_build_object('c', conv, 'k', 'call', 'what', 'ring', 'id', new_call, 'video', vid,
                                                     'from', nm, 'av', public.avatar_of(me), 'p', public.person_id(me), 'g', gname),
                                  'chat', 'inbox:' || who::text, true);
        exception when others then
            null;
        end;
    end loop;
    insert into public.push_queue (endpoint, lang, kind, payload)
        select s.endpoint, s.lang, 'call', jsonb_build_object('t', 'call', 'c', conv, 'id', new_call, 'v', vid, 'from', nm, 'g', gname)
          from public.push_subscriptions s
         where s.user_id in (select * from public.call_targets(conv, me));
    get diagnostics queued = row_count;
    if queued > 0 then
        begin
            perform net.http_post(url := 'https://dbwymcfmputeaggeeqfo.supabase.co/functions/v1/chat-push', body := '{}'::jsonb);
        exception when others then
            null;
        end;
    end if;
    return new_call;
end;
$$;

-- Entrar numa chamada (atender, ou juntar-se a uma chamada de grupo a decorrer). Devolve { conv, video, n } ou { ended }.
create or replace function public.join_call(call_id uuid) returns jsonb
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    k public.chat_calls;
    c public.conversations;
    others integer;
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    select * into k from public.chat_calls where chat_calls.id = call_id for update;
    if k.id is null then
        raise exception 'not_found';
    end if;
    select * into c from public.conversations where conversations.id = k.conversation_id;
    if not exists (select 1 from public.conversation_members cm where cm.conversation_id = k.conversation_id and cm.user_id = me and cm.status = 'active')
       or (c.kind = 'direct' and not exists (select 1 from public.call_targets(k.conversation_id, me))) then
        raise exception 'not_allowed';
    end if;
    others := public.call_live(k.present - me::text);
    if k.ended_at is not null or others = 0 then
        if k.ended_at is null then
            update public.chat_calls set ended_at = now() where chat_calls.id = k.id;
        end if;
        return jsonb_build_object('ended', true);
    end if;
    if not (k.present ? me::text) and others >= 4 then
        raise exception 'call_full';
    end if;
    update public.chat_calls
       set present = present || jsonb_build_object(me::text, extract(epoch from now())),
           joined = case when me = any (joined) then joined else joined || me end,
           answered_at = coalesce(answered_at, now()),
           peak = greatest(peak, others + 1)
     where chat_calls.id = k.id;
    if c.kind = 'group' then
        perform public.call_tell(k.conversation_id, k.id, 'update', others + 1);
    end if;
    return jsonb_build_object('conv', k.conversation_id, 'video', k.video, 'n', others + 1);
end;
$$;

-- Sinal de vida, a cada 30 segundos durante a chamada. Devolve falso se a chamada já acabou.
create or replace function public.call_alive(call_id uuid) returns boolean
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
begin
    update public.chat_calls set present = present || jsonb_build_object(me::text, extract(epoch from now()))
     where chat_calls.id = call_id and ended_at is null and present ? me::text;
    return found;
end;
$$;

-- Sair. Se era a última pessoa, a chamada acaba: registo na conversa, aviso "ended" e, se ninguém atendeu,
-- um aviso cifrado de chamada não atendida (substitui o aviso de chamada nos telemóveis). Devolve se a chamada acabou.
create or replace function public.leave_call(call_id uuid) returns boolean
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    k public.chat_calls;
    c public.conversations;
    rest jsonb;
    dur integer;
    sender uuid;
    new_at timestamptz;
    queued integer := 0;
begin
    if me is null then
        raise exception 'not_signed_in';
    end if;
    select * into k from public.chat_calls where chat_calls.id = call_id for update;
    if k.id is null then
        return true;
    end if;
    if k.ended_at is not null or not (k.present ? me::text) then
        return k.ended_at is not null;
    end if;
    rest := k.present - me::text;
    select * into c from public.conversations where conversations.id = k.conversation_id;
    if public.call_live(rest) > 0 then
        update public.chat_calls set present = rest where chat_calls.id = k.id;
        if c.kind = 'group' then
            perform public.call_tell(k.conversation_id, k.id, 'update', public.call_live(rest));
        end if;
        return false;
    end if;
    update public.chat_calls set present = rest, ended_at = now() where chat_calls.id = k.id;
    dur := case when k.answered_at is null then 0 else least(greatest(extract(epoch from now() - k.answered_at), 0), 86400)::integer end;
    sender := case when exists (select 1 from public.conversation_members cm where cm.conversation_id = k.conversation_id and cm.user_id = k.started_by)
                   then k.started_by else me end;
    -- Quem esteve na chamada já sabe que ela aconteceu: o registo não lhe conta como mensagem por ler.
    insert into public.chat_messages (conversation_id, sender_id, kind, data)
        values (k.conversation_id, sender, 'call', jsonb_build_object('video', k.video, 'dur', dur, 'n', k.peak))
        returning chat_messages.created_at into new_at;
    update public.conversations set last_message_at = new_at where conversations.id = k.conversation_id;
    update public.conversation_members cm set last_read_at = greatest(cm.last_read_at, new_at)
     where cm.conversation_id = k.conversation_id and cm.user_id = any (k.joined);
    perform public.call_tell(k.conversation_id, k.id, 'ended', 0);
    if k.answered_at is null then
        insert into public.push_queue (endpoint, lang, kind, payload)
            select s.endpoint, s.lang, 'call-end',
                   jsonb_build_object('t', 'call-end', 'c', k.conversation_id, 'id', k.id, 'v', k.video, 'from', public.name_of(k.started_by),
                                      'g', case when c.kind = 'group' then c.title end)
              from public.push_subscriptions s
              join public.conversation_members cm on cm.user_id = s.user_id and cm.conversation_id = k.conversation_id and cm.status = 'active'
             where s.user_id <> all (k.joined) and s.p256dh is not null and s.auth is not null;
        get diagnostics queued = row_count;
        if queued > 0 then
            begin
                perform net.http_post(url := 'https://dbwymcfmputeaggeeqfo.supabase.co/functions/v1/chat-push', body := '{}'::jsonb);
            exception when others then
                null;
            end;
        end if;
    end if;
    return true;
end;
$$;

-- Recusar ou "ocupado" (só conta numa conversa a dois): avisa quem ligou. "cancel" fica para versões antigas da app.
create or replace function public.call_signal(conv uuid, call uuid, what text) returns void
    language plpgsql security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    k public.chat_calls;
    other uuid;
begin
    if me is null or what not in ('cancel', 'decline', 'busy') then
        raise exception 'not_allowed';
    end if;
    select * into k from public.chat_calls where chat_calls.id = call and chat_calls.conversation_id = conv;
    if k.id is not null and k.started_by is not null and k.started_by <> me then
        if exists (select 1 from public.conversation_members cm where cm.conversation_id = conv and cm.user_id = me and cm.status = 'active') then
            perform realtime.send(jsonb_build_object('c', conv, 'k', 'call', 'what', what, 'id', call), 'chat', 'inbox:' || k.started_by::text, true);
        end if;
        return;
    end if;
    other := public.call_peer(conv);
    if other is null then
        raise exception 'not_allowed';
    end if;
    perform realtime.send(jsonb_build_object('c', conv, 'k', 'call', 'what', what, 'id', call), 'chat', 'inbox:' || other::text, true);
end;
$$;

-- O estado de uma chamada (ao abrir a app pelo aviso): ainda a tocar? a decorrer? quem ligou?
create or replace function public.call_state(call_id uuid) returns jsonb
    language plpgsql stable security definer set search_path = public as $$
declare
    me uuid := auth.uid();
    k public.chat_calls;
    c public.conversations;
    n integer;
begin
    select * into k from public.chat_calls where chat_calls.id = call_id;
    if me is null or k.id is null
       or not exists (select 1 from public.conversation_members cm where cm.conversation_id = k.conversation_id and cm.user_id = me and cm.status = 'active') then
        return null;
    end if;
    select * into c from public.conversations where conversations.id = k.conversation_id;
    n := public.call_live(k.present);
    return jsonb_build_object(
        'id', k.id, 'conv', k.conversation_id, 'video', k.video, 'group', c.kind = 'group',
        'g', case when c.kind = 'group' then c.title end,
        'open', k.ended_at is null and n > 0,
        'ringing', k.ended_at is null and n > 0 and k.answered_at is null and k.started_at > now() - interval '45 seconds',
        'n', n, 'here', k.present ? me::text, 'mine', k.started_by = me,
        'from', public.name_of(k.started_by), 'av', public.avatar_of(k.started_by), 'p', public.person_id(k.started_by));
end;
$$;

-- A chamada a decorrer numa conversa, se houver (para o botão "Entrar" nos grupos).
create or replace function public.conv_call(conv uuid) returns jsonb
    language plpgsql stable security definer set search_path = public as $$
declare
    k uuid;
begin
    if not public.is_active_member(conv) then
        return null;
    end if;
    select x.id into k from public.chat_calls x
     where x.conversation_id = conv and x.ended_at is null and public.call_live(x.present) > 0
     order by x.started_at desc limit 1;
    return case when k is null then null else public.call_state(k) end;
end;
$$;

-- ---------------------------------------------------------------- 5. O registo da chamada não manda o aviso genérico

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
    if is_message then
        conv := new.conversation_id;
        what := case when tg_op = 'INSERT' then 'new' else 'gone' end;
        if tg_op = 'INSERT' then
            new_message := new.kind not in ('system', 'call');
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

-- ---------------------------------------------------------------- Permissões

do $$
declare
    f text;
begin
    foreach f in array array[
        'call_targets(uuid, uuid)', 'call_live(jsonb)', 'close_stale_calls(uuid)', 'call_tell(uuid, uuid, text, integer)',
        'take_push_jobs()', 'chat_notify()'
    ] loop
        execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    end loop;
    foreach f in array array[
        'save_push(text, text, text, text)', 'ring_call(uuid, boolean)', 'join_call(uuid)', 'call_alive(uuid)', 'leave_call(uuid)',
        'call_signal(uuid, uuid, text)', 'call_state(uuid)', 'conv_call(uuid)'
    ] loop
        execute format('revoke execute on function public.%s from public, anon', f);
        execute format('grant execute on function public.%s to authenticated', f);
    end loop;
end;
$$;
grant execute on function public.take_push_jobs() to service_role;

commit;
