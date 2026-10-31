# Emails de conta com o nome Tuende (Resend + Supabase)

Hoje os emails de "Confirme a sua conta", "Nova palavra-passe" e "Mudar o email" saem do serviço incluído no Supabase:
remetente "Supabase Auth", texto em inglês, sem nada do Tuende, e um limite muito baixo por hora. Quem os recebe pode
achar que não têm nada a ver com o Tuende. O Supabase só deixa mudar o texto destes emails depois de ligar um serviço de
envio próprio (SMTP). Com o Resend, passam a sair de "Tuende <nao-responder@mail.tuende.app>", com o logótipo, o nome e as
cores do Tuende, na língua de cada pessoa (português, inglês, francês ou espanhol).

## O que já está feito

- Conta no Resend e domínio `mail.tuende.app` verificado (região Irlanda, `eu-west-1`), com os registos de DNS na Cloudflare.
- Os modelos desta pasta: `confirm-signup.html`, `reset-password.html`, `change-email.html` e os assuntos em
  `*.subject.txt`. São gerados por `tools/emails_conta.py`; `pre-visualizacao/` mostra cada email em cada língua.
- A app guarda a língua de cada pessoa na conta (`lang`), para o email sair na língua certa.

## O que falta (passos do dono)

1. **Chave:** em https://resend.com > API Keys > Create API Key, nome "Supabase Tuende", permissão "Sending access",
   domínio `mail.tuende.app`. A chave só aparece uma vez: copie-a diretamente para o passo 2 e não a envie por chat nem
   por email.
2. **Supabase** (https://supabase.com/dashboard > projeto Tuende > Authentication > Emails > SMTP Settings):
   - Enable custom SMTP: ligado
   - Sender email: `nao-responder@mail.tuende.app`
   - Sender name: `Tuende`
   - Host: `smtp.resend.com`
   - Port: `465`
   - Username: `resend`
   - Password: a chave do passo 1
   - Guardar.
3. **Modelos** (Authentication > Emails > Templates). Para cada um, colar o assunto do ficheiro `.subject.txt` e o corpo
   do ficheiro `.html` (todo o conteúdo):
   - "Confirm signup": `confirm-signup.subject.txt` e `confirm-signup.html`
   - "Reset password": `reset-password.subject.txt` e `reset-password.html`
   - "Change email address": `change-email.subject.txt` e `change-email.html`

   Depois do passo 2, também posso colar os modelos eu, com autorização.
4. **Limite por hora:** em Authentication > Rate Limits, subir "Rate limit for sending emails" para 30 por hora
   (fica abaixo dos 100 por dia do Resend grátis).
5. **Testar:** criar uma conta nova no Tuende com outro email e pedir uma nova palavra-passe. Os emails devem chegar de
   "Tuende", com o logótipo e o nome Tuende no topo.

Se um dia passar dos 100 emails por dia, o envio pára até ao dia seguinte (o plano grátis não cobra nada a mais); aí vale
a pena ver os planos pagos do Resend.
