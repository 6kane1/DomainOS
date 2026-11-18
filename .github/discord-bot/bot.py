"""Domain OS Discord helper, run by .github/workflows/discord-bot.yml every 15 minutes (no server of our own).

results forum: a new post with DomainSchedTest results (zip / 7z / summary.txt) gets a reply with a chart: the runs
are grouped by their label (base-1, base-2, S2-1 … → base, S2), every group uses the same number of runs (the first N
by time, N = the smallest group), bar = average, dot = one run. The numbers go to the site's results page (results.json).
help forum: a new post gets a first answer from the FAQ matched by keywords (EN + RU), then a person takes over.
A post is handled once: the bot looks for its own reply in the thread.
Needs the secret DISCORD_TOKEN and the bot's "Message Content" intent (to read attachments).
"""
import io, json, os, re, sys, time, uuid, zipfile, urllib.request, urllib.error, urllib.parse
from datetime import datetime, timezone
from statistics import mean
from PIL import Image, ImageDraw, ImageFont

GUILD = '1572225088340889802'
RESULTS = '1572682487543365843'
HELP = '1572233501518991500'
TOKEN = os.environ.get('DISCORD_TOKEN', '').strip()
OUT_JSON = os.environ.get('RESULTS_JSON', '')            # the site's results/results.json (checked out by the workflow)
HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, '..', 'discord-status', 'fonts')
API = 'https://discord.com/api/v10'
PINK = 0xF4B6CB
DRY = '--dry' in sys.argv


def http(url, method='GET', data=None, headers=None, ctype=None):
    h = {'User-Agent': 'DomainOS-bot (github actions)'}
    h.update(headers or {})
    if ctype: h['Content-Type'] = ctype
    for _ in range(6):
        req = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            body = e.read()
            if e.code == 429:
                time.sleep(json.loads(body or b'{}').get('retry_after', 2) + .5); continue
            return e.code, body
        except Exception:
            time.sleep(3)
    return 0, b''


def dc(method, path, payload=None, raw=None, ctype='application/json'):
    data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
    st, body = http(API + path, method, data, {'Authorization': 'Bot ' + TOKEN}, ctype if data is not None else None)
    if st >= 300 or st == 0:
        raise RuntimeError(f'{method} {path}: {st} {body[:300]!r}')
    return json.loads(body) if body else None


def threads(forum):
    out = [t for t in dc('GET', f'/guilds/{GUILD}/threads/active')['threads'] if t.get('parent_id') == forum]
    return out


def answered(tid, me):
    return any(m['author']['id'] == me for m in dc('GET', f'/channels/{tid}/messages?limit=50'))


def reply(tid, comps, files=()):
    payload = {'flags': 1 << 15, 'components': comps, 'attachments': [{'id': i, 'filename': n} for i, (n, _) in enumerate(files)]}
    if DRY:
        print('DRY reply', tid, json.dumps(comps, ensure_ascii=False)[:600]); return None
    b = uuid.uuid4().hex
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="payload_json"\r\nContent-Type: application/json\r\n\r\n'.encode(), json.dumps(payload).encode(), b'\r\n']
    for i, (n, data) in enumerate(files):
        parts += [f'--{b}\r\nContent-Disposition: form-data; name="files[{i}]"; filename="{n}"\r\nContent-Type: image/png\r\n\r\n'.encode(), data, b'\r\n']
    parts.append(f'--{b}--\r\n'.encode())
    return dc('POST', f'/channels/{tid}/messages', raw=b''.join(parts), ctype=f'multipart/form-data; boundary={b}')


T = lambda s: {'type': 10, 'content': s}
SEP = {'type': 14, 'divider': True, 'spacing': 2}
card = lambda comps: {'type': 17, 'accent_color': PINK, 'components': comps}

# ===================================================================================================================
# results
# ===================================================================================================================


