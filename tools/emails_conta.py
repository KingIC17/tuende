"""Gera os modelos de email das contas (Supabase Auth) com a marca Tuende, em pt/en/fr/es.

O Supabase escolhe a língua com {{ .Data.lang }} (a app guarda a língua da pessoa ao criar a conta); sem língua, português.
Saída: supabase/emails/<modelo>.html (para colar em Authentication > Emails > Templates), <modelo>.subject.txt (assunto)
e pre-visualizacao/<modelo>-<língua>.html (para ver no navegador; não vai para o Supabase).
Correr: python3 tools/emails_conta.py
"""
import html
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'supabase' / 'emails'
PREVIEW = OUT / 'pre-visualizacao'
LOGO = 'https://tuende.app/icon-192.png'
LANGS = ['pt', 'en', 'fr', 'es']

FOOT = {
    'pt': ('Descubra onde ir em Angola', 'Recebeu este email porque este endereço foi usado em tuende.app.'),
    'en': ('Find where to go in Angola', 'You received this email because this address was used on tuende.app.'),
    'fr': ('Trouvez où aller en Angola', 'Vous recevez cet e-mail parce que cette adresse a été utilisée sur tuende.app.'),
    'es': ('Descubra adónde ir en Angola', 'Recibe este email porque esta dirección se usó en tuende.app.'),
}
HELLO = {'pt': ('Olá, {}!', 'Olá!'), 'en': ('Hello, {}!', 'Hello!'), 'fr': ('Bonjour {} !', 'Bonjour !'), 'es': ('¡Hola, {}!', '¡Hola!')}
LINK_NOTE = {
    'pt': 'Se o botão não funcionar, copie este endereço para o navegador:',
    'en': 'If the button does not work, copy this address into your browser:',
    'fr': 'Si le bouton ne fonctionne pas, copiez cette adresse dans votre navigateur :',
    'es': 'Si el botón no funciona, copie esta dirección en su navegador:',
}

