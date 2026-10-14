#!/usr/bin/env python3
"""Gera uma página por lugar (web/lugares/<nome>.html), os guias por tema (web/lugares/<guia>.html), a agenda
(web/agenda/index.html), a lista de lugares, o sitemap.xml e o robots.txt.

Os dados vêm de web/index.html (const venues, DESC_EN e EVENTS), por isso basta voltar a correr este script
depois de mudar ou acrescentar lugares ou eventos:

    python3 tools/gerar_paginas.py

Estas páginas servem para o Google mostrar cada lugar nos resultados e para o WhatsApp e as redes
sociais mostrarem a foto e o nome do lugar quando alguém partilha o link. A app continua a ser a
página principal; cada página tem um botão para abrir o lugar na app.
"""
import html
import json
import re
import shutil
import unicodedata
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
}
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


def page(v, others, desc_en):
    name = v['name']
    cat_pt, cat_en, schema_type = CATEGORY[v['type']]
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
    focus = f' style="object-position: {photo["focus"]}"' if photo and photo['focus'] else ''
    figure = f'''        <figure>
            <img src="../{e(photo['src'])}" alt="{e(name)}" width="960" height="540"{focus}>
            <figcaption>{photo['credit']}</figcaption>
        </figure>''' if photo else ''
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
    <style>{STYLE}    </style>
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
        {f'<p class="lead">{e(highlight)}</p>' if highlight else ''}
        <p>{e(v['description'])}</p>
        <div class="actions">
            <a class="btn solid" href="../#local-{v['id']}">Ver no Tuende</a>
            <a class="btn" href="{e(maps_url(v))}">Como chegar</a>
        </div>

        <h2>Informação prática</h2>
        <dl>
{facts_html}
        </dl>
        <p class="sources">Verificado a {e(pt_date(checked))}. Fontes: {', '.join(f'<a href="{e(src["url"])}">{e(src["label"])}</a>' for src in sources) or 'por confirmar'}. Confirme sempre antes de ir.</p>

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
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="./">Todos os lugares</a> · <a href="../termos.html">Termos de utilização</a></p>
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
}
TYPE_ORDER = ['culture', 'museum', 'nature', 'beach', 'plaza', 'restaurant', 'bar', 'nightclub', 'accommodation', 'shopping', 'sport', 'services', 'transport']


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
     'pick': lambda v: v['type'] == 'services', 'what': 'casas de câmbio em Angola', 'what_en': 'currency exchange offices in Angola'},
]


def guides_html(current='', prefix=''):
    links = [('agenda', f'{prefix}../agenda/', 'Agenda de eventos')] + [(t['slug'], f'{prefix}{t["slug"]}.html', t['title']) for t in TOPICS]
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
            <a class="btn solid" href="../?page=map">Ver no mapa</a>
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
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="./">Todos os lugares</a> · <a href="../termos.html">Termos de utilização</a></p>
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
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="../lugares/">Todos os lugares</a> · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
    <script>
        // Esconde os eventos que já acabaram (hora de Angola), até a página ser gerada de novo.
        const today = new Intl.DateTimeFormat('en-CA', {{ timeZone: 'Africa/Luanda' }}).format(new Date());
        document.querySelectorAll('[data-end]').forEach((item) => {{ if (item.dataset.end < today) item.hidden = true; }});
    </script>
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
        <p><a href="../">Tuende</a> · Descubra onde ir em Angola · <a href="../termos.html">Termos de utilização</a></p>
    </footer>
</body>
</html>
'''


def main():
    venues, desc_en = load()
    slugs = [slug(v['name']) for v in venues] + [t['slug'] for t in TOPICS]
    dupes = {s for s in slugs if slugs.count(s) > 1}
    if dupes:
        raise SystemExit(f'Nomes que dão o mesmo endereço: {sorted(dupes)}')
    out = WEB / 'lugares'
    if out.exists():
        shutil.rmtree(out)
    out.mkdir()
    for v in venues:
        city = v['location'].split(' - ')[0]
        others = [o for o in venues if o['id'] != v['id'] and o['location'].split(' - ')[0] == city][:8]
        (out / f'{slug(v["name"])}.html').write_text(page(v, others, desc_en), encoding='utf-8')
    (out / 'index.html').write_text(index_page(venues), encoding='utf-8')
    for topic in TOPICS:
        items = [v for v in venues if topic['pick'](v)]
        if len(items) < 3:
            raise SystemExit(f'O guia {topic["slug"]} só tem {len(items)} lugares')
        (out / f'{topic["slug"]}.html').write_text(topic_page(topic, items), encoding='utf-8')
    (WEB / 'agenda').mkdir(exist_ok=True)
    events = load_events()
    (WEB / 'agenda' / 'index.html').write_text(agenda_page(events, date.today().isoformat()), encoding='utf-8')

    today = date.today().isoformat()
    # Só endereços próprios: as secções da app (?page=...) apontam para a página principal (canonical).
    urls = [SITE, f'{SITE}agenda/', f'{SITE}lugares/'] + [f'{SITE}lugares/{t["slug"]}.html' for t in TOPICS] + [f'{SITE}termos.html']
    urls += [f'{SITE}lugares/{slug(v["name"])}.html' for v in venues]
    sitemap = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    sitemap += [f'  <url><loc>{html.escape(u)}</loc><lastmod>{today}</lastmod></url>' for u in urls]
    sitemap.append('</urlset>')
    (WEB / 'sitemap.xml').write_text('\n'.join(sitemap) + '\n', encoding='utf-8')
    (WEB / 'robots.txt').write_text(f'User-agent: *\nAllow: /\n\nSitemap: {SITE}sitemap.xml\n', encoding='utf-8')
    print(f'{len(venues)} páginas de lugares, {len(TOPICS)} guias (lugares/<guia>.html), lugares/index.html, agenda/index.html, '
          f'sitemap.xml ({len(urls)} endereços) e robots.txt')


if __name__ == '__main__':
    main()