def summaries_from(name, data):
    """All DomainSchedTest summary.txt texts inside an attachment (zip, 7z or a single txt)."""
    out = []
    low = name.lower()
    try:
        if low.endswith('.zip'):
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                for n in z.namelist():
                    if n.lower().endswith('summary.txt') and z.getinfo(n).file_size < 2_000_000:
                        out.append(z.read(n).decode('utf-8-sig', 'replace'))
        elif low.endswith('.7z'):
            import py7zr
            with py7zr.SevenZipFile(io.BytesIO(data), 'r') as z:
                names = [n for n in z.getnames() if n.lower().endswith('summary.txt')]
                for n, bio in (z.read(names) or {}).items():
                    out.append(bio.read().decode('utf-8-sig', 'replace'))
        elif low.endswith('.txt'):
            out.append(data.decode('utf-8-sig', 'replace'))
    except Exception as e:
        print('archive', name, e)
    return [s for s in out if 'Domain SchedTest' in s[:200]]


def parse(s):
    r = {}
    m = re.search(r'Подпись: ([^\r\n]+)', s); r['label'] = m.group(1).strip() if m else 'run'
    m = re.search(r'Дата: ([\d\- :]+)', s); r['date'] = m.group(1).strip() if m else ''
    m = re.search(r'средний FPS ([\d.]+)\s+1% low ([\d.]+)\s+0\.1% low ([\d.]+)', s)
    if not m: return None
    r['fps'], r['low1'], r['low01'] = map(float, m.groups())
    m = re.search(r'Процессор: ([^\r\n]+)', s); r['cpu'] = m.group(1).strip() if m else ''
    m = re.search(r'Windows: ([^\r\n]+)', s); r['windows'] = m.group(1).strip() if m else ''
    m = re.search(r'процесс: (\S+) \(', s); r['game'] = m.group(1) if m else ''
    m = re.search(r'\nDomain OS: [^\r\n]*?(\d+\.\d+\.\d+)', s); r['domainos'] = m.group(1) if m else ''
    return r


def group_of(label):
    # base-1, base 2, base_3, base#4 → base; a label without a separator (S1, D3) is a group of its own
    g = re.sub(r'[\s_\-#]+\(?\d+\)?$', '', label).strip()
    return g or label


def chart(title, groups, n):
    fd = lambda f, s: ImageFont.truetype(os.path.join(FONTS, f), s)
    BG, PANEL, FG, DIM, PINKc, SIL = (11, 12, 16), (16, 17, 22), (236, 237, 240), (150, 154, 164), (244, 182, 203), (170, 174, 186)
    W, H = 2400, 1180
    im = Image.new('RGB', (W, H), BG); d = ImageDraw.Draw(im)
    d.text((80, 56), title[:90], font=fd('Inter-SemiBold.ttf', 50), fill=FG)
    d.text((80, 122), f'{n} run(s) per group · {n} прогон(а) на группу · dot = one run, bar = average', font=fd('Inter-Regular.ttf', 28), fill=DIM)
    d.text((W - 80, 60), 'Domain OS · RESULTS', font=fd('JetBrainsMono-Medium.ttf', 26), fill=PINKc, anchor='ra')
    metrics = [('Average FPS', 'средний FPS', 'fps'), ('1% low FPS', '1% low', 'low1'), ('0.1% low FPS', '0.1% low', 'low01')]
    names = list(groups)
    pw = (W - 160) // 3; top, base = 300, 1010
    best = {k: max(names, key=lambda g: mean(r[k] for r in groups[g])) for _, _, k in metrics}
    for i, (en, ru, key) in enumerate(metrics):
        px = 80 + i * pw
        d.rounded_rectangle((px + 10, top - 100, px + pw - 10, base + 90), radius=22, fill=PANEL)
        d.text((px + pw / 2, top - 82), en, font=fd('Inter-SemiBold.ttf', 32), fill=FG, anchor='ma')
        d.text((px + pw / 2, top - 40), ru + '  ·  higher = better', font=fd('Inter-Regular.ttf', 22), fill=DIM, anchor='ma')
        vals = [[r[key] for r in groups[g]] for g in names]
        mx = max(max(v) for v in vals) * 1.15 or 1
        step = (pw - 80) / len(names); bw = step * 0.62
        Y = lambda v: base - (v / mx) * (base - top)
        for j, (g, vs) in enumerate(zip(names, vals)):
            x = px + 40 + j * step + (step - bw) / 2; m_ = mean(vs)
            col = PINKc if g == best[key] else ((150, 110, 124) if j else SIL)
            d.rectangle((x, Y(m_), x + bw, base), fill=col)
            for k, v in enumerate(vs):
                xx = x + bw / 2 + (k - (len(vs) - 1) / 2) * 12
                d.ellipse((xx - 5, Y(v) - 5, xx + 5, Y(v) + 5), fill=(255, 255, 255), outline=BG, width=2)
            d.text((x + bw / 2, min(Y(m_), min(Y(v) for v in vs)) - 12), f'{m_:.0f}', font=fd('Inter-SemiBold.ttf', 26), fill=FG, anchor='mb')
            d.text((x + bw / 2, base + 16), g[:10], font=fd('JetBrainsMono-Medium.ttf', 22), fill=FG, anchor='ma')
    b = io.BytesIO(); im.save(b, 'PNG', optimize=True); return b.getvalue()