TEMPLATES = {
    'confirm-signup': {
        'subject': {'pt': 'Confirme a sua conta no Tuende', 'en': 'Confirm your Tuende account', 'fr': 'Confirmez votre compte Tuende', 'es': 'Confirme su cuenta de Tuende'},
        'title': {'pt': 'Confirme o seu email', 'en': 'Confirm your email', 'fr': 'Confirmez votre e-mail', 'es': 'Confirme su email'},
        'body': {
            'pt': 'Obrigado por criar uma conta no Tuende, o guia para descobrir onde ir em Angola. Toque no botão para confirmar o seu email e ativar a conta.',
            'en': 'Thank you for creating a Tuende account, the guide to finding where to go in Angola. Tap the button to confirm your email and activate your account.',
            'fr': 'Merci d’avoir créé un compte Tuende, le guide pour trouver où aller en Angola. Touchez le bouton pour confirmer votre e-mail et activer votre compte.',
            'es': 'Gracias por crear una cuenta en Tuende, la guía para descubrir adónde ir en Angola. Toque el botón para confirmar su email y activar la cuenta.',
        },
        'button': {'pt': 'Confirmar email', 'en': 'Confirm email', 'fr': 'Confirmer l’e-mail', 'es': 'Confirmar email'},
        'ignore': {
            'pt': 'Se não criou esta conta, ignore este email: sem confirmação a conta não fica ativa.',
            'en': 'If you did not create this account, ignore this email: without confirmation the account stays inactive.',
            'fr': 'Si vous n’avez pas créé ce compte, ignorez cet e-mail : sans confirmation, le compte reste inactif.',
            'es': 'Si no creó esta cuenta, ignore este email: sin confirmación la cuenta no se activa.',
        },
        'url': '{{ .ConfirmationURL }}',
    },
    'reset-password': {
        'subject': {'pt': 'Nova palavra-passe no Tuende', 'en': 'Your new Tuende password', 'fr': 'Nouveau mot de passe Tuende', 'es': 'Nueva contraseña de Tuende'},
        'title': {'pt': 'Escolha uma nova palavra-passe', 'en': 'Choose a new password', 'fr': 'Choisissez un nouveau mot de passe', 'es': 'Elija una nueva contraseña'},
        'body': {
            'pt': 'Pediu para mudar a palavra-passe da sua conta no Tuende. Toque no botão para escolher uma nova.',
            'en': 'You asked to change the password of your Tuende account. Tap the button to choose a new one.',
            'fr': 'Vous avez demandé à changer le mot de passe de votre compte Tuende. Touchez le bouton pour en choisir un nouveau.',
            'es': 'Pidió cambiar la contraseña de su cuenta de Tuende. Toque el botón para elegir una nueva.',
        },
        'button': {'pt': 'Escolher palavra-passe', 'en': 'Choose password', 'fr': 'Choisir un mot de passe', 'es': 'Elegir contraseña'},
        'ignore': {
            'pt': 'Se não foi você, ignore este email: a palavra-passe continua a mesma.',
            'en': 'If this was not you, ignore this email: your password stays the same.',
            'fr': 'Si ce n’était pas vous, ignorez cet e-mail : votre mot de passe reste le même.',
            'es': 'Si no fue usted, ignore este email: la contraseña sigue siendo la misma.',
        },
        'url': '{{ .ConfirmationURL }}',
    },
    'change-email': {
        'subject': {'pt': 'Confirme o novo email no Tuende', 'en': 'Confirm your new Tuende email', 'fr': 'Confirmez votre nouvel e-mail Tuende', 'es': 'Confirme su nuevo email en Tuende'},
        'title': {'pt': 'Confirme o novo email', 'en': 'Confirm your new email', 'fr': 'Confirmez votre nouvel e-mail', 'es': 'Confirme su nuevo email'},
        'body': {
            'pt': 'Pediu para mudar o email da sua conta no Tuende para {{ .NewEmail }}. Toque no botão para confirmar.',
            'en': 'You asked to change the email of your Tuende account to {{ .NewEmail }}. Tap the button to confirm.',
            'fr': 'Vous avez demandé à changer l’e-mail de votre compte Tuende pour {{ .NewEmail }}. Touchez le bouton pour confirmer.',
            'es': 'Pidió cambiar el email de su cuenta de Tuende a {{ .NewEmail }}. Toque el botón para confirmar.',
        },
        'button': {'pt': 'Confirmar novo email', 'en': 'Confirm new email', 'fr': 'Confirmer le nouvel e-mail', 'es': 'Confirmar nuevo email'},
        'ignore': {
            'pt': 'Se não foi você, ignore este email e mude a palavra-passe da conta.',
            'en': 'If this was not you, ignore this email and change your account password.',
            'fr': 'Si ce n’était pas vous, ignorez cet e-mail et changez le mot de passe du compte.',
            'es': 'Si no fue usted, ignore este email y cambie la contraseña de la cuenta.',
        },
        'url': '{{ .ConfirmationURL }}',
    },
}

# Go templates (Supabase): variables are untyped; "with" skips the block when .Data.lang is missing, so "eq" only ever
# compares strings.
PICK = '{{ $l := "pt" }}{{ with .Data.lang }}{{ $l = . }}{{ end }}'


def e(text):
    """Escape for HTML but keep Go template actions ({{ ... }}) intact."""
    parts = text.split('{{')
    out = html.escape(parts[0], quote=False)
    for p in parts[1:]:
        action, rest = p.split('}}', 1)
        out += '{{' + action + '}}' + html.escape(rest, quote=False)
    return out


