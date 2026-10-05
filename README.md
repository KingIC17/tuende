# ANGOLIVE

Guia de Angola: restaurantes, festas e nightclubs, beach clubs, alojamento, turismo e câmbio, com preços em Kwanza.

- Site: https://kingic17.github.io/ANGOLIVE/
- Objetivo: publicar como site, na Google Play (Android) e na App Store (iPhone).

## Estado atual (5 de outubro de 2026)

| Parte | Estado |
|---|---|
| Site (web app) | Online no GitHub Pages, 32 locais |
| App instalável (PWA) | `manifest.json` e `sw.js` publicados; modo offline ainda não testado num browser real |
| App iPhone (`ios/`) | Projeto Xcode criado; o código Swift passa o `swiftc -typecheck`, mas o build completo e o simulador ainda não foram testados |
| App Android | Por fazer (depende do domínio próprio) |
| Comentários, fotos e vídeos dos visitantes | Código pronto e testado com um servidor simulado; falta criar o projeto Supabase (ver abaixo). Sem Supabase, os comentários ficam só no dispositivo |
| Domínio próprio | angolive.net escolhido; falta comprar e configurar (ver abaixo) |
| Política de privacidade | Escrita, por publicar (falta confirmar o email de contacto) |

## Estrutura

```
angolive-complete.html   App completa num só ficheiro (HTML + CSS + JS, sem dependências)
index.html               Redireciona para angolive-complete.html (mantém #local-N)
manifest.json            Manifesto PWA (start_url ./angolive-complete.html)
sw.js                    Service worker: network-first para o site, cache-first para fotos Unsplash
icon-192.png, icon-512.png, apple-touch-icon.png
privacy.html             Política de privacidade PT/EN (por publicar: falta o email)
supabase/setup.sql       Base de dados dos comentários, fotos e vídeos dos visitantes
ios/                     Projeto Xcode (SwiftUI + WKWebView)
  ANGOLIVE.xcodeproj
  ANGOLIVE/AngoliveApp.swift
  ANGOLIVE/angolive-complete.html   Cópia local da app, para funcionar offline
  ANGOLIVE/Assets.xcassets          Ícone 1024x1024 sem transparência
```

## Como funciona a app web

- Os dados dos locais e menus estão no próprio ficheiro: `const venues` (32 locais) e `const menuData`.
- Página inicial (por esta ordem): título e pesquisa "O que procura? / Onde?", filtros rápidos, Perto de si, Recomendados (com o motivo), Explorar por categoria, Coleções e Verificados recentemente. Pesquisa, filtros, categorias e coleções abrem a vista de resultados.
- Campos de cada local: `type` (restaurant, beach, culture, nature, nightclub, accommodation, exchange), `highlight` (destaque útil PT/EN, também usado como motivo das recomendações), `family` (sugestão editorial para famílias), `address`, `hours` (horário por dia da semana, 0 = domingo, hora de Angola), `verified` (data e fontes da verificação; `stale` quando as fontes têm alguns anos).
- O estado "Aberto/Fechado" só aparece com horário confirmado. O filtro "Aberto agora" aparece automaticamente quando pelo menos 8 locais tiverem `hours` (`MIN_PLACES_WITH_HOURS`). Hoje só a Fortaleza de São Miguel tem horário com fonte.
- Recomendados, coleções e cidades: `RECOMMENDED`, `COLLECTIONS`, `CITIES`.
- O detalhe mostra primeiro a informação prática (horário, morada, mapa, preço, contacto, o que falta confirmar e quando foi verificado) e só depois a descrição.
- `exact: true` indica coordenadas confirmadas na Wikipedia/Wikidata. Nos restantes, "Como chegar" e "Ver no mapa" pesquisam o nome do local no Google Maps, e as coordenadas só servem para calcular distâncias aproximadas.
- `photos`: fotos reais do Wikimedia Commons, com autor e licença (mostrados na app, como as licenças CC BY/CC BY-SA exigem). Locais sem `photos` usam `image`, uma foto ilustrativa do Unsplash, com a etiqueta "Foto ilustrativa".
- Português por defeito, com botão para Inglês. Os textos estão em `I18N`; as traduções das descrições estão em `DESC_EN` e `MENU_DESC_EN`.
- Perfil, favoritos, comentários, idioma e tema ficam no `localStorage` do dispositivo. Não há servidor.
- "Perto de mim" usa `navigator.geolocation` apenas no dispositivo.
- Links diretos para um local: `angolive-complete.html#local-<id>`.
- Pedido do dono: sem emojis no design; os ícones são SVG inline (`ICONS`).

Para correr localmente:

```bash
python3 -m http.server 8000
```

e abrir http://localhost:8000/

## App iPhone (`ios/`)