def handle_result(t, me, store):
    starter = dc('GET', f'/channels/{t["id"]}/messages/{t["id"]}')
    runs = []
    for a in starter.get('attachments', []):
        if a.get('size', 0) > 25_000_000: continue
        st, data = http(a['url'])
        if st == 200:
            for s in summaries_from(a['filename'], data):
                r = parse(s)
                if r: runs.append(r)
    if not runs:
        reply(t['id'], [card([T('🇬🇧 No DomainSchedTest runs found in this post. Attach the **zipped `results` folder** (zip or 7z) with all runs — every run folder has a `summary.txt`.\n'
                                '🇷🇺 В посте не нашлось прогонов DomainSchedTest. Приложите **архив папки `results`** (zip или 7z) со всеми прогонами — в каждой папке прогона есть `summary.txt`.')])])
        return
    runs.sort(key=lambda r: r['date'])
    groups = {}
    for r in runs: groups.setdefault(group_of(r['label']), []).append(r)
    groups = dict(list(groups.items())[:10])
    n = min(len(v) for v in groups.values())
    eq = {g: v[:n] for g, v in groups.items()}
    base = next(iter(eq))
    lines = []
    for g, v in eq.items():
        f, l1, l01 = mean(r['fps'] for r in v), mean(r['low1'] for r in v), mean(r['low01'] for r in v)
        if g == base: lines.append(f'`{g:<12}` {f:7.1f} · {l1:6.1f} · {l01:6.1f}')
        else:
            bf = mean(r['fps'] for r in eq[base]); bl = mean(r['low1'] for r in eq[base])
            lines.append(f'`{g:<12}` {f:7.1f} · {l1:6.1f} · {l01:6.1f}   ({(f / bf - 1) * 100:+.1f}% avg, {(l1 / bl - 1) * 100:+.1f}% 1% low)')
    extra = '' if all(len(v) == n for v in groups.values()) else \
        f'\n-# 🇬🇧 Groups had different numbers of runs: the first {n} of each (by time) are compared. · 🇷🇺 В группах разное число прогонов: сравниваются первые {n} в каждой (по времени).'
    hw = runs[0]
    info = ' · '.join(x for x in (hw['cpu'], hw['windows'], hw['game'], ('Domain OS ' + hw['domainos']) if hw['domainos'] else '') if x)
    title = (t.get('name') or 'Results')[:80]
    png = chart(title, eq, n)
    text = (f'## 📊 {title}\n-# {info}\n'
            '🇬🇧 group · average FPS · 1% low · 0.1% low (vs the first group) · 🇷🇺 группа · средний FPS · 1% low · 0.1% low (к первой группе)\n'
            + '\n'.join(lines) + extra +
            '\n-# 🇬🇧 Differences under ~2% are usually noise. · 🇷🇺 Разница меньше ~2% — обычно разброс.')
    m = reply(t['id'], [card([T(text[:3900]), {'type': 12, 'items': [{'media': {'url': 'attachment://chart.png'}}]},
                              T('-# 🗑️ Owner/Admin: react 🗑️ to this message to remove the result from the website. · Owner/Admin: реакция 🗑️ на это сообщение убирает замер с сайта.')])],
              [('chart.png', png)])
    store.append({'thread': t['id'], 'reply': (m or {}).get('id', ''), 'title': title, 'url': f'https://discord.com/channels/{GUILD}/{t["id"]}', 'date': runs[0]['date'][:10],
                  'cpu': hw['cpu'], 'windows': hw['windows'], 'game': hw['game'], 'domainos': hw['domainos'], 'runs': n,
                  'groups': [{'name': g, 'fps': round(mean(r['fps'] for r in v), 1), 'low1': round(mean(r['low1'] for r in v), 1),
                              'low01': round(mean(r['low01'] for r in v), 1)} for g, v in eq.items()]})

