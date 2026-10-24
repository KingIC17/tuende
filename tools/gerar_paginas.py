#!/usr/bin/env python3
"""Gera uma página por lugar (web/lugares/<nome>.html), os guias por tema (web/lugares/<guia>.html), a agenda
(web/agenda/index.html), o câmbio do dia (web/cambio/index.html), a lista de lugares, o sitemap.xml e o robots.txt.

Os dados vêm de web/index.html (const venues, DESC_EN, EVENTS, FX_CODES e FX_FALLBACK), por isso basta voltar a
correr este script depois de mudar ou acrescentar lugares ou eventos:

    python3 tools/gerar_paginas.py

Estas páginas servem para o Google mostrar cada lugar nos resultados e para o WhatsApp e as redes
sociais mostrarem a foto e o nome do lugar quando alguém partilha o link. A app continua a ser a
página principal; cada página tem um botão para abrir o lugar na app.
"""
import html
import json
import re
import subprocess
import unicodedata
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / 'web'
SITE = 'https://tuende.app/'

CATEGORY = {
    'restaurant': ('Restaurante', 'Restaurant', 'Restaurant'),
    'bar': ('Bar', 'Bar', 'BarOrPub'),
    'nightclub': ('Discoteca', 'Club', 'NightClub'),
    'beach': ('Praia', 'Beach', 'Beach'),
    'culture': ('Cultura e monumentos', 'Culture and landmarks', 'TouristAttraction'),
    'museum': ('Museu', 'Museum', 'Museum'),
    'nature': ('Natureza', 'Nature', 'TouristAttraction'),
    'accommodation': ('Alojamento', 'Accommodation', 'LodgingBusiness'),
    'shopping': ('Centro comercial', 'Shopping centre', 'ShoppingCenter'),
    'plaza': ('Praça e passeio', 'Square and promenade', 'TouristAttraction'),
    'sport': ('Desporto', 'Sport', 'SportsActivityLocation'),
    'transport': ('Transporte', 'Transport', 'Place'),
    'services': ('Câmbio', 'Exchange', 'LocalBusiness'),
    'health': ('Saúde', 'Health', 'MedicalClinic'),
}
# Places without a photo get a banner in the category colour with the category icon, as in the app (placeholderHTML).
PH_GROUP = {'restaurant': 'food', 'bar': 'food', 'nightclub': 'night', 'beach': 'beach', 'nature': 'nature',
            'culture': 'culture', 'museum': 'culture', 'plaza': 'culture'}
PH_STYLE = """
    <style>
        .ph { display: flex; align-items: center; justify-content: center; margin-top: 14px; aspect-ratio: 16 / 7; border-radius: 16px; background-size: 28px 28px, auto; }
        .ph svg { width: 56px; height: 56px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
        .ph-food { color: #FFFFFF; background-image: var(--dw), linear-gradient(135deg, #CE1126, #A50E1F); }
        .ph-beach { color: #FFFFFF; background-image: var(--dw), linear-gradient(135deg, #1D4E89, #163C6A); }
        .ph-nature { color: #FFFFFF; background-image: var(--dw), linear-gradient(135deg, #1E6B3A, #15502B); }
        .ph-culture { color: #111111; background-image: var(--dd), linear-gradient(135deg, #FFCB00, #E8B400); }
        .ph-night { color: #FFFFFF; background-image: var(--dy), linear-gradient(135deg, #2B2B33, #111111); }
        .ph-light { color: var(--primary); background-image: var(--dr), linear-gradient(var(--surface), var(--surface)); box-shadow: inset 0 0 0 1.5px var(--line); }
        .ph { --dw: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='28' height='28'%3E%3Cpath d='M14 4 24 14 14 24 4 14z' fill='none' stroke='white' stroke-opacity='0.14' stroke-width='1.5'/%3E%3C/svg%3E");
              --dd: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='28' height='28'%3E%3Cpath d='M14 4 24 14 14 24 4 14z' fill='none' stroke='%23111111' stroke-opacity='0.10' stroke-width='1.5'/%3E%3C/svg%3E");
              --dy: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='28' height='28'%3E%3Cpath d='M14 4 24 14 14 24 4 14z' fill='none' stroke='%23FFCB00' stroke-opacity='0.22' stroke-width='1.5'/%3E%3C/svg%3E");
              --dr: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='28' height='28'%3E%3Cpath d='M14 4 24 14 14 24 4 14z' fill='none' stroke='%23CE1126' stroke-opacity='0.14' stroke-width='1.5'/%3E%3C/svg%3E"); }
    </style>"""
APP_ICONS = {}  # type -> SVG inner markup, read from index.html (ICONS and CATEGORY) in main


def load_icons():
    source = (WEB / 'index.html').read_text(encoding='utf-8')
    def literal(name):
        start = source.index('{', source.index(f'const {name} = {{'))
        return js_value(source[start:source.index('\n        };', start) + len('\n        }')])
    icons, categories = literal('ICONS'), literal('CATEGORY')
    return {k: icons[c['icon']] for k, c in categories.items() if c.get('icon') in icons}


def adds_to(lead, text):
    """True when the lead line says something the description does not already say (fewer than 60% of its words repeated)."""
    lw = {w for w in words(lead) if len(w) > 3}
    if not lw:
        return False
    tw = set(words(text))
    return len(lw & tw) / len(lw) < 0.6


DAYS = [(1, 'Segunda'), (2, 'Terça'), (3, 'Quarta'), (4, 'Quinta'), (5, 'Sexta'), (6, 'Sábado'), (0, 'Domingo')]
MONTHS = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro']


def pt_date(iso):
    if not iso:
        return 'data por confirmar'
    y, m, d = (int(x) for x in iso.split('-'))
    return f'{d} de {MONTHS[m - 1]} de {y}'


PER = {'person': 'por pessoa', 'night': 'por noite', 'entry': 'de entrada', 'trip': 'por viagem', 'month': 'por mês'}


def slug(name):
    """O mesmo cálculo que placeSlug() na app: sem acentos, minúsculas, só letras, números e hífenes."""
    plain = unicodedata.normalize('NFD', name)
    plain = ''.join(c for c in plain if not unicodedata.combining(c)).lower()
    return re.sub(r'[^a-z0-9]+', '-', plain).strip('-')


def load():
    source = (WEB / 'index.html').read_text(encoding='utf-8')
    start = source.index('const venues = [')
    end = source.index('\n        ];', start)
    venues = [json.loads(line.strip().rstrip(',')) for line in source[start:end].split('\n')[1:] if line.strip().startswith('{')]
    start = source.index('const DESC_EN = {')
    end = source.index('\n        };', start)
    desc_en = {int(k): json.loads(v) for k, v in re.findall(r'^ {12}(\d+): ("(?:[^"\\]|\\.)*"),?$', source[start:end], re.M)}
    return venues, desc_en


def e(text):
    return html.escape(str(text), quote=True)


def kz(value):
    return f'{value:,}'.replace(',', ' ')


def price_text(v):
    p = v.get('price')
    if not p:
        return 'Preço por confirmar'
    if p.get('free'):
        return 'Entrada gratuita'
    if p.get('text'):
        return p['text']['pt']
    amount = f"{kz(p['from'])}–{kz(p['to'])} Kz" if p.get('to') else f"{kz(p['from'])} Kz"
    text = ' '.join(filter(None, [amount, PER.get(p.get('per'), '')]))
    return f'{text} (valor indicativo)' if p.get('estimate') else text


def hours_lines(v):
    if v.get('hours'):
        rows = []
        for day, name in DAYS:
            spans = v['hours'].get(str(day))
            rows.append((name, ', '.join(f'{a}–{b}' for a, b in spans) if spans else 'Fechado'))
        return rows
    if v.get('hoursText'):
        return [('', v['hoursText']['pt'])]
    return [('', 'Por confirmar')]


def place_line(v):
    city, _, area = v['location'].partition(' - ')
    return f'{area}, {city}' if area and area != city else city


def photo_of(v):
    if v.get('photos'):
        p = v['photos'][0]
        label = 'Foto ilustrativa' if p.get('illustrative') else 'Foto'
        caption = f"{e(p['caption']['pt'])} · " if p.get('illustrative') and p.get('caption') else ''
        return {'src': p['url'], 'credit': f"{label}: {caption}<a href=\"{e(p['page'])}\">{e(p['author'])}</a> · {e(p['license'])} · Wikimedia Commons", 'focus': p.get('focus', '')}
    if v.get('image'):
        return {'src': v['image'], 'credit': 'Foto ilustrativa (Unsplash)', 'focus': ''}
    return None


def maps_url(v):
    if v.get('exact'):
        return f"https://www.google.com/maps/dir/?api=1&destination={v['lat']},{v['lng']}"
    from urllib.parse import quote
    return f"https://www.google.com/maps/search/?api=1&query={quote(v['name'] + ', ' + v['location'] + ', Angola')}"


STYLE = """
        @font-face { font-family: 'Plus Jakarta Sans'; font-style: normal; font-weight: 400 800; font-display: swap; src: url('../fonts/plus-jakarta-sans-latin.woff2') format('woff2'); }
        :root { --primary: #CE1126; --fill: #CE1126; --bg: #FFFFFF; --surface: #F3F3F5; --text: #161618; --muted: #55555D; --line: #E4E4E8; color-scheme: light; }
        @media (prefers-color-scheme: dark) { :root { --primary: #FF6B7A; --bg: #0E0E10; --surface: #1A1A1F; --text: #F2F2F4; --muted: #B4B4BC; --line: #2E2E35; color-scheme: dark; } }
        * { box-sizing: border-box; margin: 0; }
        body { background: var(--bg); color: var(--text); font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; font-size: 17px; line-height: 1.55; }
        .strip { height: 8px; background: repeating-linear-gradient(135deg, #CE1126 0 10px, #FFCB00 10px 20px); }
        header, main, footer { max-width: 760px; margin: 0 auto; padding: 0 16px; }
        header { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding-top: 14px; padding-bottom: 14px; border-bottom: 1px solid var(--line); }
        .brand { color: var(--primary); font-weight: 800; font-size: 22px; text-decoration: none; }
        .crumbs { font-size: 14px; color: var(--muted); margin-top: 18px; }
        .crumbs a { color: var(--muted); }
        figure { margin-top: 14px; }
        figure img { display: block; width: 100%; height: auto; aspect-ratio: 16 / 9; object-fit: cover; border-radius: 16px; background: var(--surface); }
        figcaption { font-size: 13px; color: var(--muted); margin-top: 6px; }
        figcaption a, .sources a, footer a { color: inherit; }
        .kicker { margin-top: 18px; color: var(--primary); font-size: 13px; font-weight: 700; letter-spacing: 0.04em; text-transform: uppercase; }
        h1 { font-size: 32px; line-height: 1.15; margin-top: 4px; }
        .lead { font-size: 19px; margin-top: 8px; }
        p { margin-top: 12px; }
        .actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 20px; }
        .btn { display: inline-flex; align-items: center; justify-content: center; min-height: 48px; padding: 0 20px; border-radius: 12px; font-weight: 700; text-decoration: none; border: 1.5px solid var(--fill); color: var(--primary); }
        .btn.solid { background: var(--fill); color: #fff; }
        h2 { font-size: 20px; margin-top: 28px; color: var(--primary); }
        dl { margin-top: 10px; border: 1px solid var(--line); border-radius: 14px; }
        dl > div { display: grid; grid-template-columns: 130px 1fr; gap: 10px; padding: 12px 14px; }
        dl > div + div { border-top: 1px solid var(--line); }
        dt { font-weight: 700; }
        dd { color: var(--muted); margin: 0; }
        .hours { display: grid; grid-template-columns: auto 1fr; gap: 2px 14px; }
        .muted, .sources { color: var(--muted); font-size: 15px; }
        ul.links { margin-top: 10px; padding-left: 18px; }
        ul.links li { margin-top: 4px; }
        ul.links a { color: var(--primary); font-weight: 600; }
        section[lang="en"] { margin-top: 32px; padding-top: 18px; border-top: 1px solid var(--line); }
        footer { margin-top: 40px; padding-top: 18px; padding-bottom: 40px; border-top: 1px solid var(--line); color: var(--muted); font-size: 14px; }
        @media (max-width: 600px) { h1 { font-size: 27px; } dl > div { grid-template-columns: 1fr; gap: 2px; } }
"""


