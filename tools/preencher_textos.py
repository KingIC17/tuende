#!/usr/bin/env python3
"""Preenche no HTML de web/index.html os textos em português, os ícones e o botão do Kamba.

A app escreve estes textos por JavaScript (data-i18n, data-i18n-placeholder, data-i18n-aria, data-icon).
Como o script fica no fim de um ficheiro grande, o navegador desenha a página antes de o correr: os
botões aparecem vazios e depois "saltam" quando o texto chega, o que piora a experiência e o Google
(Cumulative Layout Shift). Com os textos já no HTML, a primeira imagem da página é a final e o
JavaScript só volta a escrever o mesmo texto (ou o de outra língua).

Voltar a correr depois de mudar textos de I18N.pt, ícones ou KAMBA_TEXT, e copiar para a app do iPhone:

    python3 tools/preencher_textos.py
    cp web/index.html ios/ANGOLIVE/index.html
"""
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
from gerar_paginas import js_value  # noqa: E402

PAGE = ROOT / 'web' / 'index.html'


def literal(source, name):
    start = source.index('{', source.index(f'const {name} = {{'))
    end = source.index('\n        };', start) + len('\n        }')
    return js_value(source[start:end])


def main():
    source = PAGE.read_text(encoding='utf-8')
    pt = literal(source, 'I18N')['pt']
    icons = literal(source, 'ICONS')
    kamba = literal(source, 'KAMBA_TEXT')['pt']

    def text(key):
        if key not in pt:
            raise SystemExit(f'Texto em falta em I18N.pt: {key}')
        return re.sub(r'\{\w+\}', '', pt[key])

    body_start = source.index('<body>')
    body_end = source.index('<script', body_start)
    head, body, tail = source[:body_start], source[body_start:body_end], source[body_end:]
    counts = {'textos': 0, 'placeholders': 0, 'aria': 0, 'ícones': 0}

    def fill_text(m):
        counts['textos'] += 1
        return f'{m.group(1)}{html.escape(text(m.group(3)), quote=False)}{m.group(5)}'
    body = re.sub(r'(<(\w+)\b[^>]*\sdata-i18n="([^"]+)"[^>]*>)([^<]*)(</\2>)', fill_text, body)

    def set_attr(tag, attr, value):
        value = html.escape(value, quote=True)
        if re.search(rf'\s{attr}="[^"]*"', tag):
            return re.sub(rf'(\s{attr}=)"[^"]*"', lambda m: f'{m.group(1)}"{value}"', tag)
        return tag[:-1] + f' {attr}="{value}">' if not tag.endswith('/>') else tag[:-2] + f' {attr}="{value}"/>'

    def fill_placeholder(m):
        counts['placeholders'] += 1
        return set_attr(m.group(0), 'placeholder', text(m.group(1)))
    body = re.sub(r'<[^>]*\sdata-i18n-placeholder="([^"]+)"[^>]*>', fill_placeholder, body)

    def fill_aria(m):
        counts['aria'] += 1
        return set_attr(m.group(0), 'aria-label', text(m.group(1)))
    body = re.sub(r'<[^>]*\sdata-i18n-aria="([^"]+)"[^>]*>', fill_aria, body)

    def fill_icon(m):
        name = m.group(2)
        if name not in icons:
            raise SystemExit(f'Ícone em falta em ICONS: {name}')
        counts['ícones'] += 1
        return f'{m.group(1)}<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">{icons[name]}</svg></span>'
    body = re.sub(r'(<span\b[^>]*\sdata-icon="([^"]+)"[^>]*>)(?:<svg class="icon"[^>]*>.*?</svg>)?</span>', fill_icon, body)

    label = html.escape(re.sub(r'\{\w+\}', '', kamba['launch']), quote=False)
    body, n = re.subn(r'(<span class="kamba-btn-label" id="kambaBtnLabel">)[^<]*(</span>)', lambda m: f'{m.group(1)}{label}{m.group(2)}', body)
    if n != 1:
        raise SystemExit('Botão do Kamba não encontrado')

    PAGE.write_text(head + body + tail, encoding='utf-8')
    print(', '.join(f'{v} {k}' for k, v in counts.items()) + ', botão do Kamba')


if __name__ == '__main__':
    main()
