#!/usr/bin/env python3
"""Gera uma página por lugar (web/lugares/<nome>.html), a lista de lugares, o sitemap.xml e o robots.txt.

Os dados vêm de web/index.html (const venues e DESC_EN), por isso basta voltar a correr este script
depois de mudar ou acrescentar lugares:

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
SITE = 'https://kingic17.github.io/tuende/'

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
        return {'src': p['url'], 'credit': f"Foto: <a href=\"{e(p['page'])}\">{e(p['author'])}</a> · {e(p['license'])} · Wikimedia Commons", 'focus': p.get('focus', '')}
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
    facts = [('Horário', ''.join(f'<span>{e(d)}</span><span>{e(h)}</span>' if d else f'<span>{e(h)}</span>' for d, h in hours_lines(v)))]
    facts.append(('Morada', e(v.get('address') or where)))
    price = price_text(v)
    note = v.get('price', {}).get('note', {}).get('pt') if v.get('price') else ''
    facts.append(('Preço', e(price) + (f'<br>{e(note)}' if note else '')))
    facts_html = '\n'.join(
        f'            <div><dt>{label}</dt><dd>{f"<div class=\"hours\">{value}</div>" if label == "Horário" and v.get("hours") else value}</dd></div>'
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
    <style>{STYLE}    </style>
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
    slugs = [slug(v['name']) for v in venues]
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

    today = date.today().isoformat()
    urls = [SITE, f'{SITE}?page=events', f'{SITE}?page=guide', f'{SITE}?page=routes', f'{SITE}?page=map', f'{SITE}lugares/', f'{SITE}termos.html']
    urls += [f'{SITE}lugares/{slug(v["name"])}.html' for v in venues]
    sitemap = ['<?xml version="1.0" encoding="UTF-8"?>', '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    sitemap += [f'  <url><loc>{html.escape(u)}</loc><lastmod>{today}</lastmod></url>' for u in urls]
    sitemap.append('</urlset>')
    (WEB / 'sitemap.xml').write_text('\n'.join(sitemap) + '\n', encoding='utf-8')
    (WEB / 'robots.txt').write_text(f'User-agent: *\nAllow: /\n\nSitemap: {SITE}sitemap.xml\n', encoding='utf-8')
    print(f'{len(venues)} páginas de lugares (lugares/<nome>.html), lugares/index.html, sitemap.xml ({len(urls)} endereços) e robots.txt')


if __name__ == '__main__':
    main()