def page(v, others, desc_en, near=(), events=()):
    name = v['name']
    cat_pt, cat_en, schema_type = CATEGORY[v['type']]
    if v['type'] == 'health' and v['name'].startswith('Hospital'):
        schema_type = 'Hospital'
    where = place_line(v)
    s = slug(name)
    url = f'{SITE}lugares/{s}.html'
    photo = photo_of(v)
    image = f"{SITE}{photo['src']}" if photo else f'{SITE}og-image.jpg'
    highlight = v.get('highlight', {}).get('pt', '')
    description = f'{highlight} {cat_pt} em {where}, Angola: horário, preço e como chegar.'.strip()
    title = f'{name} ({where}) | Tuende'
    data = {
        '@context': 'https://schema.org', '@type': schema_type, 'name': name, 'description': v['description'],
        'url': url, 'image': image,
        'address': {'@type': 'PostalAddress', 'streetAddress': v.get('address') or where, 'addressCountry': 'AO'},
    }
    if v.get('exact'):
        data['geo'] = {'@type': 'GeoCoordinates', 'latitude': v['lat'], 'longitude': v['lng']}
    sources = v.get('verified', {}).get('sources', [])
    checked = v.get('verified', {}).get('date', '')
    hours_note = v.get('hoursNote', {}).get('pt', '') if v.get('hours') else ''
    facts = [('Horário', ''.join(f'<span>{e(d)}</span><span>{e(h)}</span>' if d else f'<span>{e(h)}</span>' for d, h in hours_lines(v)))]
    facts.append(('Morada', e(v.get('address') or where)))
    price = price_text(v)
    note = v.get('price', {}).get('note', {}).get('pt') if v.get('price') else ''
    facts.append(('Preço', e(price) + (f'<br>{e(note)}' if note else '')))
    facts_html = '\n'.join(
        f'            <div><dt>{label}</dt><dd>{f"<div class=\"hours\">{value}</div>" + (f"<p class=\"muted\">{e(hours_note)}</p>" if hours_note else "") if label == "Horário" and v.get("hours") else value}</dd></div>'
        for label, value in facts)
    others_html = '\n'.join(f'            <li><a href="{slug(o["name"])}.html">{e(o["name"])}</a> · {e(place_line(o))}</li>' for o in others)
    # Próximos eventos neste lugar; os que já acabaram saem sozinhos (script), até a página voltar a ser gerada.
    events_html = ''
    if events:
        items = '\n'.join(f'            <li data-end="{e(ev.get("end") or ev["start"])}"><a href="../agenda/#{e(ev["id"])}">{e(ev["title"]["pt"])}</a> · {e(event_dates(ev["start"], ev.get("end")))}</li>' for ev in events)
        events_html = (f'{chr(10)}        <section id="eventos-aqui">{chr(10)}        <h2>Próximos eventos aqui</h2>{chr(10)}        <ul class="links">{chr(10)}{items}{chr(10)}        </ul>{chr(10)}'
                       '        <script>(function(){var d=new Date().toISOString().slice(0,10),s=document.getElementById("eventos-aqui");'
                       's.querySelectorAll("[data-end]").forEach(function(li){if(li.getAttribute("data-end")<d)li.remove();});'
                       'if(!s.querySelector("[data-end]"))s.remove();})();</script>' + chr(10) + '        </section>')
    near_html = '\n'.join(f'            <li><a href="{slug(o["name"])}.html">{e(o["name"])}</a> · {e(CATEGORY[o["type"]][0])} · {f"{d:.1f}".replace(".", ",")} km</li>' for d, o in near)
    focus = f' style="object-position: {photo["focus"]}"' if photo and photo['focus'] else ''
    rates_note = ('\n        <p class="muted">Antes de trocar, veja o <a href="../cambio/">câmbio do dia</a> (taxas de referência do Banco Nacional de Angola).</p>'
                  if v['type'] == 'services' else '')
    figure = f'''        <figure>
            <img src="../{e(photo['src'])}" alt="{e(name)}" width="960" height="540"{focus}>
            <figcaption>{photo['credit']}</figcaption>
        </figure>''' if photo else ''
    if not photo and APP_ICONS.get(v['type']):
        group = PH_GROUP.get(v['type'], 'light')
        figure = f'        <div class="ph ph-{group}" aria-hidden="true"><svg viewBox="0 0 24 24">{APP_ICONS[v["type"]]}</svg></div>'
    return f'''<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{e(title)}</title>
    <meta name="description" content="{e(description)}">
    <link rel="canonical" href="{url}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Tuende">
    <meta property="og:locale" content="pt_PT">
    <meta property="og:title" content="{e(name)} · {e(where)}">
    <meta property="og:description" content="{e(highlight or description)}">
    <meta property="og:url" content="{url}">
    <meta property="og:image" content="{e(image)}">
    <meta property="og:image:alt" content="{e(name)}">
    <meta name="twitter:card" content="summary_large_image">
    <meta name="theme-color" content="#CE1126">
    <link rel="icon" type="image/png" href="../icon-192.png">
    <script type="application/ld+json">{json.dumps(data, ensure_ascii=False).replace("</", "<\\/")}</script>
    <style>{STYLE}    </style>{PH_STYLE if not photo and APP_ICONS.get(v['type']) else ''}
</head>
<body>
    <div class="strip" aria-hidden="true"></div>
    <header>
        <a class="brand" href="../">Tuende</a>
        <a class="btn solid" href="../#local-{v['id']}">Abrir na app</a>
    </header>
    <main>
        <p class="crumbs"><a href="../">Tuende</a> › <a href="./">Lugares</a> › {e(where.split(', ')[-1])}</p>
{figure}
        <p class="kicker">{e(cat_pt)} · {e(where)}</p>
        <h1>{e(name)}</h1>
        {f'<p class="lead">{e(highlight)}</p>' if highlight and adds_to(highlight, v['description']) else ''}
        <p>{e(v['description'])}</p>{rates_note}
        <div class="actions">
            <a class="btn solid" href="../#local-{v['id']}">Ver no Tuende</a>
            <a class="btn" href="{e(maps_url(v))}">Como chegar</a>
        </div>

        <h2>Informação prática</h2>
        <dl>
{facts_html}
        </dl>
        <p class="sources">Verificado a {e(pt_date(checked))}. Fontes: {', '.join(f'<a href="{e(src["url"])}">{e(src["label"])}</a>' for src in sources) or 'por confirmar'}. Confirme sempre antes de ir.</p>

        {f'<h2>Perto daqui</h2>{chr(10)}        <ul class="links">{chr(10)}{near_html}{chr(10)}        </ul>{chr(10)}        <p class="muted">Distâncias em linha reta{"" if v.get("exact") else "; a posição deste lugar é aproximada"}.</p>' if near else ''}{events_html}

        {f'<h2>Mais lugares em {e(where.split(", ")[-1])}</h2>' if others else ''}
        {f'<ul class="links">{chr(10)}{others_html}{chr(10)}        </ul>' if others else ''}

        <section lang="en">
            <h2>{e(name)} — {e(cat_en)}, {e(where)}</h2>
            {f'<p>{e(v.get("highlight", {}).get("en", ""))}</p>' if v.get('highlight', {}).get('en') else ''}
            <p>{e(desc_en.get(v['id'], ''))}</p>
            <p class="muted">Prices in Kwanza, opening hours and directions are in the <a href="../#local-{v['id']}">Tuende app</a> (Portuguese and English).</p>
        </section>
    </main>
    <footer>
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="./">Todos os lugares</a> · <a href="../sobre/">Sobre o Tuende</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
</body>
</html>
'''


# Estilo extra das páginas de guias, da agenda e da lista de lugares (as páginas de cada lugar não o usam).
EXTRA_STYLE = """
        .guides { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; padding: 0; list-style: none; }
        .guides a { display: inline-block; padding: 8px 14px; border: 1px solid var(--line); border-radius: 999px; color: var(--text); text-decoration: none; font-size: 15px; font-weight: 600; }
        .items { list-style: none; padding: 0; margin-top: 12px; display: grid; gap: 12px; }
        .item { display: grid; grid-template-columns: 96px 1fr; gap: 14px; padding: 12px; border: 1px solid var(--line); border-radius: 14px; }
        .item.text-only { grid-template-columns: 1fr; }
        .item img { width: 96px; height: 96px; object-fit: cover; border-radius: 10px; background: var(--surface); }
        .item h3 { font-size: 18px; line-height: 1.3; }
        .item h3 a { color: var(--text); }
        .item .meta, .item .credit { color: var(--muted); font-size: 14px; margin-top: 2px; }
        .item .credit a { color: inherit; }
        .item p { margin-top: 6px; }
        .item .links { margin-top: 8px; display: flex; flex-wrap: wrap; gap: 6px 16px; font-size: 15px; }
        .item .links a { color: var(--primary); font-weight: 600; }
        .item ul { margin-top: 6px; padding-left: 18px; color: var(--muted); font-size: 15px; }
        @media (max-width: 600px) { .item { grid-template-columns: 72px 1fr; } .item img { width: 72px; height: 72px; } }
"""

PLURAL = {
    'restaurant': 'Restaurantes', 'bar': 'Bares', 'nightclub': 'Discotecas', 'beach': 'Praias', 'culture': 'Cultura e monumentos',
    'museum': 'Museus', 'nature': 'Natureza', 'accommodation': 'Alojamento', 'shopping': 'Centros comerciais', 'plaza': 'Praças e passeios',
    'sport': 'Desporto', 'transport': 'Transportes', 'services': 'Câmbio',
    'health': 'Saúde e hospitais',
}
TYPE_ORDER = ['culture', 'museum', 'nature', 'beach', 'plaza', 'restaurant', 'bar', 'nightclub', 'accommodation', 'shopping', 'sport', 'services', 'health', 'transport']


def province(v):
    return v['location'].split(' - ')[0]


