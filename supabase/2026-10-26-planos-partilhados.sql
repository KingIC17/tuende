-- 26 de outubro de 2026: planos partilhados. Quem fez um plano cria um link e os amigos (com conta) acrescentam
-- lugares, eventos e notas ao mesmo plano (ideia do Wanderlog, adaptada ao Tuende).
-- Para aplicar: Supabase > SQL Editor > New query > colar tudo > Run. Pode correr-se mais de uma vez.
-- A app deteta sozinha esta novidade: antes de correr isto, «Planear com amigos» diz «em breve».
--
-- O que muda:
--   1. shared_plans: o plano (nome, primeiro dia, dias com lugares, eventos e notas), o link secreto (token),
--      quem o criou, a versão (para duas pessoas não apagarem as mudanças uma da outra) e quem mudou por último.
--   2. shared_plan_members: quem já editou o plano (a app mostra «3 pessoas neste plano»).
--   3. Ninguém lê as tabelas diretamente: tudo passa pelas funções abaixo. Ver um plano só com o link;
--      mudar exige conta. O filtro de palavras recusa nomes e notas ofensivos.
--      Limites: 30 dias, 60 itens por dia, 50 planos partilhados criados por conta.
--   4. Quem criou o plano pode deixar de o partilhar (apaga-o do servidor; as cópias nos telemóveis ficam).
--   5. Ao apagar a conta, os planos que criou são apagados em cascata.

begin;

create table if not exists public.shared_plans (
    id uuid primary key default gen_random_uuid(),
    token text not null unique default replace(gen_random_uuid()::text, '-', ''),
    owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    name text not null check (char_length(name) between 1 and 80),
    start_date date,
    days jsonb not null default '[[]]'::jsonb,
    version integer not null default 1,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    updated_by uuid references auth.users (id) on delete set null,
    updated_by_name text
);
alter table public.shared_plans enable row level security;
revoke all on public.shared_plans from anon, authenticated;

create table if not exists public.shared_plan_members (
    plan_id uuid not null references public.shared_plans (id) on delete cascade,
    user_id uuid not null references auth.users (id) on delete cascade,
    joined_at timestamptz not null default now(),
    primary key (plan_id, user_id)
);
alter table public.shared_plan_members enable row level security;
revoke all on public.shared_plan_members from anon, authenticated;

-- Confere o plano antes de guardar: 1 a 30 dias, até 60 itens por dia, cada item {kind, ref, time},
-- e passa o nome e as notas pelo filtro de palavras.
create or replace function public.shared_plan_check(p_name text, p_days jsonb) returns void
    language plpgsql stable security definer set search_path = public as $$
declare
    d jsonb;
    it jsonb;
    texts text := coalesce(p_name, '');
