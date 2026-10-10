-- 10 de outubro de 2026: filtro de palavras (regra 1.2 da App Store para conteúdo publicado por utilizadores).
-- Comentários, legendas de fotos e vídeos e o nome público de quem publica são recusados se tiverem uma
-- palavra da lista. Continuam a ser publicados logo; só o que tiver palavras proibidas é recusado.
-- Correr uma vez no Supabase (SQL Editor). Só acrescenta; não apaga nada.
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