# Guias por tema: cada um junta lugares que já estão na app, para o Google os mostrar a quem procura,
# por exemplo, "o que fazer em Luanda". group = 'type' agrupa por categoria; 'province' agrupa por província.
TOPICS = [
    {'slug': 'o-que-fazer-em-luanda', 'title': 'O que fazer em Luanda', 'en': 'Things to do in Luanda', 'group': 'type',
     'pick': lambda v: province(v) == 'Luanda' and v['type'] in ('culture', 'museum', 'plaza', 'beach', 'nature'),
     'what': 'lugares para visitar em Luanda: monumentos, museus, praças, praias e paisagens',
     'what_en': 'places to visit in Luanda: landmarks, museums, squares, beaches and landscapes'},
    {'slug': 'restaurantes-bares-e-discotecas-em-luanda', 'title': 'Restaurantes, bares e discotecas em Luanda', 'en': 'Restaurants, bars and clubs in Luanda', 'group': 'type',
     'pick': lambda v: province(v) == 'Luanda' and v['type'] in ('restaurant', 'bar', 'nightclub'),
     'what': 'restaurantes, bares e discotecas em Luanda', 'what_en': 'restaurants, bars and clubs in Luanda'},
    {'slug': 'centros-comerciais-em-luanda', 'title': 'Centros comerciais em Luanda', 'en': 'Shopping centres in Luanda', 'group': 'type',
     'pick': lambda v: province(v) == 'Luanda' and v['type'] == 'shopping',
     'what': 'centros comerciais (shoppings) em Luanda', 'what_en': 'shopping centres in Luanda'},
    {'slug': 'desporto-e-ginasios-em-luanda', 'title': 'Desporto e ginásios em Luanda', 'en': 'Sport and gyms in Luanda', 'group': 'type',
     'pick': lambda v: province(v) == 'Luanda' and v['type'] == 'sport',
     'what': 'ginásios, piscinas e recintos desportivos em Luanda', 'what_en': 'gyms, pools and sports venues in Luanda'},
    {'slug': 'o-que-fazer-em-benguela', 'title': 'O que fazer em Benguela e no Lobito', 'en': 'Things to do in Benguela and Lobito', 'group': 'type',
     'pick': lambda v: province(v) == 'Benguela', 'what': 'lugares na província de Benguela (Benguela, Lobito, Catumbela e arredores)',
     'what_en': 'places in Benguela province (Benguela, Lobito, Catumbela and around)'},
    {'slug': 'o-que-fazer-no-lubango-e-na-huila', 'title': 'O que fazer no Lubango e na Huíla', 'en': 'Things to do in Lubango and Huíla', 'group': 'type',
     'pick': lambda v: province(v) == 'Huíla', 'what': 'lugares na província da Huíla, a maioria no Lubango', 'what_en': 'places in Huíla province, most of them in Lubango'},
    {'slug': 'o-que-fazer-no-huambo', 'title': 'O que fazer no Huambo', 'en': 'Things to do in Huambo', 'group': 'type',
     'pick': lambda v: province(v) == 'Huambo', 'what': 'lugares na província do Huambo', 'what_en': 'places in Huambo province'},
    {'slug': 'o-que-fazer-em-cabinda', 'title': 'O que fazer em Cabinda', 'en': 'Things to do in Cabinda', 'group': 'type',
     'pick': lambda v: province(v) == 'Cabinda', 'what': 'lugares na província de Cabinda', 'what_en': 'places in Cabinda province'},
    {'slug': 'o-que-fazer-no-namibe', 'title': 'O que fazer no Namibe (Moçâmedes)', 'en': 'Things to do in Namibe (Moçâmedes)', 'group': 'type',
     'pick': lambda v: province(v) == 'Namibe', 'what': 'lugares na província do Namibe', 'what_en': 'places in Namibe province'},
    {'slug': 'o-que-fazer-em-malanje', 'title': 'O que fazer em Malanje', 'en': 'Things to do in Malanje', 'group': 'type',
     'pick': lambda v: province(v) == 'Malanje', 'what': 'lugares na província de Malanje', 'what_en': 'places in Malanje province'},
    {'slug': 'praias-de-angola', 'title': 'Praias de Angola', 'en': 'Beaches in Angola', 'group': 'province',
     'pick': lambda v: v['type'] == 'beach', 'what': 'praias em Angola, de Luanda a Cabinda e ao Namibe', 'what_en': 'beaches in Angola'},
    {'slug': 'parques-nacionais-de-angola', 'title': 'Parques nacionais de Angola', 'en': 'National parks of Angola', 'group': 'province',
     'pick': lambda v: v['name'].startswith('Parque Nacional'), 'what': 'parques nacionais de Angola', 'what_en': 'national parks in Angola'},
    {'slug': 'natureza-em-angola', 'title': 'Natureza e paisagens de Angola', 'en': 'Nature and landscapes of Angola', 'group': 'province',
     'pick': lambda v: v['type'] == 'nature', 'what': 'lugares de natureza em Angola: quedas de água, serras, lagoas, florestas e parques',
     'what_en': 'nature spots in Angola: waterfalls, mountains, lagoons, forests and parks'},
    {'slug': 'museus-de-angola', 'title': 'Museus de Angola', 'en': 'Museums in Angola', 'group': 'province',
     'pick': lambda v: v['type'] == 'museum', 'what': 'museus em Angola', 'what_en': 'museums in Angola'},
    {'slug': 'hoteis-em-angola', 'title': 'Hotéis e alojamento em Angola', 'en': 'Hotels and places to stay in Angola', 'group': 'province',
     'pick': lambda v: v['type'] == 'accommodation', 'what': 'hotéis, resorts e pousadas em Angola', 'what_en': 'hotels, resorts and guesthouses in Angola'},
    {'slug': 'transportes-em-angola', 'title': 'Transportes em Angola: aeroportos, comboios e autocarros', 'en': 'Getting around Angola: airports, trains and buses', 'group': 'province',
     'pick': lambda v: v['type'] == 'transport', 'what': 'aeroportos, estações, terminais de autocarros e outros transportes em Angola',
     'what_en': 'airports, railway stations, bus terminals and other transport in Angola'},
    {'slug': 'casas-de-cambio-em-angola', 'title': 'Casas de câmbio em Angola', 'en': 'Currency exchange in Angola', 'group': 'province',
     'pick': lambda v: v['type'] == 'services', 'what': 'casas de câmbio em Angola', 'what_en': 'currency exchange offices in Angola',
     'cta': ('../cambio/', 'Câmbio do dia (BNA)')},
    {'slug': 'hospitais-e-clinicas-em-angola', 'title': 'Hospitais e clínicas em Angola', 'en': 'Hospitals and clinics in Angola', 'group': 'province',
     'pick': lambda v: v['type'] == 'health', 'what': 'hospitais e clínicas em Angola, com urgência e médicos que falam inglês',
     'what_en': 'hospitals and clinics in Angola, with emergency care and English-speaking doctors'},
]


def guides_html(current='', prefix=''):
    # Todas estas páginas ficam um nível abaixo da raiz (lugares/, agenda/, cambio/).
    links = [('agenda', '../agenda/', 'Agenda de eventos'), ('cambio', '../cambio/', 'Câmbio do dia'), ('rotas', '../rotas/', 'Como viajar entre cidades')] + [(t['slug'], f'{prefix}{t["slug"]}.html', t['title']) for t in TOPICS]
    items = '\n'.join(f'            <li><a href="{href}">{e(label)}</a></li>' for key, href, label in links if key != current)
    return f'        <ul class="guides">\n{items}\n        </ul>'


def item_html(v):
    s = slug(v['name'])
    photo = v['photos'][0] if v.get('photos') else None
    price = price_text(v) if v.get('price') else ''
    focus = f' style="object-position: {photo["focus"]}"' if photo and photo.get('focus') else ''
    img = f'<img src="../{e(photo["thumb"])}" alt="{e(v["name"])}" width="96" height="96" loading="lazy"{focus}>' if photo else ''
    credit = f'<p class="credit">Foto: <a href="{e(photo["page"])}">{e(photo["author"])}</a> · {e(photo["license"])}</p>' if photo else ''
    meta = ' · '.join(filter(None, [CATEGORY[v['type']][0], place_line(v), price]))
    return f'''            <li class="item{'' if photo else ' text-only'}">
                {img}
                <div>
                    <h3><a href="{s}.html">{e(v['name'])}</a></h3>
                    <p class="meta">{e(meta)}</p>
                    <p>{e(v.get('highlight', {}).get('pt') or v['description'])}</p>
                    {credit}
                </div>
            </li>'''


def topic_page(topic, items):
    url = f'{SITE}lugares/{topic["slug"]}.html'
    n = len(items)
    title = f'{topic["title"]} | Tuende'
    description = f'{n} {topic["what"]}, com horário, preço em Kwanza (quando conhecido) e como chegar. Cada lugar indica as fontes e a data de verificação.'
    if topic['group'] == 'type':
        groups = [(PLURAL[t], [v for v in items if v['type'] == t]) for t in TYPE_ORDER]
    else:
        provinces = sorted({province(v) for v in items}, key=lambda p: (p != 'Luanda', -sum(1 for v in items if province(v) == p), p))
        groups = [(p, [v for v in items if province(v) == p]) for p in provinces]
    groups = [(label, vs) for label, vs in groups if vs]
    body = '\n'.join(
        (f'        <h2>{e(label)}</h2>\n' if len(groups) > 1 else '') + '        <ul class="items">\n' + '\n'.join(item_html(v) for v in vs) + '\n        </ul>'
        for label, vs in groups)
    data = {'@context': 'https://schema.org', '@type': 'ItemList', 'name': topic['title'], 'url': url, 'numberOfItems': n,
            'itemListElement': [{'@type': 'ListItem', 'position': i, 'url': f'{SITE}lugares/{slug(v["name"])}.html', 'name': v['name']}
                                for i, v in enumerate([v for _, vs in groups for v in vs], 1)]}
    photo = next((v['photos'][0] for _, vs in groups for v in vs if v.get('photos')), None)
    image = f'{SITE}{photo["url"]}' if photo else f'{SITE}og-image.jpg'
    return f'''<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{e(title)}</title>
    <meta name="description" content="{e(description)}">
    <link rel="canonical" href="{url}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Tuende">
    <meta property="og:locale" content="pt_PT">
    <meta property="og:title" content="{e(topic['title'])}">
    <meta property="og:description" content="{e(description)}">
    <meta property="og:url" content="{url}">
    <meta property="og:image" content="{e(image)}">
    <meta name="twitter:card" content="summary_large_image">
    <meta name="theme-color" content="#CE1126">
    <link rel="icon" type="image/png" href="../icon-192.png">
    <script type="application/ld+json">{json.dumps(data, ensure_ascii=False).replace("</", "<\\/")}</script>
    <style>{STYLE}{EXTRA_STYLE}    </style>
</head>
<body>
    <div class="strip" aria-hidden="true"></div>
    <header>
        <a class="brand" href="../">Tuende</a>
        <a class="btn solid" href="../">Abrir a app</a>
    </header>
    <main>
        <p class="crumbs"><a href="../">Tuende</a> › <a href="./">Lugares</a> › Guias</p>
        <h1 style="margin-top:12px">{e(topic['title'])}</h1>
        <p class="lead">{n} {e(topic['what'])}.</p>
        <p class="muted">Na página de cada lugar: horário, preço em Kwanza (quando conhecido), como chegar, as fontes e a data de verificação. Horários e preços mudam: confirme antes de ir.</p>
        <div class="actions">
            {f'<a class="btn solid" href="{topic["cta"][0]}">{e(topic["cta"][1])}</a>' if topic.get('cta') else ''}
            <a class="btn{'' if topic.get('cta') else ' solid'}" href="../?page=map">Ver no mapa</a>
            <a class="btn" href="../agenda/">Agenda de eventos</a>
        </div>
{body}

        <h2>Mais guias</h2>
{guides_html(topic['slug'])}

        <section lang="en">
            <h2>{e(topic['en'])}</h2>
            <p>{n} {e(topic['what_en'])}. Each place page has opening hours, prices in Kwanza and directions. The <a href="../">Tuende app</a> is available in Portuguese, English, French and Spanish.</p>
        </section>
    </main>
    <footer>
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="./">Todos os lugares</a> · <a href="../sobre/">Sobre o Tuende</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
</body>
</html>
'''


