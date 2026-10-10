-- 10 de outubro de 2026: bloquear pessoas (regra 1.2 da App Store para conteúdo publicado por utilizadores).
-- Quem tem conta pode bloquear o autor de um comentário, foto ou vídeo: deixa de ver tudo o que essa pessoa
-- publica. A pessoa bloqueada não é avisada e continua a ver o que publicou. Desbloquear: na Conta da app.
-- Correr uma vez no Supabase (SQL Editor). Só troca as duas regras de leitura de reviews e submissions.
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