begin
    if p_days is null or jsonb_typeof(p_days) <> 'array' or jsonb_array_length(p_days) < 1 or jsonb_array_length(p_days) > 30
       or pg_column_size(p_days) > 65536 then
        raise exception 'plano inválido' using errcode = '22023';
    end if;
    for d in select value from jsonb_array_elements(p_days) loop
        if jsonb_typeof(d) <> 'array' or jsonb_array_length(d) > 60 then
            raise exception 'dia inválido' using errcode = '22023';
        end if;
        for it in select value from jsonb_array_elements(d) loop
            if jsonb_typeof(it) <> 'object'
               or coalesce(it ->> 'kind', '') not in ('place', 'event', 'note')
               or char_length(coalesce(it ->> 'ref', '')) not between 1 and 200
               or coalesce(it ->> 'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$|^$' then
                raise exception 'item inválido' using errcode = '22023';
            end if;
            if it ->> 'kind' = 'note' then
                texts := texts || ' ' || (it ->> 'ref');
            end if;
        end loop;
    end loop;
    if public.has_blocked_words(texts) then
        raise exception 'O texto tem palavras que não são permitidas.' using errcode = 'P0001';
    end if;
end;
$$;
revoke all on function public.shared_plan_check(text, jsonb) from public, anon, authenticated;

-- Cria o plano partilhado e devolve o token do link.
create or replace function public.create_shared_plan(p_name text, p_start date, p_days jsonb) returns text
    language plpgsql security definer set search_path = public as $$
declare
    new_id uuid;
    new_token text;
begin
    if auth.uid() is null then
        raise exception 'É preciso entrar na conta.' using errcode = '42501';
    end if;
    if (select count(*) from public.shared_plans where owner_id = auth.uid()) >= 50 then
        raise exception 'Limite de planos partilhados.' using errcode = '54000';
    end if;
    perform public.shared_plan_check(p_name, p_days);
    insert into public.shared_plans (owner_id, name, start_date, days, updated_by, updated_by_name)
    values (auth.uid(), left(coalesce(nullif(btrim(p_name), ''), 'Plano'), 80), p_start, p_days, auth.uid(), public.current_display_name())
    returning id, token into new_id, new_token;
    insert into public.shared_plan_members (plan_id, user_id) values (new_id, auth.uid()) on conflict do nothing;
    return new_token;
end;
$$;
revoke all on function public.create_shared_plan(text, date, jsonb) from public, anon;
grant execute on function public.create_shared_plan(text, date, jsonb) to authenticated;

-- Ler um plano: só com o token (32 caracteres), com ou sem conta.
create or replace function public.get_shared_plan(p_token text)
    returns table (plan_name text, plan_start date, plan_days jsonb, plan_version integer, plan_updated timestamptz,
                   plan_editor text, plan_members integer, plan_is_owner boolean)
    language sql stable security definer set search_path = public as $$
    select p.name, p.start_date, p.days, p.version, p.updated_at, p.updated_by_name,
           (select count(*)::integer from public.shared_plan_members m where m.plan_id = p.id),
           coalesce(p.owner_id = auth.uid(), false)
      from public.shared_plans p
     where char_length(p_token) = 32 and p.token = p_token;
$$;
revoke all on function public.get_shared_plan(text) from public;
grant execute on function public.get_shared_plan(text) to anon, authenticated;

-- Guardar: só se a versão for a mesma que a app leu. Se alguém mudou entretanto, não guarda e devolve a versão
-- atual (saved = false), para a app juntar as duas mudanças e tentar de novo.
create or replace function public.save_shared_plan(p_token text, p_version integer, p_name text, p_start date, p_days jsonb)
    returns table (saved boolean, plan_name text, plan_start date, plan_days jsonb, plan_version integer, plan_editor text, plan_members integer)
    language plpgsql security definer set search_path = public as $$
declare
    r public.shared_plans%rowtype;
begin
    if auth.uid() is null then
        raise exception 'É preciso entrar na conta.' using errcode = '42501';
    end if;
    select * into r from public.shared_plans sp where char_length(p_token) = 32 and sp.token = p_token for update;
    if not found then
        raise exception 'Plano não encontrado.' using errcode = 'P0002';
    end if;
    if r.version <> p_version then
        return query select false, r.name, r.start_date, r.days, r.version, r.updated_by_name,
                            (select count(*)::integer from public.shared_plan_members m where m.plan_id = r.id);
        return;
    end if;
    perform public.shared_plan_check(p_name, p_days);
    update public.shared_plans sp
       set name = left(coalesce(nullif(btrim(p_name), ''), r.name), 80),
           start_date = p_start,
           days = p_days,
           version = r.version + 1,
           updated_at = now(),
           updated_by = auth.uid(),
           updated_by_name = public.current_display_name()
     where sp.id = r.id
    returning * into r;
    insert into public.shared_plan_members (plan_id, user_id) values (r.id, auth.uid()) on conflict do nothing;
    return query select true, r.name, r.start_date, r.days, r.version, r.updated_by_name,
                        (select count(*)::integer from public.shared_plan_members m where m.plan_id = r.id);
end;
$$;
revoke all on function public.save_shared_plan(text, integer, text, date, jsonb) from public, anon;
grant execute on function public.save_shared_plan(text, integer, text, date, jsonb) to authenticated;

-- Deixar de partilhar: só quem criou o plano.
create or replace function public.delete_shared_plan(p_token text) returns boolean
    language plpgsql security definer set search_path = public as $$
begin
    delete from public.shared_plans sp where sp.token = p_token and sp.owner_id = auth.uid();
    return found;
end;
$$;
revoke all on function public.delete_shared_plan(text) from public, anon;
grant execute on function public.delete_shared_plan(text) to authenticated;

-- Teste: uma conta existente cria, lê e guarda um plano, e uma versão antiga é recusada; tudo é logo desfeito.
-- Se algo falhar, dá erro e nada fica aplicado.
do $$
declare
    uid uuid := (select id from auth.users order by created_at limit 1);
    tok text;
    ok boolean;
begin
    if uid is null then
        return;
    end if;
    begin
        perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
        set local role authenticated;
        tok := public.create_shared_plan('Teste', null, '[[{"kind": "place", "ref": 7, "time": "09:00"}], []]'::jsonb);
        perform * from public.get_shared_plan(tok);
        select s.saved into ok from public.save_shared_plan(tok, 1, 'Teste 2', null, '[[{"kind": "note", "ref": "olá", "time": ""}]]'::jsonb) s;
        if not ok then raise exception 'a primeira gravação devia passar'; end if;
        select s.saved into ok from public.save_shared_plan(tok, 1, 'Teste 3', null, '[[]]'::jsonb) s;
        if ok then raise exception 'uma versão antiga não devia gravar'; end if;
        perform public.delete_shared_plan(tok);
        raise exception using errcode = 'TT001', message = 'teste ok';
    exception when sqlstate 'TT001' then
        null; -- O plano de teste foi criado, lido, guardado e apagado, e já foi desfeito.
    end;
    reset role;
end;
$$;

commit;