def js_value(text):
    """Converte um literal de JavaScript (objetos, listas, textos, números, true/false) em dados Python."""
    pattern = re.compile(r"""\s+|//[^\n]*|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?|[A-Za-z_$][\w$]*|[{}\[\]:,]""", re.S)
    out, pos = [], 0
    while pos < len(text):
        m = pattern.match(text, pos)
        if not m:
            raise ValueError(f'Literal inesperado perto de: {text[pos:pos + 60]!r}')
        tok, pos = m.group(), m.end()
        if tok.isspace() or tok.startswith('//'):
            continue
        if tok[0] in '\'"':
            body, chars, i = tok[1:-1], [], 0
            while i < len(body):
                if body[i] == '\\':
                    nxt = body[i + 1]
                    if nxt == 'u':
                        chars.append(chr(int(body[i + 2:i + 6], 16)))
                        i += 6
                        continue
                    chars.append({'n': '\n', 't': '\t', 'r': '\r'}.get(nxt, nxt))
                    i += 2
                else:
                    chars.append(body[i])
                    i += 1
            out.append(json.dumps(''.join(chars), ensure_ascii=False))
        elif tok in ('true', 'false', 'null'):
            out.append(tok)
        elif tok[0].isalpha() or tok[0] in '_$':
            out.append(json.dumps(tok))
        elif tok in '}]' and out and out[-1] == ',':
            out[-1] = tok
        else:
            out.append(tok)
    return json.loads(''.join(out))


def load_events():
    source = (WEB / 'index.html').read_text(encoding='utf-8')
    start = source.index('[', source.index('const EVENTS = ['))
    end = source.index('\n        ];', start) + len('\n        ]')
    return js_value(source[start:end])


def words(text):
    """As palavras de um texto sem acentos nem maiúsculas, como kambaWords na app."""
    t = unicodedata.normalize('NFD', str(text).lower())
    t = ''.join(ch for ch in t if not '\u0300' <= ch <= '\u036f')
    return [w for w in re.split(r'[^a-z0-9]+', re.sub(r"['’]", ' ', t)) if w]


def load_aliases():
    source = (WEB / 'index.html').read_text(encoding='utf-8')
    start = source.index('const PLACE_ALIASES = {')
    block = source[start:source.index('};', start)]
    return {int(m.group(1)): re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(2)) for m in re.finditer(r'(\d+):\s*\[([^\]]*)\]', block)}


def event_places(events, venues, aliases):
    """O lugar do Tuende onde é cada evento, como eventPlace na app: o nome do local contém o nome do lugar
    (ou um nome alternativo de PLACE_ALIASES) e ganha o nome que aparece primeiro."""
    keys = []
    for v in venues:
        if not v.get('exact'):
            continue
        for name in [v['name'], *aliases.get(v['id'], [])]:
            k = ' ' + ' '.join(words(re.sub(r'\s*\(.*?\)\s*', ' ', name))) + ' '
            if len(k.strip()) >= 4:
                keys.append((k, v))
    out = {}
    for ev in events:
        if not ev.get('venue') or ev.get('venueTbc'):
            continue
        key = ' ' + ' '.join(words(ev['venue'])) + ' '
        hits = [(key.index(k), -len(k), i, v) for i, (k, v) in enumerate(keys) if k in key]
        if hits:
            out[ev['id']] = min(hits, key=lambda h: h[:3])[3]
    return out


EVENT_PLACE = {}  # id do evento -> lugar (preenchido em main)


WEEKDAYS = ['segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado', 'domingo']
EVENT_TYPE = {'music': ('Música', 'Music'), 'dance': ('Dança', 'Dance'), 'theatre': ('Teatro', 'Theatre'), 'film': ('Cinema', 'Film'),
              'fashion': ('Moda', 'Fashion'), 'fairs': ('Feiras e festas', 'Fairs and festivities'), 'sports': ('Desporto', 'Sport')}


def event_dates(start, end=None):
    a = date.fromisoformat(start)
    if not end or end == start:
        return f'{WEEKDAYS[a.weekday()]}, {a.day} de {MONTHS[a.month - 1]} de {a.year}'
    b = date.fromisoformat(end)
    if (a.year, a.month) == (b.year, b.month):
        return f'{a.day} a {b.day} de {MONTHS[a.month - 1]} de {a.year}'
    if a.year == b.year:
        return f'{a.day} de {MONTHS[a.month - 1]} a {b.day} de {MONTHS[b.month - 1]} de {a.year}'
    return f'{pt_date(start)} a {pt_date(end)}'


def event_price(ev):
    p = ev.get('price')
    if not p:
        return 'Preço por confirmar'
    if p.get('free'):
        return 'Entrada gratuita'
    if p.get('text'):
        return p['text']['pt']
    return f"{kz(p['from'])}–{kz(p['to'])} Kz" if p.get('to') else f"{kz(p['from'])} Kz"


def event_venue(ev):
    if not ev.get('venue'):
        return f"Local por confirmar, {ev['city']}"
    return f"{ev['venue']} (local por confirmar), {ev['city']}" if ev.get('venueTbc') else f"{ev['venue']}, {ev['city']}"


def event_data(ev):
    """Dados no formato que o Google usa para mostrar eventos (schema.org Event). Só para eventos com data confirmada."""
    from datetime import datetime, timedelta
    start = ev['start']
    data = {'@type': 'Event', 'name': ev['title']['pt'], 'description': ev['desc']['pt'], 'url': f"{SITE}agenda/#{ev['id']}",
            'eventStatus': 'https://schema.org/EventScheduled', 'eventAttendanceMode': 'https://schema.org/OfflineEventAttendanceMode'}
    if ev.get('time') and not ev.get('end'):
        begin = datetime.fromisoformat(f"{start}T{ev['time']}")
        data['startDate'] = begin.strftime('%Y-%m-%dT%H:%M') + '+01:00'
        if ev.get('hours'):
            data['endDate'] = (begin + timedelta(hours=ev['hours'])).strftime('%Y-%m-%dT%H:%M') + '+01:00'
    else:
        data['startDate'] = start
        if ev.get('end'):
            data['endDate'] = ev['end']
    known = ev.get('venue') and not ev.get('venueTbc')
    data['location'] = {'@type': 'Place', 'name': ev['venue'] if known else ev['city'],
                        'address': {'@type': 'PostalAddress', 'addressLocality': ev['city'], 'addressCountry': 'AO'}}
    p = ev.get('price') or {}
    link = ev.get('link') or ev['source']['url']
    if p.get('free'):
        data['isAccessibleForFree'] = True
        data['offers'] = {'@type': 'Offer', 'price': 0, 'priceCurrency': 'AOA', 'url': link}
    elif p.get('from') and p.get('to'):
        data['offers'] = {'@type': 'AggregateOffer', 'lowPrice': p['from'], 'highPrice': p['to'], 'priceCurrency': 'AOA', 'url': link}
    elif p.get('from'):
        data['offers'] = {'@type': 'Offer', 'price': p['from'], 'priceCurrency': 'AOA', 'url': link}
    if ev.get('host'):
        data['organizer'] = {'@type': 'Organization', 'name': ev['host']}
    return data


def event_html(ev):
    kind = EVENT_TYPE[ev['type']][0]
    when = ev.get('when', {}).get('pt', '')
    note = (ev.get('price') or {}).get('note', {}).get('pt', '')
    links = []
    if ev.get('link'):
        links.append(f'<a href="{e(ev["link"])}">{"Comprar bilhetes" if ev.get("tickets") else "Página do evento"}</a>')
    if ev.get('venue') and not ev.get('venueTbc'):
        from urllib.parse import quote
        links.append(f'<a href="https://www.google.com/maps/search/?api=1&amp;query={quote(ev.get("mapsQuery") or ev["venue"] + ", " + ev["city"] + ", Angola")}">Como chegar</a>')
    place = EVENT_PLACE.get(ev['id'])
    if place:
        links.append(f'<a href="../lugares/{slug(place["name"])}.html">{e(place["name"])} no Tuende</a>')
    links.append(f'<a href="../?page=events#evento-{e(ev["id"])}">Ver na app</a>')
    programme = ''.join(f'<li>{e(event_dates(p["date"], p.get("end")))}: {e(p["pt"])}</li>' for p in ev.get('programme', []))
    phones = f'<p class="meta">Informações: {e(", ".join(ev["phones"]))}</p>' if ev.get('phones') else ''
    return f'''            <li class="item text-only" id="{e(ev['id'])}" data-end="{e(ev.get('end') or ev['start'])}">
                <div>
                    <p class="kicker" style="margin-top:0">{e(kind)} · {e(ev['city'])}</p>
                    <h3>{e(ev['title']['pt'])}</h3>
                    <p class="meta">{e(event_dates(ev['start'], ev.get('end')))}{f' · {e(when)}' if when else ''}</p>
                    <p class="meta">{e(event_venue(ev))} · {e(event_price(ev))}</p>
                    {f'<p class="meta">{e(note)}</p>' if note else ''}
                    <p>{e(ev['desc']['pt'])}</p>
                    {f'<ul>{programme}</ul>' if programme else ''}
                    {phones}
                    <p class="links">{' '.join(links)}</p>
                    <p class="credit">Fonte: <a href="{e(ev['source']['url'])}">{e(ev['source']['name'])}</a>, verificado a {e(pt_date(ev['checked']))}</p>
                </div>
            </li>'''