# ===================================================================================================================
# help
# ===================================================================================================================


FAQ = [
    (r'as-?3|offline|офлайн|epic', '**Epic Games Launcher offline / AS-3 / failed captcha** · **Epic офлайн / AS-3 / капча**',
     '🇬🇧 This is the internet provider blocking Epic servers, not Windows or Domain OS (check: does it work through a phone hotspot or a VPN?). Sign in once through a VPN with "Remember me".\n'
     '🇷🇺 Это провайдер блокирует серверы Epic, а не Windows или Domain OS (проверка: работает ли через раздачу с телефона или VPN?). Войдите один раз через VPN с «Запомнить меня».'),
    (r'\bhome\b|домашн|edition|редакц|pro only|только pro|halt|останов', '**The install stops at the first step** · **Установка остановилась на первом шаге**',
     '🇬🇧 Domain OS installs on **Windows 11 Pro** only. Check Settings → System → About. On Home: switch to Pro with a Pro key (Settings → System → Activation).\n'
     '🇷🇺 Domain OS ставится только на **Windows 11 Pro**. Проверьте «Параметры → Система → О системе». На Home — перейдите на Pro своим ключом («Параметры → Система → Активация»).'),
    (r'undo|откат|верну|restore|вернуть', '**How to undo** · **Как откатить**',
     '🇬🇧 Start → Domain OS → **Undo Domain OS**, then restart. Toolbox changes: "Undo everything" in Toolbox.\n'
     '🇷🇺 «Пуск» → Domain OS → **Undo Domain OS** и перезагрузка. Изменения Toolbox: «Вернуть всё как было» в Toolbox.'),
    (r'driver|драйвер', '**Drivers** · **Драйверы**',
     '🇬🇧 Graphics and chipset drivers only from the official NVIDIA / AMD / Intel sites, no driver packs. The driver page opens after the first restart.\n'
     '🇷🇺 Драйверы видеокарты и чипсета — только с официальных сайтов NVIDIA / AMD / Intel, без сборников. Страница драйверов открывается после первой перезагрузки.'),
    (r'fps|фпс|lag|лаг|stutter|фриз|рывк', '**FPS / stutter** · **FPS / рывки**',
     '🇬🇧 Toolbox: Auto on, then once "Optimize devices" with the game closed and restart. Steam: Settings → Interface → GPU acceleration in web views off. If the GPU is at 95–100%, average FPS will barely move — that is the card, not Windows.\n'
     '🇷🇺 Toolbox: Auto вкл., затем один раз «Оптимизация устройств» при закрытой игре и перезагрузка. Steam: Настройки → Интерфейс → GPU-ускорение веб-окон выкл. Если видеокарта загружена на 95–100%, средний FPS почти не изменится — это предел карты, а не Windows.'),
    (r'faceit|vanguard|valorant|античит|anti-?cheat|eac|battleye', '**Anti-cheat** · **Античит**',
     '🇬🇧 Domain OS keeps Defender, VBS/Memory Integrity, Secure Boot and TPM as Windows has them. If an anti-cheat refuses: check that TPM and Secure Boot are on in the BIOS and close third-party tools that load drivers.\n'
     '🇷🇺 Domain OS оставляет Defender, VBS/защиту памяти, Secure Boot и TPM как в Windows. Если античит не пускает: проверьте, что TPM и Secure Boot включены в BIOS, и закройте сторонние программы с драйверами.'),
]


