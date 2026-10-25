"""Ementas do menus.ao -> preços de pratos no Tuende (MENUS_AO e «Pratos de Angola», DISHES).

Uso (a partir da pasta ANGOLIVE):
    python3 tools/ementas/ementas.py            # lê o menus.ao de novo (cerca de 15 minutos, devagar) e atualiza a app
    python3 tools/ementas/ementas.py --cache    # usa a última leitura guardada em tools/ementas/cache/
    python3 tools/ementas/ementas.py --ver      # lê o menus.ao e só mostra o que mudaria (não altera a app)

O que faz:
  1. Lê a lista de restaurantes do menus.ao (serviço da Delta Cafés; as ementas são geridas pelos próprios restaurantes)
     e, de cada um, só as categorias de comida (sem bebidas), com meio segundo entre pedidos.
  2. Junta os preços: MENUS_AO para os restaurantes que são lugares do Tuende (MESMO_LUGAR, verificado à mão pelo
     nome e pela morada) e, para cada prato de pratos.py, os restaurantes que o têm na ementa.
  3. Escreve as três linhas MENUS_AO, DISHES e DISHES_CHECKED em web/index.html e na cópia do iPhone.
     Se algum valor mudar mais de 50% num lugar, avisa (pode ser um erro na ementa) mas escreve na mesma.
Depois: verificar na app (página Pratos de Angola e um lugar com ementa) e publicar os dois index.html.
"""
import html
import json
import re
import subprocess
import sys
import time
import unicodedata
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
from pratos import DISHES  # noqa: E402

CACHE = HERE / 'cache'
APPS = [ROOT / 'web' / 'index.html', ROOT / 'ios' / 'ANGOLIVE' / 'index.html']
BASE = 'https://www.menus.ao/'

# Restaurantes do menus.ao que são o mesmo lugar no Tuende (id). Acrescentar aqui quando se junta um lugar novo.
MESMO_LUGAR = {
    'lookal-mar': 4, 'lookal-beach-club': 5, 'otto-luanda': 196, 'clube-s': 209, 'bar-terrace-skyna': 221,
    'o-almeida': 232, 'bar-da-amizade': 233, 'tia-maria': 234, 'pontovip': 235,
    'seven-restaurante': 237, 'solar-pinguim-restaurante-e-pastelaria-lda': 238,
}

DRINKS = re.compile(r'agua|cerveja|champagne|cocktail|cognac|espumante|gin|licor|refrigerante|rum|sangri|sumo|vermute|vinho|vodka|whisk|aguardente|alergeno|garrafeira|cafetaria|bebida|cha-|cafe-|cafes|shot|tequila|bourbon|drink|wine|beer|batido|smoothie|energetic|digestiv|aperitiv|tabaco|charuto|cigar|narguil|shisha|hookah|barbearia|unha|estetica', re.I)


def get(url):
    time.sleep(0.5)
    r = subprocess.run(['curl', '-sL', '--max-time', '30', '-A', 'Mozilla/5.0 (Tuende; contacto@tuende.app)', url], capture_output=True)
    return r.stdout.decode('utf-8', 'replace')