def agenda_page(events, today):
    current = [ev for ev in events if (ev.get('end') or ev['start']) >= today]
    confirmed = sorted([ev for ev in current if ev.get('confirmed', True)], key=lambda ev: (ev['start'], ev.get('end') or ev['start']))
    yearly = [ev for ev in current if not ev.get('confirmed', True)]
    updated = pt_date(max(ev['checked'] for ev in events))
    months = []
    for ev in confirmed:
        key = ev['start'][:7]
        if not months or months[-1][0] != key:
            months.append((key, []))
        months[-1][1].append(ev)
    body = '\n'.join(f'        <h2>{MONTHS[int(k[5:]) - 1].capitalize()} de {k[:4]}</h2>\n        <ul class="items">\n' + '\n'.join(event_html(ev) for ev in evs) + '\n        </ul>'
                     for k, evs in months)
    if yearly:
        body += ('\n        <h2>Eventos anuais com data por anunciar</h2>\n        <p class="muted">Acontecem todos os anos; as datas abaixo são de edições anteriores.</p>\n'
                 '        <ul class="items">\n' + '\n'.join(event_html(ev) for ev in yearly) + '\n        </ul>')
    cities = sorted({ev['city'] for ev in confirmed}, key=lambda c: (c != 'Luanda', c))
    kinds = [EVENT_TYPE[k][0].lower() for k in EVENT_TYPE if any(ev['type'] == k for ev in confirmed)]
    description = f'{len(confirmed)} eventos em Angola ({", ".join(cities)}): {", ".join(kinds)}. Com datas, locais, preços em Kwanza e links para bilhetes. Atualizada a {updated}.'
    data = {'@context': 'https://schema.org', '@graph': [event_data(ev) for ev in confirmed]}
    url = f'{SITE}agenda/'
    return f'''<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Agenda de eventos em Luanda e Angola | Tuende</title>
    <meta name="description" content="{e(description)}">
    <link rel="canonical" href="{url}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Tuende">
    <meta property="og:locale" content="pt_PT">
    <meta property="og:title" content="Agenda de eventos em Angola">
    <meta property="og:description" content="{e(description)}">
    <meta property="og:url" content="{url}">
    <meta property="og:image" content="{SITE}og-image.jpg">
    <meta name="twitter:card" content="summary_large_image">
    <meta name="theme-color" content="#CE1126">
    <link rel="icon" type="image/png" href="../icon-192.png">
    <script type="application/ld+json">{json.dumps(data, ensure_ascii=False).replace("</", "<\\/")}</script>
    <style>{STYLE}{EXTRA_STYLE}    </style>
</head>
<body>
    <div class="strip" aria-hidden="true"></div>
    <header>
        <a class="brand" href="../">Tuende</a>
        <a class="btn solid" href="../?page=events">Abrir a agenda na app</a>
    </header>
    <main>
        <p class="crumbs"><a href="../">Tuende</a> › Agenda</p>
        <h1 style="margin-top:12px">Agenda de eventos em Angola</h1>
        <p class="lead">Concertos, festas, dança, teatro, cinema, feiras e desporto, sobretudo em Luanda. Só mostramos eventos com fonte publicada.</p>
        <p class="muted">Atualizada a {e(updated)}. Datas, locais e preços podem mudar: confirme na página do evento antes de ir.</p>
{body}

        <h2>Guias</h2>
{guides_html('agenda', '../lugares/')}

        <section lang="en">
            <h2>Events in Luanda and Angola</h2>
            <p>Concerts, parties, dance, theatre, film, fairs and sport, mostly in Luanda, each with a published source, dates, venue and prices in Kwanza. The <a href="../?page=events">agenda in the Tuende app</a> is available in Portuguese, English, French and Spanish and lets you add events to your calendar.</p>
        </section>
    </main>
    <footer>
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="../lugares/">Todos os lugares</a> · <a href="../sobre/">Sobre o Tuende</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
    <script>
        // Esconde os eventos que já acabaram (hora de Angola), até a página ser gerada de novo.
        const today = new Intl.DateTimeFormat('en-CA', {{ timeZone: 'Africa/Luanda' }}).format(new Date());
        document.querySelectorAll('[data-end]').forEach((item) => {{ if (item.dataset.end < today) item.hidden = true; }});
    </script>
</body>
</html>
'''


# Página "Câmbio do dia" (web/cambio/index.html), para quem procura "câmbio do dólar hoje" no Google. As taxas de
# referência do BNA ficam escritas no HTML e o navegador volta a lê-las no BNA a cada visita. As moedas e as taxas
# de reserva vêm de index.html (FX_CODES e FX_FALLBACK); ao gerar, o script tenta primeiro as taxas do dia no BNA.
BNA_RATE = 'https://www.bna.ao/service/rest/taxas/get/taxa/referencia?moeda={}&tipocambio=m'
FX_NAMES = {
    'usd': 'Dólar dos Estados Unidos', 'eur': 'Euro', 'cny': 'Yuan chinês (renminbi)', 'gbp': 'Libra esterlina', 'zar': 'Rand sul-africano',
    'brl': 'Real brasileiro', 'nad': 'Dólar namibiano', 'chf': 'Franco suíço', 'jpy': 'Iene japonês', 'cad': 'Dólar canadiano',
    'aud': 'Dólar australiano', 'aed': 'Dirham dos Emirados Árabes Unidos', 'sar': 'Rial saudita', 'inr': 'Rupia indiana',
    'cdf': 'Franco congolês', 'xaf': 'Franco CFA (BEAC)', 'ngn': 'Naira nigeriana', 'mzn': 'Metical moçambicano',
    'cve': 'Escudo cabo-verdiano', 'rub': 'Rublo russo', 'krw': 'Won sul-coreano', 'sek': 'Coroa sueca', 'nok': 'Coroa norueguesa',
    'dkk': 'Coroa dinamarquesa',
}
FX_TIPS = [
    ('Taxa de referência', 'É a taxa oficial que o BNA publica em cada dia útil (câmbio médio). Serve de guia: não é o valor exato que vai receber.'),
    ('Bancos e casas de câmbio', 'Cada um tem as suas taxas de compra e de venda, um pouco diferentes da de referência, e pode cobrar comissão. Pergunte quanto vai receber antes de trocar e guarde o recibo.'),
    ('Fim de semana', 'O BNA publica as taxas nos dias úteis. Ao sábado e ao domingo continua a valer a de sexta-feira.'),
]
FX_STYLE = """
        .fx-cards { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; margin-top: 18px; }
        .fx-card { display: grid; align-content: start; gap: 2px; padding: 14px 16px; border: 1px solid var(--line); border-radius: 14px; background: var(--surface); }
        .fx-code { font-size: 13px; font-weight: 800; letter-spacing: 0.04em; color: var(--primary); }
        .fx-name { font-size: 14px; color: var(--muted); }
        .fx-card b { margin-top: 4px; font-size: 22px; white-space: nowrap; }
        .fx-convert { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr); gap: 12px; margin-top: 12px; }
        .fx-convert label { display: grid; gap: 6px; min-width: 0; font-size: 15px; font-weight: 700; }
        .fx-convert .fx-wide { grid-column: 1 / -1; }
        .fx-convert input, .fx-convert select { width: 100%; min-height: 48px; padding: 8px 12px; border: 1.5px solid var(--line); border-radius: 12px; background: var(--bg); color: var(--text); font: inherit; font-weight: 400; }
        .fx-list { list-style: none; padding: 0; margin-top: 8px; }
        .fx-list li { display: grid; grid-template-columns: 44px minmax(0, 1fr) auto; align-items: center; gap: 12px; padding: 10px 0; }
        .fx-list li + li { border-top: 1px solid var(--line); }
        .fx-list .fx-name { font-size: 15px; color: var(--text); }
        .fx-rate { text-align: right; }
        .fx-rate b { display: block; font-size: 15px; white-space: nowrap; }
        .fx-rate small { display: block; font-size: 13px; color: var(--muted); white-space: nowrap; }
        @media (max-width: 600px) { .fx-cards { grid-template-columns: 1fr; gap: 8px; } .fx-card { grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 10px; } .fx-card b { margin-top: 0; font-size: 19px; } }
"""
FX_SCRIPT = r"""
        // Volta a ler as taxas do dia no BNA e atualiza os números escritos na página; o conversor só existe com JavaScript.
        const FX = __FX__;
        const fmt = (n) => n.toLocaleString('pt-PT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        const amount = (n) => n.toLocaleString('pt-PT', { maximumFractionDigits: n < 1 ? 4 : 2 });
        const dayText = (iso) => new Date(`${iso}T12:00:00Z`).toLocaleDateString('pt-PT', { day: 'numeric', month: 'long', year: 'numeric' });
        const valor = document.getElementById('fx-valor');
        const kwanzas = document.getElementById('fx-kz');
        const moeda = document.getElementById('fx-moeda');
        let rates = FX.rates;
        let side = 'valor';
        // Aceita "1500", "1 500", "1.500,50" ou "1,500.50".
        function parse(text) {
            const s = String(text).replace(/[\s  ']/g, '');
            for (const [g, d] of [['.', ','], [',', '.']]) {
                if (new RegExp(`^\\d{1,3}(\\${g}\\d{3})*(\\${d}\\d+)?$|^\\d+(\\${d}\\d+)?$`).test(s)) return Number(s.split(g).join('').replace(d, '.'));
            }
            return NaN;
        }
        function convert() {
            const rate = rates[moeda.value];
            const from = side === 'valor' ? valor : kwanzas;
            const to = side === 'valor' ? kwanzas : valor;
            const n = parse(from.value);
            to.value = rate && Number.isFinite(n) ? amount(side === 'valor' ? n * rate : n / rate) : '';
        }
        valor.addEventListener('input', () => { side = 'valor'; convert(); });
        kwanzas.addEventListener('input', () => { side = 'kz'; convert(); });
        moeda.addEventListener('change', convert);
        document.getElementById('conversor').hidden = false;
        convert();
        Promise.all(FX.codes.map((code) => fetch(`https://www.bna.ao/service/rest/taxas/get/taxa/referencia?moeda=${code}&tipocambio=m`)
            .then((res) => res.json())
            .then((json) => ({ code, row: json?.genericResponse?.[0] }))
            .catch(() => ({ code }))))
            .then((rows) => {
                const day = rows.find((r) => r.code === 'usd')?.row?.data;
                const fresh = {};
                rows.forEach(({ code, row }) => { if (row?.taxa > 0 && row.data === day) fresh[code] = row.taxa; });
                if (!fresh.usd || !fresh.eur || !(day >= FX.date)) throw new Error('bna');
                rates = { ...rates, ...fresh };
                document.querySelectorAll('[data-kz]').forEach((el) => { const r = rates[el.dataset.kz]; if (r) el.textContent = fmt(r * Number(el.dataset.unit || 1)); });
                document.querySelectorAll('[data-inv]').forEach((el) => { const r = rates[el.dataset.inv]; if (r) el.textContent = fmt(1000 / r); });
                document.querySelectorAll('[data-date]').forEach((el) => { el.textContent = dayText(day); });
                convert();
            })
            .catch(() => { document.getElementById('fx-falha').hidden = false; });
"""


def pt_number(x, digits=2):
    whole, _, frac = f'{x:.{digits}f}'.partition('.')
    if len(whole) > 4:
        whole = f'{int(whole):,}'.replace(',', ' ')
    return whole + (f',{frac}' if frac else '')