def handle_help(t):
    starter = dc('GET', f'/channels/{t["id"]}/messages/{t["id"]}')
    text = ((t.get('name') or '') + ' ' + (starter.get('content') or '')).lower()
    hits = [f for f in FAQ if re.search(f[0], text)]
    body = '\n\n'.join(f'### {h}\n{a}' for _, h, a in hits[:3])
    if not body:
        body = ('🇬🇧 Thanks! While you wait for a reply, please add: playbook and Toolbox versions, `winver`, CPU and GPU, what you did and what happened, and attach `%ProgramData%\\Domain OS\\Logs\\install.log` and `%LOCALAPPDATA%\\DomainScheduler\\log.txt`.\n'
                '🇷🇺 Спасибо! Пока ждёте ответа, добавьте: версии сборки и Toolbox, `winver`, процессор и видеокарту, что делали и что произошло, и приложите `%ProgramData%\\Domain OS\\Logs\\install.log` и `%LOCALAPPDATA%\\DomainScheduler\\log.txt`.')
    reply(t['id'], [card([T('## 🤖 First answer · Первый ответ\n' + body[:3500]),
                          T('-# 🇬🇧 An automatic answer from the FAQ — a person will look at your post too. · 🇷🇺 Автоматический ответ из частых вопросов — человек тоже посмотрит вашу тему.')])])


STAFF_ROLES = ('Owner', 'Admin')


def prune(store):
    """Results leave the website when their forum post was deleted, or Owner/Admin reacted 🗑️ to the bot's chart."""
    roles = {r['id'] for r in dc('GET', f'/guilds/{GUILD}/roles') if r['name'] in STAFF_ROLES}
    keep = []
    for x in store:
        tid = str(x.get('thread', ''))
        if not tid.isdigit(): keep.append(x); continue                 # entries added by hand (e.g. the lab post)
        st, _ = http(API + f'/channels/{tid}', headers={'Authorization': 'Bot ' + TOKEN})
        if st == 404: print('removed (post deleted)', tid); continue
        rid = x.get('reply')
        if rid:
            st, body = http(API + f'/channels/{tid}/messages/{rid}/reactions/' + urllib.parse.quote('🗑️'), headers={'Authorization': 'Bot ' + TOKEN})
            users = json.loads(body) if st == 200 and body else []
            staff = False
            for u in users:
                st2, mb = http(API + f'/guilds/{GUILD}/members/{u["id"]}', headers={'Authorization': 'Bot ' + TOKEN})
                if st2 == 200 and roles & set(json.loads(mb).get('roles', [])): staff = True; break
            if staff: print('removed (🗑️ by staff)', tid); continue
        keep.append(x)
    return keep


def main():
    if not TOKEN: sys.exit('DISCORD_TOKEN is not set')
    me = dc('GET', '/users/@me')['id']
    store = []
    if OUT_JSON and os.path.exists(OUT_JSON):
        try: store = json.load(open(OUT_JSON, encoding='utf-8'))
        except Exception: store = []
    known = {x['thread'] for x in store}
    done = 0
    for t in threads(RESULTS):
        if t.get('owner_id') == me or t['id'] in known or answered(t['id'], me): continue
        try: handle_result(t, me, store); done += 1
        except Exception as e: print('result', t['id'], e)
    for t in threads(HELP):
        if t.get('owner_id') == me or answered(t['id'], me): continue
        try: handle_help(t); done += 1
        except Exception as e: print('help', t['id'], e)
    try: store = prune(store)
    except Exception as e: print('prune', e)
    if OUT_JSON and not DRY:
        os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
        json.dump(store, open(OUT_JSON, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print('handled', done)


if __name__ == '__main__':
    main()
