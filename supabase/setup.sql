-- ANGOLIVE: fotos e vídeos dos visitantes.
-- Correr uma vez no Supabase: SQL Editor > New query > colar tudo > Run.
--
-- Como funciona:
--   * Qualquer pessoa pode enviar uma foto ou um link de vídeo; fica com o estado 'pending'.
--   * Só aparecem na app as linhas com estado 'approved'.
--   * Para aprovar: Table Editor > submissions > mudar status para 'approved' (ou 'rejected').
--   * Cada "Denunciar" soma 1 a report_count; com 3 denúncias o envio fica 'hidden' automaticamente.

create table public.submissions (
    id uuid primary key default gen_random_uuid(),
    venue_id integer not null,
    kind text not null check (kind in ('photo', 'video')),
    url text not null check (url like 'https://%' and char_length(url) <= 500),
    author text not null check (char_length(author) between 1 and 60),
    caption text check (char_length(caption) <= 200),
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'hidden')),
    report_count integer not null default 0,
    created_at timestamptz not null default now()
);

create index submissions_venue_status_idx on public.submissions (venue_id, status, created_at desc);

alter table public.submissions enable row level security;

create policy "Visitantes veem apenas envios aprovados"
    on public.submissions for select
    to anon, authenticated
    using (status = 'approved');

create policy "Visitantes podem enviar, sempre como pendente"
    on public.submissions for insert
    to anon, authenticated
    with check (status = 'pending' and report_count = 0);

create table public.reports (
    id bigint generated always as identity primary key,
    submission_id uuid not null references public.submissions (id) on delete cascade,
    reason text check (char_length(reason) <= 200),
    created_at timestamptz not null default now()
);

alter table public.reports enable row level security;

create policy "Visitantes podem denunciar"
    on public.reports for insert
    to anon, authenticated
    with check (true);

create function public.handle_report() returns trigger
    language plpgsql
    security definer
    set search_path = public
as $$
begin
    update public.submissions
       set report_count = report_count + 1,
           status = case when report_count + 1 >= 3 then 'hidden' else status end
     where id = new.submission_id;
    return new;
end;
$$;

create trigger on_report
    after insert on public.reports
    for each row execute function public.handle_report();

-- Fotos: pasta pública, só JPEG até 5 MB (a app comprime antes de enviar).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('submissions', 'submissions', true, 5242880, array['image/jpeg']);

create policy "Visitantes podem enviar fotos"
    on storage.objects for insert
    to anon, authenticated
    with check (bucket_id = 'submissions');