def load_fx():
    source = (WEB / 'index.html').read_text(encoding='utf-8')

    def literal(name, opener):
        start = source.index(opener, source.index(f'const {name} = '))
        return js_value(source[start:source.index(';\n', start)])
    codes, fallback = literal('FX_CODES', '['), literal('FX_FALLBACK', '{')

    # O Python do python.org às vezes não tem os certificados do sistema; o curl do macOS tem.
    def download(link):
        try:
            with urllib.request.urlopen(link, timeout=20) as res:
                return res.read()
        except urllib.error.URLError:
            return subprocess.run(['curl', '-sf', '--max-time', '20', link], capture_output=True, check=True).stdout

    def fetch(code):
        try:
            row = json.loads(download(BNA_RATE.format(code)))['genericResponse'][0]
            return code, float(row['taxa']), row['data']
        except Exception:
            return code, None, None
    with ThreadPoolExecutor(6) as pool:
        rows = list(pool.map(fetch, codes))
    day = next((d for c, r, d in rows if c == 'usd'), None)
    rates = {c: r for c, r, d in rows if r and d == day}
    if day and rates.get('usd') and rates.get('eur') and day >= fallback['date']:
        return codes, {'date': day, 'rates': rates}, True
    return codes, fallback, False


def cambio_page(codes, fx, venues):
    rates, day = fx['rates'], fx['date']
    codes = [c for c in codes if rates.get(c)]
    unit = {c: 100 if rates[c] < 1 else 1 for c in codes}
    url = f'{SITE}cambio/'
    when = pt_date(day)

    def kz_span(c):
        return f'<span data-kz="{c}" data-unit="{unit[c]}">{pt_number(rates[c] * unit[c])}</span>'
    cards = '\n'.join(f'            <div class="fx-card"><span class="fx-code">{c.upper()}</span><span class="fx-name">{e(FX_NAMES.get(c, c.upper()))}</span><b>{kz_span(c)} Kz</b></div>'
                      for c in codes[:3])
    rows = '\n'.join(f'            <li><span class="fx-code">{c.upper()}</span><span class="fx-name">{e(FX_NAMES.get(c, c.upper()))}</span>'
                     f'<span class="fx-rate"><b>{unit[c]} {c.upper()} = {kz_span(c)} Kz</b><small>1000 Kz = <span data-inv="{c}">{pt_number(1000 / rates[c])}</span> {c.upper()}</small></span></li>'
                     for c in codes)
    options = ''.join(f'<option value="{c}">{c.upper()} · {e(FX_NAMES.get(c, c.upper()))}</option>' for c in codes)
    tips = '\n'.join(f'            <div><dt>{e(lead)}</dt><dd>{e(text)}</dd></div>' for lead, text in FX_TIPS)
    shops = '\n'.join(f'            <li><a href="../lugares/{slug(v["name"])}.html">{e(v["name"])}</a> · {e(place_line(v))}</li>'
                      for v in sorted((v for v in venues if v['type'] == 'services'), key=lambda v: (province(v) != 'Luanda', province(v), v['name'])))
    usd, eur, cny = (f'<b>{kz_span(c)} kwanzas</b>' if c in rates else 'por confirmar' for c in ('usd', 'eur', 'cny'))
    description = (f'Câmbio do kwanza hoje, segundo o Banco Nacional de Angola: dólar, euro, yuan e mais {len(codes) - 3} moedas, '
                   'com conversor. As taxas são lidas no BNA sempre que abre a página.')
    data = {'@context': 'https://schema.org', '@type': 'WebPage', 'name': 'Câmbio do dia em Angola', 'url': url, 'description': description,
            'inLanguage': 'pt', 'dateModified': day, 'isPartOf': {'@type': 'WebSite', 'name': 'Tuende', 'url': SITE},
            'mainEntity': [{'@type': 'ExchangeRateSpecification', 'currency': c.upper(),
                            'currentExchangeRate': {'@type': 'UnitPriceSpecification', 'price': rates[c], 'priceCurrency': 'AOA'}} for c in codes]}
    script = FX_SCRIPT.replace('__FX__', json.dumps({'date': day, 'codes': codes, 'rates': {c: rates[c] for c in codes}}))
    return f'''<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Câmbio do dia: kwanza, dólar, euro e yuan | Tuende</title>
    <meta name="description" content="{e(description)}">
    <link rel="canonical" href="{url}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Tuende">
    <meta property="og:locale" content="pt_PT">
    <meta property="og:title" content="Câmbio do dia em Angola">
    <meta property="og:description" content="{e(description)}">
    <meta property="og:url" content="{url}">
    <meta property="og:image" content="{SITE}og-image.jpg">
    <meta name="twitter:card" content="summary_large_image">
    <meta name="theme-color" content="#CE1126">
    <link rel="icon" type="image/png" href="../icon-192.png">
    <script type="application/ld+json">{json.dumps(data, ensure_ascii=False).replace("</", "<\\/")}</script>
    <style>{STYLE}{EXTRA_STYLE}{FX_STYLE}    </style>
</head>
<body>
    <div class="strip" aria-hidden="true"></div>
    <header>
        <a class="brand" href="../">Tuende</a>
        <a class="btn solid" href="../?page=cambio">Abrir na app</a>
    </header>
    <main>
        <p class="crumbs"><a href="../">Tuende</a> › Câmbio do dia</p>
        <h1 style="margin-top:12px">Câmbio do dia: quanto vale o kwanza hoje</h1>
        <p class="lead">1 dólar americano vale {usd}, 1 euro vale {eur} e 1 yuan chinês vale {cny}, segundo a taxa de referência do Banco Nacional de Angola (BNA) de <span data-date>{e(when)}</span>.</p>
        <p class="muted">A página lê as taxas mais recentes no BNA sempre que é aberta.<span id="fx-falha" hidden> Agora não foi possível ligar ao BNA: estas são as taxas de <span data-date>{e(when)}</span>.</span></p>
        <div class="fx-cards">
{cards}
        </div>

        <section id="conversor" hidden>
            <h2>Conversor</h2>
            <div class="fx-convert">
                <label>Valor<input id="fx-valor" type="text" inputmode="decimal" autocomplete="off" value="100"></label>
                <label>Moeda<select id="fx-moeda">{options}</select></label>
                <label class="fx-wide">Em kwanzas (Kz)<input id="fx-kz" type="text" inputmode="decimal" autocomplete="off"></label>
            </div>
            <p class="muted">Escreva num dos campos; o outro é calculado com a taxa de referência.</p>
        </section>

        <h2>Todas as moedas</h2>
        <ul class="fx-list">
{rows}
        </ul>
        <p class="sources">Fonte: <a href="https://www.bna.ao/">Banco Nacional de Angola</a> (taxa de referência, câmbio médio).</p>

        <h2>Antes de trocar</h2>
        <dl>
{tips}
        </dl>

        <h2>Onde trocar</h2>
        <p>Em bancos ou casas de câmbio. Estas são as que o Tuende conhece, com morada e como chegar:</p>
        <ul class="links">
{shops}
        </ul>
        <div class="actions">
            <a class="btn solid" href="../?page=cambio">Abrir o conversor na app</a>
            <a class="btn" href="../lugares/casas-de-cambio-em-angola.html">Casas de câmbio em Angola</a>
        </div>

        <h2>Guias</h2>
{guides_html('cambio', '../lugares/')}

        <section lang="en">
            <h2>Kwanza exchange rate today</h2>
            <p>The official reference rates of the Banco Nacional de Angola (BNA) for the kwanza against the US dollar, the euro, the Chinese yuan and {len(codes) - 3} other currencies. This page reads the latest rates from the BNA each time it opens. Banks and exchange bureaus apply their own buying and selling rates. The converter is also in the <a href="../?page=cambio">Tuende app</a>, in Portuguese, English, French and Spanish.</p>
        </section>
    </main>
    <footer>
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="../lugares/">Todos os lugares</a> · <a href="../sobre/">Sobre o Tuende</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
    <script>{script}    </script>
</body>
</html>
'''

# Rotas entre cidades (web/rotas/<id>.html e web/rotas/index.html): autocarro, avião, comboio, barco e carro, a partir
# de const TRAVEL_ROUTES em index.html. Só preços publicados (com fonte e data); o resto fica "por confirmar".
MODE = {'bus': ('Autocarro', 'Bus'), 'plane': ('Avião', 'Plane'), 'train': ('Comboio', 'Train'), 'boat': ('Barco', 'Boat'), 'car': ('Carro', 'Car')}
ARTICLE = {'Lobito': 'o', 'Luena': 'o', 'Huambo': 'o', 'Lubango': 'o', 'Soyo': 'o', 'Dundo': 'o', 'Namibe': 'o', 'Cuíto': 'o', 'Sumbe': 'o', 'Uíge': 'o'}
ROUTES_STYLE = """
        .options { list-style: none; padding: 0; margin-top: 12px; display: grid; gap: 12px; }
        .option { padding: 14px 16px; border: 1px solid var(--line); border-radius: 14px; }
        .option h3 { font-size: 18px; } .option .mode { color: var(--primary); font-weight: 800; }
        .option dl { margin-top: 8px; border: 0; } .option dl > div { padding: 4px 0; grid-template-columns: 110px 1fr; } .option dl > div + div { border-top: 0; }
        .option .src { font-size: 14px; color: var(--muted); margin-top: 6px; } .option .src a { color: inherit; }
        .routes { list-style: none; padding: 0; margin-top: 12px; display: grid; gap: 10px; }
        .routes a { display: block; padding: 12px 16px; border: 1px solid var(--line); border-radius: 14px; color: var(--text); text-decoration: none; }
        .routes b { display: block; font-size: 18px; } .routes span { color: var(--muted); font-size: 15px; }
"""


def de(city):
    return {'o': 'do'}.get(ARTICLE.get(city), 'de') + ' ' + city


def a(city):
    return {'o': 'ao'}.get(ARTICLE.get(city), 'a') + ' ' + city


def load_routes():
    source = (WEB / 'index.html').read_text(encoding='utf-8')

    def literal(name, opener):
        start = source.index(opener, source.index(f'const {name} = '))
        return source[start:source.index(';\n', start)]
    consts = {name: js_value(literal(name, '{')) for name in ('ROUTE_SOURCES', 'TAAG_NOTE', 'GAMEK', 'AIAAN', 'MACON_NOTE')}
    text = literal('TRAVEL_ROUTES', '[')
    text = re.sub(r'ROUTE_SOURCES\.(\w+)', lambda m: json.dumps(consts['ROUTE_SOURCES'][m.group(1)], ensure_ascii=False), text)
    for name in ('TAAG_NOTE', 'GAMEK', 'AIAAN', 'MACON_NOTE'):
        text = re.sub(rf'\b{name}\b', lambda m: json.dumps(consts[m.group(0)], ensure_ascii=False), text)
    return js_value(text)


def route_title(r, lang='pt'):
    if lang == 'en':
        return f'How to get from {r["from"]} to {r["to"]}'
    return f'Como ir {de(r["from"])} {a(r["to"])}'


def hours_text(h, lang='pt'):
    whole = int(h)
    minutes = round((h - whole) * 60 / 10) * 10
    if minutes == 60:
        whole, minutes = whole + 1, 0
    return f'{whole}h{minutes:02d}' if minutes else f'{whole}h'


