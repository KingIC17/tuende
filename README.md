# Tuende

Antes chamado ANGOLIVE (mudou de nome a 6 de outubro de 2026).

Guia de Angola: restaurantes, bares, discotecas, praias, cultura, museus, natureza, alojamento, compras, praças, ginásios e piscinas, transportes e câmbio, com preços em Kwanza, agenda de eventos e contas de utilizador.

- Site: https://kingic17.github.io/tuende/ (o endereço antigo kingic17.github.io/ANGOLIVE/ redireciona para aqui)
- Objetivo: publicar como site, na Google Play (Android) e na App Store (iPhone).

## Estado atual (6 de outubro de 2026)

| Parte | Estado |
|---|---|
| Site (web app) | Online no GitHub Pages, 60 locais e agenda de eventos |
| App instalável (PWA) | `manifest.json` e `sw.js` publicados; modo offline ainda não testado num browser real |
| App iPhone (`ios/`) | Projeto Xcode criado; o código Swift passa o `swiftc -typecheck`, mas o build completo e o simulador ainda não foram testados |
| App Android | Por fazer (depende do domínio próprio) |
| Contas, comentários, fotos e vídeos | Ligado ao Supabase (organização Tuende, projeto `tuende`, antes `angolive`; região West EU / Irlanda, 6 de outubro de 2026). `setup.sql` já foi corrido; email de confirmação ligado; palavra-passe com 8+ caracteres |
| Domínio próprio | tuende.app sugerido (tuende.com já está ocupado); falta comprar e configurar (ver abaixo) |
| Política de privacidade | Escrita, por publicar (falta confirmar o email de contacto) |

## Estrutura

```
index.html               App completa num só ficheiro (HTML + CSS + JS, sem dependências)
angolive-complete.html   Antigo nome da app: redireciona para ./ (mantém #local-N e ?page=)
manifest.json            Manifesto PWA (start_url ./)
og-image.jpg             Imagem de pré-visualização (1200x630) para links partilhados no LinkedIn, WhatsApp, Facebook
sw.js                    Service worker: network-first para a página, cache-first para as fotos (photos/)
photos/                  Fotos dos locais e eventos guardadas no próprio site (cópias do Wikimedia Commons e do Unsplash, com créditos na app), em 330/960 px (Commons) e 600/800 px (Unsplash). Assim carregam em qualquer país (o Wikimedia está bloqueado na China) e sem internet
icon-192.png, icon-512.png, apple-touch-icon.png
privacy.html             Política de privacidade PT/EN (por publicar: falta o email)
supabase/setup.sql       Base de dados dos comentários, fotos e vídeos dos visitantes
ios/                     Projeto Xcode (SwiftUI + WKWebView)
  ANGOLIVE.xcodeproj
  ANGOLIVE/AngoliveApp.swift
  ANGOLIVE/index.html               Cópia local da app, para funcionar offline
  ANGOLIVE/Assets.xcassets          Ícone 1024x1024 sem transparência
```

## Como funciona a app web

