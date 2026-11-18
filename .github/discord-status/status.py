"""Domain OS — the live status card of the Discord channel "00・status".

Run by .github/workflows/discord-status.yml every hour. Reads the latest GitHub release (versions, date), the
Discord member counts and the site's availability, draws a HUD-style card (Pillow) and puts it into the channel:
the bot's own message there is edited, or posted the first time. Needs the secret DISCORD_TOKEN.
"""
import io, json, os, re, sys, time, urllib.request, urllib.error, uuid
from datetime import datetime, timezone, timedelta
from PIL import Image, ImageDraw, ImageFont, ImageFilter

GUILD = '1572225088340889802'
CHANNEL = '1572635221029945365'
REPO = '6kane1/DomainOS'
SITE = 'https://6kane1.github.io/DomainOS/'
HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = os.environ.get('DISCORD_TOKEN', '').strip()
API = 'https://discord.com/api/v10'
MSK = timezone(timedelta(hours=3))

BG, PANEL, LINE, LINE2 = (6, 6, 8), (14, 15, 19), (36, 37, 44), (51, 52, 61)
FG, TEXT, DIM, FAINT = (230, 232, 236), (196, 200, 207), (140, 146, 156), (94, 100, 109)
PINK, SILVER, OK, WARN = (244, 182, 203), (201, 206, 214), (139, 214, 160), (232, 194, 122)


def http(url, method='GET', data=None, headers=None, ctype=None):
    h = {'User-Agent': 'DomainOS-status (github actions)'}
    h.update(headers or {})
    if ctype: h['Content-Type'] = ctype
    for _ in range(5):
        req = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read()
                return r.status, body
        except urllib.error.HTTPError as e:
            body = e.read()
            if e.code == 429:
                time.sleep(json.loads(body or b'{}').get('retry_after', 2) + 0.5); continue
            return e.code, body
        except Exception:
            time.sleep(3)
    return 0, b''


def discord(method, path, payload=None, raw=None, ctype='application/json'):
    data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
    st, body = http(API + path, method, data, {'Authorization': 'Bot ' + TOKEN}, ctype if data is not None else None)
    if st >= 300 or st == 0:
        raise RuntimeError(f'{method} {path}: {st} {body[:300]!r}')
    return json.loads(body) if body else None


def facts():
    f = {'playbook': '?', 'toolbox': '?', 'released': None, 'members': None, 'online': None, 'site': False}
    st, body = http(f'https://api.github.com/repos/{REPO}/releases/latest', headers={'Accept': 'application/vnd.github+json'})
    if st == 200:
        rel = json.loads(body)
        name = rel.get('name') or rel.get('tag_name') or ''
        m = re.search(r'Domain OS\s+([\d.]+)', name); f['playbook'] = m.group(1) if m else rel.get('tag_name', '?').lstrip('v')
        m = re.search(r'Toolbox\s+([\d.]+)', name); f['toolbox'] = m.group(1) if m else '?'
        f['released'] = datetime.fromisoformat(rel['published_at'].replace('Z', '+00:00'))
    g = discord('GET', f'/guilds/{GUILD}?with_counts=true')
    f['members'], f['online'] = g.get('approximate_member_count'), g.get('approximate_presence_count')
    st, _ = http(SITE)
    f['site'] = st == 200
    return f


def font(name, size):
    return ImageFont.truetype(os.path.join(HERE, 'fonts', name), size)