def route_summary(r, lang='pt'):
    parts = []
    for mode in ('bus', 'plane', 'train', 'boat'):
        opts = [o for o in r['options'] if o['mode'] == mode]
        if not opts:
            continue
        prices = [o['price']['from'] for o in opts if o.get('price', {}).get('from') and not o['price'].get('text')]
        texts = [o['price']['text']['en' if lang == 'en' else 'pt'] for o in opts if o.get('price', {}).get('text')]
        label = MODE[mode][1 if lang == 'en' else 0].lower()
        if lang == 'en':
            parts.append(f'by {label} from {kz(min(prices))} Kz' if prices else (f'by {label} ({texts[0]})' if texts else f'by {label}'))
        else:
            parts.append(f'de {label} desde {kz(min(prices))} Kz' if prices else (f'de {label} ({texts[0]})' if texts else f'de {label}'))
    car = next((o for o in r['options'] if o['mode'] == 'car' and o.get('km')), None)
    if car:
        parts.append(f'by car: {car["km"]} km, about {hours_text(car["hours"])} without stops' if lang == 'en'
                     else f'de carro: {car["km"]} km, cerca de {hours_text(car["hours"])} sem paragens')
    if not parts:
        return ''
    text = ', '.join(parts[:-1]) + (' or ' if lang == 'en' else ' ou ') + parts[-1] if len(parts) > 1 else parts[0]
    return text[0].upper() + text[1:] + '.'


def place_link(venues, vid):
    v = next((x for x in venues if x['id'] == vid), None)
    return f'<a href="../lugares/{slug(v["name"])}.html">{e(v["name"])}</a>' if v else ''


def option_html(o, venues):
    who = o.get('who', '')
    head = f'<span class="mode">{MODE[o["mode"]][0]}</span>' + (f' · {e(who)}' if who else '')
    rows = []
    if o.get('where'):
        rows.append(('Partida', e(o['where']['pt']) + (f' ({place_link(venues, o["place"])})' if o.get('place') and o['mode'] != 'bus' else '')))
    if o.get('arrive'):
        rows.append(('Chegada', place_link(venues, o['arrive'])))
    if o['mode'] == 'car' and o.get('km'):
        rows.append(('Distância', f'{o["km"]} km, cerca de {hours_text(o["hours"])} sem paragens'))
    price = o.get('price')
    if price:
        rows.append(('Preço', e(price['text']['pt']) if price.get('text') else f'desde {kz(price["from"])} Kz'))
    elif o['mode'] != 'car':
        rows.append(('Preço', 'por confirmar'))
    if o.get('place') and o['mode'] == 'bus':
        rows.append(('No Tuende', place_link(venues, o['place'])))
    note = f'<p>{e(o["note"]["pt"])}</p>' if o.get('note') else ''
    src = f'<p class="src">Fonte: <a href="{e(o["source"]["url"])}">{e(o["source"]["label"])}</a></p>' if o.get('source') else ''
    dl = ''.join(f'<div><dt>{k}</dt><dd>{v}</dd></div>' for k, v in rows)
    return f'            <li class="option"><h3>{head}</h3>{f"<dl>{dl}</dl>" if dl else ""}{note}{src}</li>'


def routes_list_html(routes, current=''):
    return '\n'.join(f'            <li><a href="{r["id"]}.html"><b>{e(route_title(r))}</b><span>{e(route_summary(r))}</span></a></li>'
                     for r in routes if r['id'] != current)


def modes_title(r):
    names = [MODE[m][0].lower() for m in ('bus', 'plane', 'train', 'boat', 'car') if any(o['mode'] == m and (m != 'car' or o.get('km')) for o in r['options'])]
    return ', '.join(names[:-1]) + ' e ' + names[-1] if len(names) > 1 else names[0]


def route_page(r, routes, venues):
    title = route_title(r)
    url = f'{SITE}rotas/{r["id"]}.html'
    summary = route_summary(r)
    also = f' {r["alsoTitle"]}' if r.get('alsoTitle') else ''
    description = f'{title}{also}: {summary} Preços com fonte e data, e onde se apanha cada transporte.'
    options = '\n'.join(option_html(o, venues) for o in r['options'])
    topic = next((t for t in TOPICS if t['slug'] == r.get('topic')), None)
    extra = [place_link(venues, vid) for vid in r.get('places', [])]
    see = ([f'<a href="../lugares/{topic["slug"]}.html">{e(topic["title"])}</a>'] if topic else []) + [x for x in extra if x]
    en_opts = ''.join(f'<li>{MODE[o["mode"]][1]}{" (" + e(o["who"]) + ")" if o.get("who") else ""}: {str(o["km"]) + " km, about " + hours_text(o["hours"]) + " without stops. " if o.get("km") else ""}{e(o["note"]["en"]) if o.get("note") else ""}'
                      f'{" From " + kz(o["price"]["from"]) + " Kz." if o.get("price") and not o["price"].get("text") else (" " + e(o["price"]["text"]["en"]) + "." if o.get("price") else "")}</li>'
                      for o in r['options'])
    data = {'@context': 'https://schema.org', '@type': 'WebPage', 'name': title, 'url': url, 'description': description, 'inLanguage': 'pt',
            'dateModified': r['checked'], 'isPartOf': {'@type': 'WebSite', 'name': 'Tuende', 'url': SITE}}
    return f'''<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{e(title)}: {e(modes_title(r))} | Tuende</title>
    <meta name="description" content="{e(description)}">
    <link rel="canonical" href="{url}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Tuende">
    <meta property="og:locale" content="pt_PT">
    <meta property="og:title" content="{e(title)}">
    <meta property="og:description" content="{e(summary)}">
    <meta property="og:url" content="{url}">
    <meta property="og:image" content="{SITE}og-image.jpg">
    <meta name="twitter:card" content="summary_large_image">
    <meta name="theme-color" content="#CE1126">
    <link rel="icon" type="image/png" href="../icon-192.png">
    <script type="application/ld+json">{json.dumps(data, ensure_ascii=False).replace("</", "<\\/")}</script>
    <style>{STYLE}{EXTRA_STYLE}{ROUTES_STYLE}    </style>
</head>
<body>
    <div class="strip" aria-hidden="true"></div>
    <header>
        <a class="brand" href="../">Tuende</a>
        <a class="btn solid" href="../">Abrir a app</a>
    </header>
    <main>
        <p class="crumbs"><a href="../">Tuende</a> › <a href="./">Rotas</a> › {e(r["from"])}–{e(r["to"])}</p>
        <h1 style="margin-top:12px">{e(title)}{e(also)}</h1>
        <p class="lead">{e(summary)}</p>
        <p class="muted">Preços e horários verificados a {e(pt_date(r["checked"]))}. Mudam com frequência: confirme com a empresa antes de viajar.</p>

        <h2>As opções</h2>
        <ul class="options">
{options}
        </ul>
        {f'<h2>No destino</h2>{chr(10)}        <ul class="links">{"".join(f"<li>{x}</li>" for x in see)}</ul>' if see else ''}

        <h2>Outras rotas</h2>
        <ul class="routes">
{routes_list_html(routes, r["id"])}
        </ul>

        <section lang="en">
            <h2>{e(route_title(r, "en"))}</h2>
            <p>{e(route_summary(r, "en"))} Fares and timetables checked on {e(r["checked"])}; they change often, so confirm with the operator before you travel.</p>
            <ul class="links">{en_opts}</ul>
        </section>
    </main>
    <footer>
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="../lugares/">Todos os lugares</a> · <a href="../sobre/">Sobre o Tuende</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
</body>
</html>
'''


def routes_index_page(routes):
    url = f'{SITE}rotas/'
    description = (f'{len(routes)} rotas entre cidades de Angola, de autocarro, avião, comboio, barco e carro: Luanda–Benguela, '
                   'Luanda–Lubango, Luanda–Huambo, Luanda–Malanje, Luanda–Cabinda e mais. Preços com fonte e data.')
    return f'''<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Como viajar entre cidades em Angola | Tuende</title>
    <meta name="description" content="{e(description)}">
    <link rel="canonical" href="{url}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Tuende">
    <meta property="og:title" content="Como viajar entre cidades em Angola">
    <meta property="og:description" content="{e(description)}">
    <meta property="og:url" content="{url}">
    <meta property="og:image" content="{SITE}og-image.jpg">
    <meta name="theme-color" content="#CE1126">
    <link rel="icon" type="image/png" href="../icon-192.png">
    <style>{STYLE}{EXTRA_STYLE}{ROUTES_STYLE}    </style>
</head>
<body>
    <div class="strip" aria-hidden="true"></div>
    <header>
        <a class="brand" href="../">Tuende</a>
        <a class="btn solid" href="../">Abrir a app</a>
    </header>
    <main>
        <p class="crumbs"><a href="../">Tuende</a> › Rotas</p>
        <h1 style="margin-top:12px">Como viajar entre cidades em Angola</h1>
        <p class="lead">De autocarro, avião, comboio, barco ou carro: as opções para cada viagem, com preços publicados e a fonte de cada um.</p>
        <p class="muted">Os voos domésticos saem do Aeroporto Dr. António Agostinho Neto, a 40 km do centro de Luanda; há comboio da estação do Bungo para o aeroporto. As distâncias de carro são estimativas sem paragens: evite conduzir à noite fora das cidades.</p>
        <ul class="routes">
{routes_list_html(routes)}
        </ul>

        <h2>Guias</h2>
{guides_html('rotas', '../lugares/')}

        <section lang="en">
            <h2>Travelling between cities in Angola</h2>
            <p>Bus, plane, train, boat and car options for {len(routes)} routes, with published fares and their sources. The <a href="../">Tuende app</a> is available in Portuguese, English, French and Spanish.</p>
        </section>
    </main>
    <footer>
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="../lugares/">Todos os lugares</a> · <a href="../sobre/">Sobre o Tuende</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
</body>
</html>
'''



def index_page(venues):
    by_city = {}
    for v in venues:
        by_city.setdefault(v['location'].split(' - ')[0], []).append(v)
    sections = []
    for city in sorted(by_city, key=lambda c: (c != 'Luanda', c)):
        items = '\n'.join(f'            <li><a href="{slug(v["name"])}.html">{e(v["name"])}</a> · {e(CATEGORY[v["type"]][0])}</li>'
                          for v in sorted(by_city[city], key=lambda v: v['name']))
        sections.append(f'        <h2>{e(city)}</h2>\n        <ul class="links">\n{items}\n        </ul>')
    body = '\n'.join(sections)
    return f'''<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Todos os lugares em Angola | Tuende</title>
    <meta name="description" content="{len(venues)} lugares em Angola: restaurantes, praias, cultura, museus, natureza, alojamento e transportes, com preços em Kwanza.">
    <link rel="canonical" href="{SITE}lugares/">
    <meta property="og:title" content="Todos os lugares em Angola | Tuende">
    <meta property="og:image" content="{SITE}og-image.jpg">
    <meta name="theme-color" content="#CE1126">
    <link rel="icon" type="image/png" href="../icon-192.png">
    <style>{STYLE}{EXTRA_STYLE}    </style>
</head>
<body>
    <div class="strip" aria-hidden="true"></div>
    <header>
        <a class="brand" href="../">Tuende</a>
        <a class="btn solid" href="../">Abrir a app</a>
    </header>
    <main>
        <h1 style="margin-top:24px">Todos os lugares</h1>
        <p class="lead">{len(venues)} lugares em Angola, cada um com fontes e data de verificação.</p>
        <h2>Guias</h2>
{guides_html()}
{body}
    </main>
    <footer>
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="../sobre/">Sobre o Tuende</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
</body>
</html>
'''