def block(t, lang, preview_name=None):
    hello_named, hello_plain = HELLO[lang]
    if preview_name is None:
        hello = '{{ with .Data.display_name }}' + e(hello_named.format('{{ . }}')) + '{{ else }}' + e(hello_plain) + '{{ end }}'
    else:
        hello = e(hello_named.format(preview_name))
    tagline, why = FOOT[lang]
    url = t['url']
    font = "font-family:Arial,Helvetica,sans-serif;"
    return f'''<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#F6F4F1" style="background-color:#F6F4F1;">
<tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;">
<tr><td bgcolor="#FFFFFF" style="background-color:#FFFFFF;border-radius:16px 16px 0 0;padding:18px 24px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td style="padding-right:12px;"><img src="{LOGO}" width="44" height="44" alt="" style="display:block;border:0;border-radius:11px;"></td>
<td style="{font}font-size:28px;line-height:30px;font-weight:bold;color:#CE1126;">Tuende</td>
</tr></table>
</td></tr>
<tr><td height="4" bgcolor="#CE1126" style="background-color:#CE1126;font-size:0;line-height:0;">&nbsp;</td></tr>
<tr><td height="4" bgcolor="#FFCB00" style="background-color:#FFCB00;font-size:0;line-height:0;">&nbsp;</td></tr>
<tr><td bgcolor="#FFFFFF" style="background-color:#FFFFFF;border-radius:0 0 16px 16px;padding:24px 24px 28px;">
<p style="margin:0 0 6px;{font}font-size:22px;line-height:28px;font-weight:bold;color:#161618;">{e(t["title"][lang])}</p>
<p style="margin:14px 0 0;{font}font-size:16px;line-height:24px;color:#161618;">{hello}</p>
<p style="margin:8px 0 0;{font}font-size:16px;line-height:24px;color:#161618;">{e(t["body"][lang])}</p>
<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:24px;"><tr>
<td bgcolor="#CE1126" style="background-color:#CE1126;border-radius:12px;">
<a href="{url}" style="display:inline-block;padding:14px 24px;{font}font-size:17px;line-height:20px;font-weight:bold;color:#FFFFFF;text-decoration:none;">{e(t["button"][lang])}</a>
</td></tr></table>
<p style="margin:22px 0 0;{font}font-size:13px;line-height:19px;color:#5C5C66;">{e(LINK_NOTE[lang])}<br><a href="{url}" style="color:#CE1126;word-break:break-all;">{url}</a></p>
<p style="margin:18px 0 0;{font}font-size:14px;line-height:21px;color:#5C5C66;">{e(t["ignore"][lang])}</p>
</td></tr>
<tr><td align="center" style="padding:16px 8px 0;{font}font-size:13px;line-height:19px;color:#5C5C66;">
<b style="color:#CE1126;">Tuende</b> · {e(tagline)} · <a href="https://tuende.app" style="color:#5C5C66;">tuende.app</a><br>{e(why)}
</td></tr>
</table>
</td></tr></table>'''


def by_lang(make):
    """{{ if eq $l "en" }}…{{ else if … }}…{{ else }}(pt){{ end }}"""
    return (PICK + '{{ if eq $l "en" }}' + make('en') + '{{ else if eq $l "fr" }}' + make('fr')
            + '{{ else if eq $l "es" }}' + make('es') + '{{ else }}' + make('pt') + '{{ end }}')


PREVIEW.mkdir(parents=True, exist_ok=True)
for name, t in TEMPLATES.items():
    (OUT / f'{name}.html').write_text(by_lang(lambda l: block(t, l)) + '\n', encoding='utf-8')
    (OUT / f'{name}.subject.txt').write_text(by_lang(lambda l: t['subject'][l]) + '\n', encoding='utf-8')
    for lang in LANGS:
        sample = block(t, lang, preview_name='Ana').replace('{{ .ConfirmationURL }}', 'https://tuende.app/').replace('{{ .NewEmail }}', 'ana@exemplo.ao')
        (PREVIEW / f'{name}-{lang}.html').write_text(
            f'<!DOCTYPE html><html lang="{lang}"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>{html.escape(t["subject"][lang])}</title></head><body style="margin:0;">{sample}</body></html>\n', encoding='utf-8')
print('ok:', ', '.join(TEMPLATES))