def text(s):
    return html.unescape(re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', s))).strip()


def crawl():
    listing = get(BASE + 'restaurantes')
    names, entries = {}, []
    for m in re.finditer(r'href="https://www\.menus\.ao/([a-z0-9-]+)"[^>]*>(.*?)</a>', listing, re.S):
        slug, inner = m.group(1), m.group(2)
        if slug in ('restaurantes', 'aderir') or not text(inner) or slug in names:
            continue
        title = re.search(r'destaque-titulo">(.*?)</div>\s*<div[^>]*>(.*?)</div>', inner, re.S)
        if title:
            addr, _, city = text(title.group(2)).partition(' | ')
            names[slug] = {'name': text(title.group(1)), 'address': addr, 'city': city}
        else:
            names[slug] = {'name': text(inner), 'address': '', 'city': ''}
        entries.append((slug, text(inner)))
    if len(entries) < 50:
        sys.exit(f'A lista do menus.ao só tem {len(entries)} restaurantes: o site pode ter mudado. Nada foi alterado.')
    result = []
    for slug, label in entries:
        menu = get(f'{BASE}{slug}/menu')
        cats = sorted(set(re.findall(rf'href="https://www\.menus\.ao/{re.escape(slug)}/([a-z0-9-]+)"', menu)) - {'menu', 'contactos'})
        rest = {'slug': slug, 'label': label, 'categories': cats, 'items': []}
        for c in [c for c in cats if not DRINKS.search(c)]:
            page = get(f'{BASE}{slug}/{c}')
            sub = ''
            for row in re.finditer(r'<div class="col subcategoria">\s*(.*?)\s*</div>|data-nome="([^"]*)" data-descricao="([^"]*)" data-preco="([^"]*)"', page, re.S):
                if row.group(1) is not None:
                    sub = text(row.group(1))
                    continue
                rest['items'].append({'cat': c, 'sub': sub, 'name': html.unescape(row.group(2)).strip(), 'desc': html.unescape(row.group(3)).strip(), 'price': html.unescape(row.group(4)).strip()})
        result.append(rest)
        print(len(result), slug, len(rest['items']), 'pratos', flush=True)
    CACHE.mkdir(exist_ok=True)
    json.dump(result, open(CACHE / 'menus.json', 'w', encoding='utf-8'), ensure_ascii=False)
    json.dump(names, open(CACHE / 'menus_names.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    return result, names


def norm(s):
    return unicodedata.normalize('NFD', s.lower()).encode('ascii', 'ignore').decode()


def kz(price):
    digits = re.sub(r'[^\d,]', '', price).split(',')[0]
    return int(digits) if digits else 0


CITY_FIX = {'uige': 'Uíge', 'cacuaco': 'Cacuaco', 'luanda': 'Luanda', 'lubango': 'Lubango', 'benguela': 'Benguela', 'namibe': 'Namibe', 'luena': 'Luena', 'soyo': 'Soyo', 'cabinda': 'Cabinda', 'mocamedes': 'Moçâmedes', 'talatona': 'Talatona', 'maianga': 'Maianga', 'viana': 'Viana', 'maculusso': 'Maculusso', 'futungo de belas': 'Futungo de Belas'}
NOTE = re.compile(r'pessoa|encomend|anteced|\bkg\b|dose|meia|\bpax\b', re.I)
MAIN = re.compile(r'prato|principa|carne|peixe|grelh|marisc|nacion|tradicion|massa|pizza|hamb|burg|frango|bife|espeto|churras|petisco|entrada|sopa|salada|sandu|menu|kids|infantil|vegetar|sushi|rodizio|bacalhau|polvo|camar|lagost|feijoada|caldeirad|refeic|sugest', re.I)
SKIP = re.compile(r'sobremesa|doce|gelado|bolo|pastel|cafe|bebida|extra|guarni|acompanh|molho|alergeno|couvert', re.I)
DRINK_ITEM = re.compile(r'\bgin\b|vodka|whisk|cerveja|vinho|sumo|agua|refrigerante|cocktail|champanhe|licor|sangria|batido|cafe\b|cha\b', re.I)


def clean_name(name):
    # Sem numeração («1. Bitoque»), sem espaços a mais e sem tudo em maiúsculas («BIFE GRELHADO» -> «Bife grelhado»).
    name = re.sub(r'\s+', ' ', re.sub(r'^\d+\s*[.)-]\s*', '', name)).strip()
    return name[0] + name[1:].lower() if name.isupper() and len(name) > 4 else name


def build(menus, names, checked):
    def label_parts(rest):
        n = names.get(rest['slug'], {'name': rest['label'].split('|')[0].strip(), 'city': ''})
        name = n['name'].title() if n['name'].isupper() else n['name']
        name = re.sub(r',?\s+Lda\.?$', '', name).strip()
        city = n.get('city', '').strip()
        city = CITY_FIX.get(norm(city), city if city and not city.isupper() else city.title())
        return name, city

    def note_of(it):
        parts = [x.strip(' .') for x in re.split(r'<br\s*/?>|\.\s', it['desc'] or '') if x.strip(' .')]
        note = next((x for x in parts if NOTE.search(norm(x)) and len(x) <= 90), '')
        return '' if note and norm(note) in norm(it['name']) else note

    dish_where = {d['id']: [] for d in DISHES}
    menus_ao = {}
    for rest in menus:
        # Nomes sem a numeração da ementa («1. Bitoque» -> «Bitoque»).
        items = [dict(it, name=clean_name(it['name']), kz=kz(it['price']), note=note_of(it)) for it in rest['items'] if it['name'] and kz(it['price']) > 0]
        if not items:
            continue
        name, city = label_parts(rest)
        vid = MESMO_LUGAR.get(rest['slug'])
        for d in DISHES:
            rx = re.compile(d['match'], re.I)
            hits = [it for it in items if rx.search(norm(it['name']))]
            if d['id'] == 'moamba':
                hits = [it for it in hits if 'ginguba' not in norm(it['name'])]
            if d['id'] == 'funge':
                hits = [it for it in hits if len(norm(it['name']).split()) <= 4]
            for it in hits[:2]:
                dish_where[d['id']].append({'slug': rest['slug'], 'label': name, 'city': city, 'venue': vid, 'item': it['name'], 'kz': it['kz'], 'note': it['note']})
        if vid:
            angolan = [it for it in items if any(re.search(d['match'], norm(it['name']), re.I) for d in DISHES) and not DRINK_ITEM.search(norm(it['name']))]
            mains = [it for it in items if MAIN.search(norm(it['cat'] + ' ' + it['sub'] + ' ' + it['name'])) and not SKIP.search(norm(it['cat'] + ' ' + it['sub']))]
            mains = [it for it in mains if not DRINK_ITEM.search(norm(it['name'] + ' ' + it['sub']))]
            # Variedade: pratos angolanos primeiro, depois um prato de cada secção da ementa, à vez.
            by_sub = {}
            for it in mains:
                by_sub.setdefault(it['sub'] or it['cat'], []).append(it)
            pick = list(angolan)
            while len(pick) < 12 and any(by_sub.values()):
                for key in list(by_sub):
                    if by_sub[key] and len(pick) < 12:
                        it = by_sub[key].pop(0)
                        if it not in pick:
                            pick.append(it)
            pick = pick[:12] or items[:12]
            plain = [it for it in mains if not it['note']] or [it for it in items if not it['note']] or items
            prices = sorted(it['kz'] for it in plain)
            # O que custa a maioria dos pratos: os 80% do meio.
            lo, hi = prices[int(len(prices) * 0.1)], prices[min(len(prices) - 1, int(len(prices) * 0.9))]
            menus_ao[vid] = {'slug': rest['slug'], 'label': name, 'checked': checked, 'total': len(items), 'min': lo, 'max': hi,
                             'items': [[it['name'], it['kz'], (it['sub'] or it['cat'].replace('-amp-', ' e ').replace('-', ' ')).replace('&amp;', '&'), it['note']] for it in pick]}
    dishes = []
    for d in DISHES:
        seen, uniq = set(), []
        for w in sorted(dish_where[d['id']], key=lambda x: (x['kz'], x['label'])):
            if w['slug'] not in seen:
                seen.add(w['slug'])
                uniq.append(w)
        dishes.append({'id': d['id'], 'name': d['name'], 'desc': d['desc'], 'sources': d['sources'], 'where': uniq[:12], 'count': len(uniq)})
    return menus_ao, dishes


def write(menus_ao, dishes, checked, dry=False):
    lines = (f"        const MENUS_AO = {json.dumps({str(k): v for k, v in menus_ao.items()}, ensure_ascii=False)};\n"
             f"        const DISHES = {json.dumps(dishes, ensure_ascii=False)};\n"
             f"        const DISHES_CHECKED = '{checked}';\n")
    for app in APPS:
        src = app.read_text(encoding='utf-8')
        old = re.search(r"        const MENUS_AO = .*\n        const DISHES = .*\n        const DISHES_CHECKED = '[\d-]+';\n", src)
        if not old:
            sys.exit(f'Não encontrei as linhas MENUS_AO/DISHES em {app}. Nada foi alterado.')
        before = json.loads(re.search(r'const MENUS_AO = (.*);\n', old.group(0)).group(1))
        for vid, m in menus_ao.items():
            b = before.get(str(vid))
            if b and (abs(m['min'] - b['min']) > 0.5 * b['min'] or abs(m['max'] - b['max']) > 0.5 * b['max']):
                print(f'AVISO: lugar {vid} ({m["label"]}) passou de {b["min"]}-{b["max"]} para {m["min"]}-{m["max"]} Kz. Confirme a ementa.')
        if dry:
            for vid, m in menus_ao.items():
                b = before.get(str(vid))
                old = f'{b["min"]}-{b["max"]} Kz, {b["total"]} itens' if b else 'novo'
                print(f'  lugar {vid} {m["label"]}: {old} -> {m["min"]}-{m["max"]} Kz, {m["total"]} itens')
            return
        app.write_text(src[:old.start()] + lines + src[old.end():], encoding='utf-8')
        print('escrito', app)


if __name__ == '__main__':
    if '--cache' in sys.argv:
        menus = json.load(open(CACHE / 'menus.json', encoding='utf-8'))
        names = json.load(open(CACHE / 'menus_names.json', encoding='utf-8'))
        checked = '2026-10-25' if '--data-original' in sys.argv else date.today().isoformat()
    else:
        menus, names = crawl()
        checked = date.today().isoformat()
    menus_ao, dishes = build(menus, names, checked)
    for d in dishes:
        print(d['id'], d['count'], 'restaurantes')
    print('lugares com ementa:', {k: (v['slug'], v['total'], v['min'], v['max']) for k, v in menus_ao.items()})
    write(menus_ao, dishes, checked, dry='--ver' in sys.argv)