# Página "Sobre o Tuende" (web/sobre/index.html): quem somos, como verificamos e o que não somos.
def sobre_page(venues, events, routes):
    url = f'{SITE}sobre/'
    today = date.today().isoformat()
    provinces = len({province(v) for v in venues})
    upcoming = len([ev for ev in events if (ev.get('end') or ev.get('start') or '') >= today])
    description = ('O Tuende é um guia gratuito de Angola, com a fonte de cada informação, só fotos reais e "por confirmar" '
                   'em vez de inventar. Sem publicidade e sem lugares pagos.')
    data = {'@context': 'https://schema.org', '@type': 'AboutPage', 'name': 'Sobre o Tuende', 'url': url, 'description': description, 'inLanguage': 'pt',
            'isPartOf': {'@type': 'WebSite', 'name': 'Tuende', 'url': SITE},
            'mainEntity': {'@type': 'Organization', 'name': 'Tuende', 'url': SITE, 'logo': f'{SITE}icon-512.png', 'description': description}}
    trust = [
        ('Uma fonte para cada lugar.', 'Cada lugar e cada evento mostra de onde vem a informação e a data em que a verificámos. Pode abrir a fonte e confirmar.'),
        ('«Por confirmar» em vez de inventar.', 'Se não sabemos um horário, um preço ou um telefone, dizemo-lo. Os telefones só aparecem depois de confirmados.'),
        ('Só fotos reais.', 'Fotos do próprio lugar, com o nome do autor e a licença. Sem uma foto real, o lugar fica sem foto.'),
        ('Ninguém paga para aparecer.', 'O Tuende é gratuito, não pede registo e não tem publicidade. Hoje nenhum lugar paga para estar aqui ou para aparecer primeiro.'),
        ('Fontes oficiais quando existem.', 'O câmbio do dia vem do Banco Nacional de Angola, os vistos do portal eVISA do SME, e a segurança e a saúde dos conselhos de viagem de Portugal e do Reino Unido.'),
    ]
    items = '\n'.join(f'            <li><b>{e(a)}</b> {e(b)}</li>' for a, b in trust)
    return f"""<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Sobre o Tuende: um guia de Angola com fontes | Tuende</title>
    <meta name="description" content="{e(description)}">
    <link rel="canonical" href="{url}">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Tuende">
    <meta property="og:title" content="Sobre o Tuende">
    <meta property="og:description" content="{e(description)}">
    <meta property="og:url" content="{url}">
    <meta property="og:image" content="{SITE}og-image.jpg">
    <meta name="theme-color" content="#CE1126">
    <link rel="icon" type="image/png" href="../icon-192.png">
    <style>{STYLE}{EXTRA_STYLE}        .trust {{ margin-top: 10px; padding-left: 20px; display: grid; gap: 10px; }}
    </style>
    <script type="application/ld+json">{json.dumps(data, ensure_ascii=False)}</script>
</head>
<body>
    <div class="strip" aria-hidden="true"></div>
    <header>
        <a class="brand" href="../">Tuende</a>
        <a class="btn solid" href="../">Abrir a app</a>
    </header>
    <main>
        <p class="crumbs"><a href="../">Tuende</a> › Sobre</p>
        <h1 style="margin-top:12px">Sobre o Tuende</h1>
        <p class="lead">O Tuende é um guia gratuito de Angola, para quem visita e para quem vive cá: onde comer, o que ver, onde dormir, como viajar entre cidades e o que está a acontecer, com a fonte de cada informação.</p>

        <h2>Porque pode confiar no Tuende</h2>
        <ul class="trust">
{items}
        </ul>

        <h2>O que o Tuende não é</h2>
        <p>O Tuende não é um serviço do Governo de Angola nem uma agência de viagens, e não tem acreditação oficial. Não vendemos viagens nem bilhetes: indicamos onde comprá-los. Horários e preços mudam, por isso confirme o mais importante antes de ir.</p>

        <h2>Feito para quem chega e para quem cá vive</h2>
        <p>Em português, inglês, francês e espanhol. Os preços aparecem em kwanzas, com o valor aproximado em dólares, euros e libras. O que já abriu continua disponível sem internet, e o Kamba, o assistente, responde com os dados verificados do Tuende.</p>

        <h2>O Tuende hoje</h2>
        <p>{len(venues)} lugares em {provinces} províncias, {upcoming} eventos na agenda e {len(routes)} rotas entre cidades. Veja <a href="../lugares/">todos os lugares</a>, a <a href="../agenda/">agenda</a>, o <a href="../cambio/">câmbio do dia</a> e as <a href="../rotas/">rotas entre cidades</a>.</p>

        <h2>Ajude a melhorar</h2>
        <p>Viu um erro ou conhece um lugar que devia estar aqui? Na <a href="../">app</a>, use «Recomendar um lugar». Cada sugestão é verificada antes de ser publicada.</p>

        <section lang="en">
            <h2>About Tuende</h2>
            <p>Tuende is a free guide to Angola for visitors and locals, in Portuguese, English, French and Spanish. Every place and event shows its source and the date it was checked; when something is not confirmed we say "to be confirmed" instead of guessing; we only use real photos of each place, credited to their authors. Tuende has no advertising and no paid listings. It is not a government service or a travel agency, and it has no official accreditation.</p>
        </section>
    </main>
    <footer>
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="../lugares/">Todos os lugares</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
</body>
</html>
"""


# "Perto daqui": the closest places in a straight line (up to 25 km), as in the app.
def km_between(a, b):
    from math import asin, cos, radians, sin, sqrt
    dlat, dlng = radians(b['lat'] - a['lat']), radians(b['lng'] - a['lng'])
    h = sin(dlat / 2) ** 2 + cos(radians(a['lat'])) * cos(radians(b['lat'])) * sin(dlng / 2) ** 2
    return 6371 * 2 * asin(sqrt(h))


def nearby(v, venues, limit=6, max_km=25):
    has_point = lambda x: isinstance(x.get('lat'), (int, float)) and isinstance(x.get('lng'), (int, float)) and not x.get('citywide')
    if not has_point(v):
        return []
    near = sorted(((km_between(v, o), o) for o in venues if o['id'] != v['id'] and has_point(o)), key=lambda x: x[0])
    return [(d, o) for d, o in near if d <= max_km][:limit]


def main():
    venues, desc_en = load()
    APP_ICONS.update(load_icons())
    slugs = [slug(v['name']) for v in venues] + [t['slug'] for t in TOPICS]
    dupes = {s for s in slugs if slugs.count(s) > 1}
    if dupes:
        raise SystemExit(f'Nomes que dão o mesmo endereço: {sorted(dupes)}')
    out = WEB / 'lugares'
    # Apaga só as páginas geradas que já não existem (lugar removido ou renomeado); ficheiros com outros nomes ficam.
    keep = {f'{slug(v["name"])}.html' for v in venues} | {f'{t["slug"]}.html' for t in TOPICS} | {'index.html'}
    out.mkdir(exist_ok=True)
    for old in out.iterdir():
        if re.fullmatch(r'[a-z0-9-]+\.html', old.name) and old.name not in keep:
            old.unlink()
    events = load_events()
    EVENT_PLACE.update(event_places(events, venues, load_aliases()))
    today_iso = date.today().isoformat()
    for v in venues:
        city = v['location'].split(' - ')[0]
        near = nearby(v, venues)
        here = sorted((ev for ev in events if EVENT_PLACE.get(ev['id']) is v and ev.get('confirmed') is not False
                       and (ev.get('end') or ev['start']) >= today_iso), key=lambda ev: ev['start'])
        near_ids = {o['id'] for _, o in near}
        others = [o for o in venues if o['id'] != v['id'] and o['location'].split(' - ')[0] == city and o['id'] not in near_ids][:8]
        (out / f'{slug(v["name"])}.html').write_text(page(v, others, desc_en, near, here), encoding='utf-8')
    (out / 'index.html').write_text(index_page(venues), encoding='utf-8')
    for topic in TOPICS:
        items = [v for v in venues if topic['pick'](v)]
        if len(items) < 3:
            raise SystemExit(f'O guia {topic["slug"]} só tem {len(items)} lugares')
        (out / f'{topic["slug"]}.html').write_text(topic_page(topic, items), encoding='utf-8')
    (WEB / 'agenda').mkdir(exist_ok=True)
    (WEB / 'agenda' / 'index.html').write_text(agenda_page(events, date.today().isoformat()), encoding='utf-8')
    routes = load_routes()
    rdir = WEB / 'rotas'
    rdir.mkdir(exist_ok=True)
    keep_routes = {f'{r["id"]}.html' for r in routes} | {'index.html'}
    for old in rdir.iterdir():
        if re.fullmatch(r'[a-z0-9-]+\.html', old.name) and old.name not in keep_routes:
            old.unlink()
    for r in routes:
        (rdir / f'{r["id"]}.html').write_text(route_page(r, routes, venues), encoding='utf-8')
    (rdir / 'index.html').write_text(routes_index_page(routes), encoding='utf-8')
    (WEB / 'cambio').mkdir(exist_ok=True)
    codes, fx, live = load_fx()
    (WEB / 'cambio' / 'index.html').write_text(cambio_page(codes, fx, venues), encoding='utf-8')
    (WEB / 'sobre').mkdir(exist_ok=True)
    (WEB / 'sobre' / 'index.html').write_text(sobre_page(venues, events, routes), encoding='utf-8')

    today = date.today().isoformat()
    # Só endereços próprios: as secções da app (?page=...) apontam para a página principal (canonical).
    urls = [SITE, f'{SITE}agenda/', f'{SITE}cambio/', f'{SITE}rotas/'] + [f'{SITE}rotas/{r["id"]}.html' for r in routes] + [f'{SITE}lugares/'] + [f'{SITE}lugares/{t["slug"]}.html' for t in TOPICS] + [f'{SITE}termos.html', f'{SITE}sobre/']
    urls += [f'{SITE}lugares/{slug(v["name"])}.html' for v in venues]
    sitemap = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    sitemap += [f'  <url><loc>{html.escape(u)}</loc><lastmod>{today}</lastmod></url>' for u in urls]
    sitemap.append('</urlset>')
    (WEB / 'sitemap.xml').write_text('\n'.join(sitemap) + '\n', encoding='utf-8')
    (WEB / 'robots.txt').write_text(f'User-agent: *\nAllow: /\n\nSitemap: {SITE}sitemap.xml\n', encoding='utf-8')
    print(f'{len(venues)} páginas de lugares, {len(TOPICS)} guias (lugares/<guia>.html), lugares/index.html, agenda/index.html, '
          f'{len(routes)} rotas (rotas/), cambio/index.html (taxas do BNA de {fx["date"]}{"" if live else ", de reserva: o BNA não respondeu"}), '
          f'sitemap.xml ({len(urls)} endereços) e robots.txt')


if __name__ == '__main__':
    main()
