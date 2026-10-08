-- 8 de outubro de 2026: foto de perfil. Cada conta escolhe uma máscara angolana (desenhos da app)
-- ou carrega uma foto sua; aparece junto dos comentários, fotos e vídeos.
-- Correr uma vez no Supabase (SQL Editor). Só acrescenta; não apaga nada.

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