- Os dados dos locais e menus estão no próprio ficheiro: `const venues` (60 locais) e `const menuData`.
- Página inicial (por esta ordem): título e pesquisa "O que procura? / Onde?", filtros rápidos, Recomendados (com o motivo), Explorar por categoria, Coleções e Viagens de um dia a partir de Luanda (calculado pela distância). Pesquisa, filtros, categorias e coleções abrem a vista de resultados.
- A vista de resultados fica no endereço e pode ser partilhada: `?q=praia&where=luanda`, `?filter=free`, `?category=culture`, `?collection=beaches`, `?saved=1`. Os botões voltar/avançar do browser funcionam.
- Pesquisa sem acentos, com plurais (hotéis → hotel) e com tolerância a um erro de escrita por palavra (`tokens`, `stem`, `withinOneEdit`). Sinónimos em `SYNONYMS`.
- `price`: `{ from, to, per: 'person' | 'night' | 'entry' | 'trip' | 'month', estimate, note: { pt, en } }`, `{ text: { pt, en } }` (quando não há valor fixo, ex.: câmbio, voos) ou `{ free: true }`; sem `price` aparece "Preço por confirmar". Os valores com `estimate` são indicativos; `note` aparece por baixo do preço no detalhe.
- `hoursText: { pt, en }` mostra um horário em texto quando não há horário completo por dia; `citywide: true` (táxis, apps) esconde "Como chegar" e o mapa.
- Página "Recomendar um lugar" (inspirada no "Recommend a Pro" da Afenlight): categoria, nome, cidade, morada, telefone/WhatsApp, email, website, artigo, até 5 redes sociais, outro link, até 5 fotos, motivo, relação com o lugar e contacto opcional de quem recomenda. As fotos são comprimidas no telemóvel e enviadas para a pasta privada `recommendations` do Supabase; os caminhos ficam na coluna `photos`. Só com email (sem Supabase), a secção de fotos pede para anexar as fotos ao email.
- Eventos com `photo` (foto livre do local ou da zona, do Wikimedia Commons, com legenda e créditos; nunca cartazes).
- Página "Agenda" (`?page=events`, inspirada em https://afenlight.com/events): eventos com filtros Quando (hoje, fim de semana, esta semana, próxima semana, este mês, próximo mês), Tipo (com contagem) e Onde (aparece quando houver eventos em mais de uma cidade), agrupados por mês. Cada evento tem datas, horário, local, preço, etiquetas, "Mais informações" (descrição, programa, organização, contactos e fonte com data de verificação), bilhetes ou página oficial, Como chegar, Calendário (ficheiro .ics; escondido na app iPhone) e Partilhar. A página inicial mostra os 3 próximos eventos, há um botão "Agenda" nos filtros rápidos e no rodapé, e links diretos `?page=events#evento-<id>`. O formulário "Sugerir um evento" envia para a tabela `event_suggestions` (ou por email).
- Eventos: `const EVENTS`. Só entram eventos com fonte publicada (`source`, `checked`). Campos: `type` (`EVENT_TYPES`: music, dance, theatre, film, fashion, fairs, sports), `title`/`desc`/`tags` em PT e EN, `city`, `venue` (vazio = local a confirmar; `venueTbc` = só a zona), `mapsQuery`, `start`/`end` (AAAA-MM-DD, hora de Angola), `days` (dias da semana em que acontece), `programme` (datas do programa; os filtros usam só essas datas), `time` e `hours` (para o calendário), `when` (horário em texto), `price` (`from`/`to` em Kz, `text`, `note` ou `free`), `link` e `tickets`, `host`, `phones`, `confirmed: false` (evento anual ainda por anunciar). Cada evento sai da agenda sozinho depois do último dia. Atualizar a lista duas vezes por mês, nos dias 1 e 15 (fontes principais: secção Eventos do Ver Angola, ticket.ao e check-in.ao).
- "Guardados" substitui o antigo perfil (que pedia email sem o usar). Os dados antigos de perfil e de comentários locais são apagados ao abrir a app.
- Campos de cada local: `type` (as chaves de `CATEGORY`: restaurant, bar, nightclub, beach, culture, museum, nature, accommodation, shopping, plaza, sport, transport, services), `highlight` (destaque útil PT/EN, também usado como motivo das recomendações), `family` (sugestão editorial para famílias), `address`, `hours` (horário por dia da semana, 0 = domingo, hora de Angola), `verified` (data e fontes da verificação; `stale` quando as fontes têm alguns anos).
- O estado "Aberto/Fechado" só aparece com horário confirmado. O filtro "Aberto agora" aparece automaticamente quando pelo menos 8 locais tiverem `hours` (`MIN_PLACES_WITH_HOURS`). Hoje só a Fortaleza de São Miguel tem horário com fonte.
- Recomendados, coleções e cidades: `RECOMMENDED`, `COLLECTIONS`, `CITIES`.
- O detalhe mostra primeiro a informação prática (horário, morada, mapa, preço, contacto, o que falta confirmar e quando foi verificado) e só depois a descrição.
- `exact: true` indica coordenadas confirmadas na Wikipedia/Wikidata. Nos restantes, "Como chegar" e "Ver no mapa" pesquisam o nome do local no Google Maps, e as coordenadas só servem para calcular distâncias aproximadas.
- `photos`: fotos reais do Wikimedia Commons, com autor, licença e página de origem (mostrados na app, como as licenças CC BY/CC BY-SA exigem); os ficheiros estão em `photos/` (`url` 960 px, `thumb` 330 px). Locais sem `photos` usam `image` (`photos/unsplash-...-800.jpg`, miniatura `-600.jpg`), uma foto ilustrativa do Unsplash, com a etiqueta "Foto ilustrativa". Para juntar fotos novas, descarregar as versões 330 e 960 px para `photos/`. Na app iPhone as fotos vêm do site público (`asset()`).
- Português por defeito, com botão para Inglês. Os textos estão em `I18N`; as traduções das descrições estão em `DESC_EN` e `MENU_DESC_EN`.
- Perfil, favoritos, comentários, idioma e tema ficam no `localStorage` do dispositivo. Não há servidor.
- "Perto de mim" usa `navigator.geolocation` apenas no dispositivo.
- Links diretos para um local: `https://kingic17.github.io/tuende/#local-<id>`.
- Pedido do dono: sem emojis no design; os ícones são SVG inline (`ICONS`).

Para correr localmente:

```bash
python3 -m http.server 8000
```

e abrir http://localhost:8000/

## App iPhone (`ios/`)

- SwiftUI com um `WKWebView` que carrega `ANGOLIVE/index.html` do bundle (`file://`). A app aparece no telemóvel como "Tuende"; o projeto e a pasta no Xcode continuam a chamar-se ANGOLIVE.
- Links externos (Google Maps, WhatsApp, YouTube...) abrem nas apps do sistema.
- Dentro da app (`file://`), o aviso "instalar" não aparece e o botão Partilhar usa `PUBLIC_URL`.
- Bundle ID: `com.tuende.app`. iOS 16+.
- Sempre que se alterar `index.html`, é preciso copiá-lo também para `ios/ANGOLIVE/index.html`.

## Contas, comentários, fotos e vídeos dos visitantes (Supabase)

Com o Supabase ligado aparece o botão "Entrar" no topo. Com conta, as pessoas guardam lugares em todos os dispositivos, avaliam (estrelas opcionais), comentam, enviam fotos e vídeos, corrigem ou acrescentam informação e denunciam conteúdo. Sem conta, continuam a ver tudo e a guardar lugares no próprio dispositivo. Em "A minha conta" veem o estado do que enviaram, mudam o nome público, terminam a sessão ou apagam a conta (obrigatório para a App Store).

1. Criar uma conta gratuita em https://supabase.com e um projeto novo.
2. Em **SQL Editor**, colar e correr `supabase/setup.sql`.
3. Em **Authentication > Sign In / Providers > Email**: manter "Confirm email" ligado e pôr o comprimento mínimo da palavra-passe em 8.
4. Em **Authentication > URL Configuration**: Site URL = `https://kingic17.github.io/tuende/` (ou o domínio próprio) e juntar `https://kingic17.github.io/tuende/**` em "Redirect URLs" (os links de ativação e de recuperação voltam para a app).
5. Recomendado antes de abrir ao público: em **Authentication > Emails > SMTP Settings**, ligar um serviço de email próprio (ex.: Resend, Brevo); o envio de emails incluído no Supabase tem um limite muito baixo por hora. Os textos dos emails podem ser traduzidos em **Authentication > Emails > Templates**.
6. Em **Project Settings > API**, copiar o Project URL e a chave pública (publishable/anon) para `SUPABASE_URL` e `SUPABASE_KEY` em `index.html` (e na cópia em `ios/ANGOLIVE/`). Esta chave é pública por natureza; a segurança vem das regras RLS do `setup.sql`. Nunca usar a chave `service_role` na app.
7. Moderação: em **Table Editor > reviews** (comentários) e **submissions** (fotos e vídeos), mudar `status` para `approved` para publicar, ou `rejected` para recusar. Com 3 denúncias fica `hidden` automaticamente.
8. Sugestões de eventos: em **Table Editor > event_suggestions**. Depois de confirmar o evento numa fonte, juntá-lo a `EVENTS` e mudar `status` para `added`.
9. Recomendações: em **Table Editor > recommendations**. As fotos de cada recomendação estão em **Storage > recommendations**, na pasta indicada na coluna `photos` (pasta privada, só visível no painel).

As estrelas de cada local são a média dos comentários aprovados (vista `review_stats`). Tocar na nota leva à secção de comentários, que também tem ligações para as avaliações no Google Maps e no TripAdvisor.

As fotos são comprimidas na app (máx. 1600 px, JPEG) antes de enviar. Os vídeos entram como link do YouTube, TikTok ou Instagram.

## Interruptores de configuração (em `index.html`)

- `CONTACT_EMAIL`: enquanto estiver vazio, ficam escondidos Contacto, Privacidade e o envio de correções por email.
- `SUPABASE_URL` / `SUPABASE_KEY`: enquanto estiverem vazios, ficam escondidos o formulário de avaliações, as estrelas, a ordenação "Melhor avaliação" e a partilha de fotos e vídeos; a secção "Opiniões" mostra só as ligações para o Google Maps e o TripAdvisor.
- "Recomendar um lugar" (`?page=recommend`, tabela `recommendations`) e "Corrigir um lugar" (tabela `corrections`) enviam para o Supabase, ou por email se só houver `CONTACT_EMAIL`. Sem nenhum dos dois, as ligações ficam escondidas e a página de recomendação mostra o envio desligado com um aviso.

## Domínio tuende.app

Não adicionar o domínio no GitHub antes de o comprar e configurar o DNS: o endereço kingic17.github.io passaria a redirecionar para um domínio que ainda não funciona.

1. Comprar `tuende.app` (ex.: Cloudflare, Porkbun). Os domínios `.app` só funcionam com HTTPS, que o GitHub Pages dá de graça.
2. No DNS do domínio, criar:
   - 4 registos `A` para `@`: `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
   - 1 registo `CNAME` para `www` → `kingic17.github.io`
3. No GitHub: **Settings > Pages > Custom domain** → `tuende.app` → Save. Depois de verificado, ativar **Enforce HTTPS**.
4. Recomendado: verificar o domínio na conta GitHub (**Settings > Pages > Verified domains**) para ninguém o poder usar noutro repositório.
5. Atualizar `PUBLIC_URL` em `index.html` (e na cópia em `ios/`) para `https://tuende.app/`, as etiquetas `og:url` e `og:image`, o `canonical` de `angolive-complete.html` e os endereços no Supabase (Site URL e Redirect URLs).

## O que falta fazer

1. **Contas** (dono): Apple Developer Program e Google Play Console.
2. **Domínio próprio**: configurar o custom domain no GitHub Pages e os registos DNS, e atualizar `PUBLIC_URL` em `index.html`.
3. **Android**: gerar o pacote AAB como Trusted Web Activity (PWABuilder ou Bubblewrap) e publicar `/.well-known/assetlinks.json` no domínio (com `.nojekyll` na raiz do repositório). As contas pessoais novas da Google Play exigem um teste fechado com 12 testadores durante 14 dias.
4. **iPhone**: build, testes, capturas de ecrã e submissão. Atenção à regra 4.2 da Apple ("minimum functionality"): apps que só mostram um site podem ser recusadas.
5. **Política de privacidade**: publicar `privacy.html` assim que o email de contacto estiver confirmado, e ligá-la a partir da app e das fichas das lojas.
6. **Dados por confirmar** (verificação feita em outubro de 2026 com Wikipedia e o guia Ver Angola):
   - Confirmados como existentes: Café del Mar (Ilha de Luanda), O Madeirense (Liga Africana), Lookal Mar e Lookal Beach Club (Ilha do Cabo), EPIC SANA Luanda, NovaCâmbios, Batuk (Restinga do Lobito), Hotel Serra da Chela. Miami Beach, Chill Out e Coconuts vêm de artigos de 2015 a 2021: confirmar se continuam abertos.
   - Removidos por não haver fontes: "Caminito Night Club" e "Messe Hotel Huila" (substituído pelo Hotel Serra da Chela). "Lookal Ocean Club" passou a "Lookal Mar".
   - As estrelas inventadas foram removidas (outubro de 2026). Agora só aparecem estrelas calculadas a partir de comentários reais.
   - Os telefones foram removidos até serem confirmados (campo `phone` vazio); os botões Ligar e WhatsApp só aparecem quando há número.
   - Os preços dos menus e algumas descrições ainda não foram confirmados com os locais.
   - Alguns locais ainda usam fotos ilustrativas (Unsplash), marcadas como tal; os outros têm fotos reais do Wikimedia Commons.
   - Locais acrescentados a 6 de outubro de 2026 (ids 34 a 61): transportes, museus, centros comerciais, praças, bares, discotecas, câmbio, ginásios e piscina. Fontes: sites oficiais, Expansão, Novo Jornal, ANGOP, Ver Angola, Wikipedia e OpenStreetMap. Onde nenhuma fonte publica o preço ou o horário, a app mostra "por confirmar". Tarifas atualizadas: táxi coletivo 300 Kz e autocarro urbano 200 Kz (julho de 2025), comboio suburbano 300 Kz (maio de 2026).
   - Por confirmar com os próprios locais: preços dos bares, discotecas e ginásios; horário e acesso do público à Piscina do Alvalade (não encontrámos piscinas públicas com preço publicado em Luanda); horários de alguns centros comerciais.
7. **Supabase**: ligado. Antes de abrir ao público, configurar um SMTP próprio (o envio de emails incluído no Supabase tem um limite muito baixo por hora) e traduzir os modelos de email para português.

## Problema conhecido no Mac do dono

O Xcode 26.5 falha ao compilar com um erro de bibliotecas do sistema (`CoreDevice` / `Mercury`: `Symbol not found: _XPCTypeBool`). Provável desencontro entre as versões do macOS e do Xcode. Tentar `sudo xcodebuild -runFirstLaunch` ou atualizar o macOS e o Xcode.