def card(f):
    S = 2; W, H = 1600, 520
    im = Image.new('RGB', (W * S, H * S), BG); d = ImageDraw.Draw(im)
    mono, monoB = font('JetBrainsMono-Medium.ttf', 22 * S), font('JetBrainsMono-SemiBold.ttf', 22 * S)
    big = font('Inter-SemiBold.ttf', 64 * S); mid = font('Inter-SemiBold.ttf', 40 * S); small = font('Inter-Regular.ttf', 24 * S)
    # faint grid
    for x in range(0, W * S, 40 * S): d.line([(x, 0), (x, H * S)], fill=(12, 12, 15))
    for y in range(0, H * S, 40 * S): d.line([(0, y), (W * S, y)], fill=(12, 12, 15))

    def caps(x, y, text, fill=DIM, f_=mono, gap=0.22):
        for ch in text:
            d.text((x, y), ch, font=f_, fill=fill); x += f_.getlength(ch) + f_.size * gap
        return x

    def panel(x0, y0, x1, y1):
        d.rectangle([x0 * S, y0 * S, x1 * S, y1 * S], fill=PANEL, outline=LINE, width=S)
        L = 14 * S
        d.line([(x0 * S, y0 * S), (x0 * S + L, y0 * S)], fill=PINK, width=2 * S); d.line([(x0 * S, y0 * S), (x0 * S, y0 * S + L)], fill=PINK, width=2 * S)
        d.line([(x1 * S, y1 * S), (x1 * S - L, y1 * S)], fill=PINK, width=2 * S); d.line([(x1 * S, y1 * S), (x1 * S, y1 * S - L)], fill=PINK, width=2 * S)

    # header: logo mark + caption
    lx, ly, ls = 56 * S, 48 * S, 34 * S
    mark = Image.new('RGBA', (ls, ls)); md = ImageDraw.Draw(mark)
    md.polygon([(0, 0), (ls, 0), (0, ls)], fill=PINK + (255,)); md.polygon([(ls, 0), (ls, ls), (0, ls)], fill=SILVER + (255,))
    mask = Image.new('L', (ls, ls), 0); ImageDraw.Draw(mask).polygon([(0, 0), (ls, 0), (ls, ls), (int(ls * .3), ls), (0, int(ls * .7))], fill=255)
    im.paste(mark, (lx, ly), mask)
    caps(lx + ls + 20 * S, ly + 4 * S, 'DOMAIN OS  ·  STATUS', SILVER, monoB)
    now = datetime.now(MSK)
    t = f'updated {now:%d.%m %H:%M} MSK · обновлено'
    d.text((W * S - 56 * S - small.getlength(t), ly + 4 * S), t, font=small, fill=FAINT)

    # versions panel
    panel(56, 120, 760, 460)
    caps(84 * S, 146 * S, '▍ CURRENT · ТЕКУЩАЯ ВЕРСИЯ', DIM)
    d.text((84 * S, 190 * S), f'Domain OS {f["playbook"]}', font=big, fill=FG)
    d.text((84 * S, 272 * S), f'Toolbox {f["toolbox"]}', font=mid, fill=PINK)
    d.text((84 * S, 338 * S), 'Windows 11 Pro · 25H2 / 26H2', font=small, fill=TEXT)
    if f['released']:
        days = (datetime.now(timezone.utc) - f['released']).days
        ago = 'today · сегодня' if days == 0 else f'{days} d ago · {days} дн. назад'
        d.text((84 * S, 384 * S), f'released {f["released"].astimezone(MSK):%d.%m.%Y} — {ago}', font=small, fill=DIM)

    # tiles
    def tile(x0, y0, x1, y1, cap, value, unit, color):
        panel(x0, y0, x1, y1)
        caps((x0 + 26) * S, (y0 + 26) * S, cap, DIM, font('JetBrainsMono-Medium.ttf', 18 * S), 0.14)
        d.text(((x0 + 26) * S, (y0 + 62) * S), value, font=big, fill=color)
        d.text(((x0 + 26) * S + big.getlength(value) + 14 * S, (y0 + 92) * S), unit, font=small, fill=DIM)
    tile(790, 120, 1150, 280, '▍ MEMBERS · УЧАСТНИКИ', str(f['members'] or '—'), 'people', FG)
    tile(1180, 120, 1544, 280, '▍ ONLINE · В СЕТИ', str(f['online'] or '—'), 'now', OK)
    panel(790, 300, 1544, 460)
    caps(816 * S, 324 * S, '▍ WEBSITE · САЙТ', DIM)
    ok = f['site']
    dot = OK if ok else WARN
    d.ellipse([816 * S, 372 * S, 836 * S, 392 * S], fill=dot)
    d.text((852 * S, 362 * S), ('online' if ok else 'not responding') + ' · ' + ('работает' if ok else 'не отвечает'), font=mid, fill=FG if ok else WARN)
    d.text((816 * S, 414 * S), '6kane1.github.io/DomainOS', font=small, fill=DIM)

    im = im.resize((W, H), Image.LANCZOS)
    b = io.BytesIO(); im.save(b, 'PNG', optimize=True)
    return b.getvalue()


def main():
    if not TOKEN: sys.exit('DISCORD_TOKEN is not set')
    f = facts(); png = card(f)
    if '--dry' in sys.argv:
        open('status-card.png', 'wb').write(png); print(f); return
    me = discord('GET', '/users/@me')['id']
    mine = [m for m in discord('GET', f'/channels/{CHANNEL}/messages?limit=20') if m['author']['id'] == me]
    payload = {'flags': 1 << 15, 'attachments': [{'id': 0, 'filename': 'status.png'}], 'components': [
        {'type': 12, 'items': [{'media': {'url': 'attachment://status.png'}, 'description': 'Domain OS status'}]},
        {'type': 17, 'accent_color': 0xF4B6CB, 'components': [
            {'type': 10, 'content': '🇬🇧 This card updates itself every hour: version, members, website status.\n🇷🇺 Карточка обновляется сама каждый час: версия, участники, состояние сайта.'},
            {'type': 1, 'components': [
                {'type': 2, 'style': 5, 'label': 'Website · Сайт', 'url': SITE},
                {'type': 2, 'style': 5, 'label': 'Install guide', 'url': SITE + 'install.html'},
                {'type': 2, 'style': 5, 'label': 'Инструкция (RU)', 'url': SITE + 'ru/install.html'},
                {'type': 2, 'style': 5, 'label': 'GitHub', 'url': f'https://github.com/{REPO}/releases/latest'}]}]}]}
    b = uuid.uuid4().hex
    raw = b''.join([f'--{b}\r\nContent-Disposition: form-data; name="payload_json"\r\nContent-Type: application/json\r\n\r\n'.encode(),
                    json.dumps(payload).encode(), b'\r\n',
                    f'--{b}\r\nContent-Disposition: form-data; name="files[0]"; filename="status.png"\r\nContent-Type: image/png\r\n\r\n'.encode(),
                    png, f'\r\n--{b}--\r\n'.encode()])
    ct = f'multipart/form-data; boundary={b}'
    if mine:
        discord('PATCH', f'/channels/{CHANNEL}/messages/{mine[-1]["id"]}', raw=raw, ctype=ct); print('edited', mine[-1]['id'], f)
        for extra in mine[:-1]: discord('DELETE', f'/channels/{CHANNEL}/messages/{extra["id"]}')
    else:
        m = discord('POST', f'/channels/{CHANNEL}/messages', raw=raw, ctype=ct); print('posted', m['id'], f)


if __name__ == '__main__':
    main()
