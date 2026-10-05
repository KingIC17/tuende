# ANGOLIVE

Guia de Angola: restaurantes, festas e nightclubs, beach clubs, alojamento, turismo e câmbio, com preços em Kwanza.

- Site: https://kingic17.github.io/ANGOLIVE/
- Objetivo: publicar como site, na Google Play (Android) e na App Store (iPhone).

## Estado atual (5 de outubro de 2026)

| Parte | Estado |
|---|---|
| Site (web app) | Online no GitHub Pages |
| App instalável (PWA) | `manifest.json` e `sw.js` publicados; modo offline ainda não testado num browser real |
| App iPhone (`ios/`) | Projeto Xcode criado; o código Swift passa o `swiftc -typecheck`, mas o build completo e o simulador ainda não foram testados |
| App Android | Por fazer (depende do domínio próprio) |
| Política de privacidade | Escrita, por publicar (falta confirmar o email de contacto) |

## Estrutura

```
angolive-complete.html   App completa num só ficheiro (HTML + CSS + JS, sem dependências)
index.html               Redireciona para angolive-complete.html (mantém #local-N)
manifest.json            Manifesto PWA (start_url ./angolive-complete.html)
sw.js                    Service worker: network-first para o site, cache-first para fotos Unsplash
icon-192.png, icon-512.png, apple-touch-icon.png
ios/                     Projeto Xcode (SwiftUI + WKWebView)
  ANGOLIVE.xcodeproj
  ANGOLIVE/AngoliveApp.swift
  ANGOLIVE/angolive-complete.html   Cópia local da app, para funcionar offline
  ANGOLIVE/Assets.xcassets          Ícone 1024x1024 sem transparência
```

## Como funciona a app web

- Os dados dos locais e menus estão no próprio ficheiro: `const venues` e `const menuData`.
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

## O que falta fazer

1. **Contas** (dono): Apple Developer Program e Google Play Console.
2. **Domínio próprio**: configurar o custom domain no GitHub Pages e os registos DNS, e atualizar `PUBLIC_URL` em `angolive-complete.html`.
3. **Android**: gerar o pacote AAB como Trusted Web Activity (PWABuilder ou Bubblewrap) e publicar `/.well-known/assetlinks.json` no domínio (com `.nojekyll` na raiz do repositório). As contas pessoais novas da Google Play exigem um teste fechado com 12 testadores durante 14 dias.
4. **iPhone**: build, testes, capturas de ecrã e submissão. Atenção à regra 4.2 da Apple ("minimum functionality"): apps que só mostram um site podem ser recusadas.
5. **Política de privacidade**: publicar `privacy.html` assim que o email de contacto estiver confirmado, e ligá-la a partir da app e das fichas das lojas.
6. **Dados por confirmar**:
   - Os telefones foram removidos até serem confirmados (campo `phone` vazio); os botões Ligar e WhatsApp só aparecem quando há número.
   - Os preços dos menus e algumas descrições ainda não foram confirmados com os locais.
   - As fotos são ilustrativas (Unsplash), não são dos próprios locais.
7. **Comentários partilhados**: hoje só ficam no dispositivo de quem os escreve. Para todos verem os comentários, é preciso um backend (ex.: Supabase ou Firebase).

## Problema conhecido no Mac do dono

O Xcode 26.5 falha ao compilar com um erro de bibliotecas do sistema (`CoreDevice` / `Mercury`: `Symbol not found: _XPCTypeBool`). Provável desencontro entre as versões do macOS e do Xcode. Tentar `sudo xcodebuild -runFirstLaunch` ou atualizar o macOS e o Xcode.
