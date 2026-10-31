# Ligar o servidor de retransmissão das chamadas (TURN da Cloudflare)

Sem isto, as chamadas do Tuende já funcionam, mas podem falhar em algumas redes móveis (a rede não deixa os dois
telemóveis falarem diretamente). Com o TURN, a chamada passa pela Cloudflare quando é preciso. A Cloudflare não consegue
ouvir nem ver a chamada (vai cifrada de ponta a ponta).

Custo: os primeiros 1000 GB por mês são grátis; depois, 0,05 dólares por GB (preço da Cloudflare em novembro de 2026).
Uma chamada de voz de 10 minutos gasta cerca de 5 MB; uma videochamada de 10 minutos, cerca de 50 MB.

## Passos (só o dono; 5 minutos)

1. Entre em dash.cloudflare.com com a conta do Tuende (tuende.ao@gmail.com).
2. No menu da esquerda: **Realtime** (ou "Calls") > **TURN Server** > **Create** (ou "Create TURN key").
   Dê o nome `Tuende chamadas`.
3. A Cloudflare mostra duas coisas: o **Turn Token ID** e o **API Token**. O API Token só aparece uma vez.
4. Abra o Supabase: projeto do Tuende > **Edge Functions** > **Secrets** (ou "Manage secrets") e acrescente:
   - `CF_TURN_KEY_ID` = o Turn Token ID
   - `CF_TURN_KEY_API_TOKEN` = o API Token
5. Guarde. Não é preciso publicar nada: a função `turn-credentials` passa a dar o servidor às chamadas no minuto seguinte.

Não cole estes valores em mensagens, nem no chat com o assistente: são segredos.

## Como confirmar

Numa chamada, abra a consola do navegador e veja que `turn.servers` tem endereços `turn:turn.cloudflare.com`.
Ou peça ao assistente para verificar a resposta da função (`ready: true`) com a sua sessão.
