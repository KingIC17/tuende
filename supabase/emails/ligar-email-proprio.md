# Emails de conta com o nome Tuende (Resend + Supabase)

Hoje os emails de "Confirme a sua conta" e "Nova palavra-passe" saem do serviço incluído no Supabase: remetente genérico,
texto em inglês e um limite muito baixo por hora. Com um serviço próprio passam a sair de `nao-responder@tuende.app`, com
o nome "Tuende" e os modelos desta pasta (português e inglês).

## Porquê o Resend

- Grátis até 100 emails por dia e 3000 por mês, sem cartão (limites publicados pelo Resend em outubro de 2026).
- Tem um guia oficial para o Supabase (https://resend.com/docs/send-with-supabase-smtp): só um utilizador e uma chave.
- Os registos de DNS do Resend ficam no subdomínio `send.tuende.app` e numa chave DKIM, por isso não mexem no email
  `contacto@tuende.app` (ImprovMX) nem no site.

Alternativa: Brevo (cerca de 300 emails por dia grátis, `smtp-relay.brevo.com`, porta 587). Também serve, mas a
configuração tem mais passos e, sem DKIM, o remetente pode aparecer como `@brevosend.com`.

## Passos

Quem faz o quê: os passos 1, 3 e 4 são do dono (criar conta e colar a chave secreta). O passo 2 (DNS) posso fazê-lo eu na
Cloudflare, com autorização.

1. **Criar a conta** em https://resend.com com o email privado do projeto.
2. **Domínio:** em Resend > Domains > Add domain, escrever `tuende.app` (região: Irlanda, `eu-west-1`, a mais perto de Angola).
   O Resend mostra 3 ou 4 registos (um TXT `resend._domainkey`, um MX e um TXT em `send`). Acrescentá-los na Cloudflare
   (zona tuende.app > DNS > Records), todos em "DNS only" (nuvem cinzenta). Depois, no Resend, carregar em "Verify".
3. **Chave:** em Resend > API Keys > Create, nome "Supabase Tuende", permissão "Sending access", domínio `tuende.app`.
   A chave só aparece uma vez: copie-a diretamente para o passo 4 e não a envie por chat nem por email.
4. **Supabase** (https://supabase.com/dashboard > projeto Tuende > Authentication > Emails > SMTP Settings):
   - Enable custom SMTP: ligado
   - Sender email: `nao-responder@tuende.app`
   - Sender name: `Tuende`
   - Host: `smtp.resend.com`
   - Port: `465`
   - Username: `resend`
   - Password: a chave do passo 3
   - Guardar.
5. **Modelos:** em Authentication > Emails > Templates:
   - "Confirm signup": assunto `Confirme a sua conta no Tuende`, corpo = conteúdo de `confirm-signup.html`.
   - "Reset password": assunto `Nova palavra-passe no Tuende`, corpo = conteúdo de `reset-password.html`.
6. **Limite por hora:** em Authentication > Rate Limits, subir "Rate limit for sending emails" para 30 por hora
   (fica abaixo dos 100 por dia do Resend grátis).
7. **Testar:** criar uma conta nova no Tuende com outro email e pedir uma nova palavra-passe. Os dois emails devem
   chegar de "Tuende <nao-responder@tuende.app>". Se der erro 500, esperar que o domínio fique "Verified" no Resend.

Se um dia passar dos 100 emails por dia, o envio pára até ao dia seguinte (o plano grátis não cobra nada a mais); aí vale a pena ver os planos pagos do Resend.