- SwiftUI com um `WKWebView` que carrega `ANGOLIVE/angolive-complete.html` do bundle (`file://`).
- Links externos (Google Maps, WhatsApp, YouTube...) abrem nas apps do sistema.
- Dentro da app (`file://`), o aviso "instalar" não aparece e o botão Partilhar usa `PUBLIC_URL`.
- Bundle ID: `com.angolive.app` (alterar se necessário). iOS 16+.
- Sempre que se alterar `angolive-complete.html`, é preciso copiá-lo também para `ios/ANGOLIVE/`.

## Comentários, fotos e vídeos dos visitantes (Supabase)

1. Criar uma conta gratuita em https://supabase.com e um projeto novo.
2. Em **SQL Editor**, colar e correr `supabase/setup.sql`.
3. Em **Project Settings > API**, copiar o Project URL e a chave pública (publishable/anon) para `SUPABASE_URL` e `SUPABASE_KEY` em `angolive-complete.html` (e na cópia em `ios/ANGOLIVE/`). Esta chave é pública por natureza; a segurança vem das regras RLS do `setup.sql`. Nunca usar a chave `service_role` na app.
4. Moderação: em **Table Editor > reviews** (comentários) e **submissions** (fotos e vídeos), mudar `status` para `approved` para publicar, ou `rejected` para recusar. Com 3 denúncias fica `hidden` automaticamente.

As estrelas de cada local são a média dos comentários aprovados (vista `review_stats`). Tocar na nota leva à secção de comentários, que também tem ligações para as avaliações no Google Maps e no TripAdvisor.

As fotos são comprimidas na app (máx. 1600 px, JPEG) antes de enviar. Os vídeos entram como link do YouTube, TikTok ou Instagram.

## Domínio angolive.net

Não adicionar o domínio no GitHub antes de o comprar e configurar o DNS: o endereço kingic17.github.io passaria a redirecionar para um domínio que ainda não funciona.

1. Comprar `angolive.net` (ex.: Cloudflare, Namecheap, Porkbun).
2. No DNS do domínio, criar:
   - 4 registos `A` para `@`: `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
   - 1 registo `CNAME` para `www` → `kingic17.github.io`
3. No GitHub: **Settings > Pages > Custom domain** → `angolive.net` → Save. Depois de verificado, ativar **Enforce HTTPS**.
4. Recomendado: verificar o domínio na conta GitHub (**Settings > Pages > Verified domains**) para ninguém o poder usar noutro repositório.
5. Atualizar `PUBLIC_URL` em `angolive-complete.html` (e na cópia em `ios/`) para `https://angolive.net/angolive-complete.html`.

## O que falta fazer

1. **Contas** (dono): Apple Developer Program e Google Play Console.
2. **Domínio próprio**: configurar o custom domain no GitHub Pages e os registos DNS, e atualizar `PUBLIC_URL` em `angolive-complete.html`.
3. **Android**: gerar o pacote AAB como Trusted Web Activity (PWABuilder ou Bubblewrap) e publicar `/.well-known/assetlinks.json` no domínio (com `.nojekyll` na raiz do repositório). As contas pessoais novas da Google Play exigem um teste fechado com 12 testadores durante 14 dias.
4. **iPhone**: build, testes, capturas de ecrã e submissão. Atenção à regra 4.2 da Apple ("minimum functionality"): apps que só mostram um site podem ser recusadas.
5. **Política de privacidade**: publicar `privacy.html` assim que o email de contacto estiver confirmado, e ligá-la a partir da app e das fichas das lojas.
6. **Dados por confirmar** (verificação feita em outubro de 2026 com Wikipedia e o guia Ver Angola):
   - Confirmados como existentes: Café del Mar (Ilha de Luanda), O Madeirense (Liga Africana), Lookal Mar e Lookal Beach Club (Ilha do Cabo), EPIC SANA Luanda, NovaCâmbios, Batuk (Restinga do Lobito), Hotel Serra da Chela. Miami Beach, Chill Out e Coconuts vêm de artigos de 2015 a 2021: confirmar se continuam abertos.
   - Removidos por não haver fontes: "Caminito Night Club" e "Messe Hotel Huila" (substituído pelo Hotel Serra da Chela). "Lookal Ocean Club" passou a "Lookal Mar".
   - As estrelas inventadas foram removidas (outubro de 2026). Agora só aparecem estrelas calculadas a partir de comentários reais.
   - Os telefones foram removidos até serem confirmados (campo `phone` vazio); os botões Ligar e WhatsApp só aparecem quando há número.
   - Os preços dos menus e algumas descrições ainda não foram confirmados com os locais.
   - As fotos são ilustrativas (Unsplash), não são dos próprios locais.
7. **Comentários partilhados**: hoje só ficam no dispositivo de quem os escreve. Para todos verem os comentários, é preciso um backend (ex.: Supabase ou Firebase).

## Problema conhecido no Mac do dono

O Xcode 26.5 falha ao compilar com um erro de bibliotecas do sistema (`CoreDevice` / `Mercury`: `Symbol not found: _XPCTypeBool`). Provável desencontro entre as versões do macOS e do Xcode. Tentar `sudo xcodebuild -runFirstLaunch` ou atualizar o macOS e o Xcode.
