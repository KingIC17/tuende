-- 8 de outubro de 2026: avaliações, comentários, fotos e vídeos passam a ficar públicos logo que são enviados.
-- Correr uma vez no Supabase (SQL Editor). As denúncias continuam: com 3, o envio fica 'hidden'.

alter table public.reviews alter column status set default 'approved';
alter table public.submissions alter column status set default 'approved';

drop policy "Contas avaliam e comentam, sempre como pendente" on public.reviews;
create policy "Contas avaliam e comentam, publicado logo"
    on public.reviews for insert
    to authenticated
    with check (user_id = auth.uid() and status = 'approved' and report_count = 0);

drop policy "Contas enviam fotos e vídeos, sempre como pendentes" on public.submissions;
create policy "Contas enviam fotos e vídeos, publicados logo"
    on public.submissions for insert
    to authenticated
    with check (user_id = auth.uid() and status = 'approved' and report_count = 0);

-- O que estava à espera de aprovação passa a público.
update public.reviews set status = 'approved' where status = 'pending';
update public.submissions set status = 'approved' where status = 'pending';
