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


NUM = lambda x: float(x.replace(',', '').replace(' ', ''))

# Every measurement DomainSchedTest writes: key, English / Russian name, higher is better, mode (game / idle / both)
METRICS = [
    ('fps', 'Average FPS', 'средний FPS', True, 'game'),
    ('low1', '1% low FPS', '1% low', True, 'game'),
    ('low01', '0.1% low FPS', '0.1% low', True, 'game'),
    ('ft_p99', 'Frame time p99, ms', 'время кадра p99, мс', False, 'game'),
    ('hitch', 'Hitches per run', 'рывков за прогон', False, 'game'),
    ('gw_p99', 'Game-thread wait p99, µs', 'ожидание потоков игры p99, мкс', False, 'game'),
    ('bg', 'Steam + Discord CPU, ms/s', 'Steam + Discord, мс процессора/с', False, 'game'),
    ('tb', 'Toolbox CPU, % of a core', 'нагрузка Toolbox, % ядра', False, 'both'),
    ('ft_max', 'Longest frame, ms', 'самый долгий кадр, мс', False, 'game'),
    ('gw_o50', 'Game waits > 50 µs', 'ожиданий игры > 50 мкс', False, 'game'),
    ('steal', 'Game delayed by Steam + Discord, ms', 'задержка игры из-за Steam + Discord, мс', False, 'game'),
    ('p50', 'Wait p50, µs', 'ожидание p50, мкс', False, 'idle'),
    ('p99', 'Wait p99, µs', 'ожидание p99, мкс', False, 'idle'),
    ('p999', 'Wait p99.9, µs', 'ожидание p99.9, мкс', False, 'idle'),
    ('o50', 'Waits > 50 µs, %', 'ожиданий > 50 мкс, %', False, 'idle'),
    ('o100', 'Waits > 100 µs', 'ожиданий > 100 мкс', False, 'idle'),
    ('dpc', 'Long waits with DPC/ISR, %', 'долгих ожиданий с DPC/ISR, %', False, 'idle'),
]
MAX_PANELS = 8
ORDER = {
    'game': ['fps', 'low1', 'low01', 'ft_p99', 'hitch', 'gw_p99', 'bg', 'tb', 'ft_max', 'gw_o50', 'steal'],
    'idle': ['p99', 'p999', 'o50', 'p50', 'o100', 'dpc', 'tb', 'gw_p99'],
}


def parse(s):
    """All numbers of one DomainSchedTest summary.txt (versions 1.4–1.6); missing ones stay absent."""
    r = {}
    m = re.search(r'Подпись: ([^\r\n]+)', s); r['label'] = m.group(1).strip() if m else 'run'
    m = re.search(r'Дата: ([\d\- :]+)', s); r['date'] = m.group(1).strip() if m else ''
    m = re.search(r'Процессор: ([^\r\n]+)', s); r['cpu'] = m.group(1).strip() if m else ''
    m = re.search(r'Windows: ([^\r\n]+)', s); r['windows'] = m.group(1).strip() if m else ''
    m = re.search(r'процесс: (\S+) \(', s); r['game'] = m.group(1) if m else ''
    m = re.search(r'\nDomain OS: [^\r\n]*?(\d+\.\d+\.\d+)', s); r['domainos'] = m.group(1) if m else ''
    fr = re.search(r'средний FPS ([\d.,]+)\s+1% low ([\d.,]+)\s+0\.1% low ([\d.,]+)', s)
    if fr: r['fps'], r['low1'], r['low01'] = (NUM(x) for x in fr.groups())
    m = re.search(r'время кадра: медиана ([\d.,]+) мс, p99 ([\d.,]+) мс, самый долгий ([\d.,]+) мс', s)
    if m: r['ft_p99'], r['ft_max'] = NUM(m.group(2)), NUM(m.group(3))
    m = re.search(r'рывков \([^)]*\): ([\d,]+)', s)
    if m: r['hitch'] = NUM(m.group(1))
    m = re.search(r'Ожидание готового потока[^\n]*\n\s+среднее ([\d.,]+)\s+p50 ([\d.,]+)\s+p90 ([\d.,]+)\s+p99 ([\d.,]+)\s+p99\.9 ([\d.,]+)', s)
    if m: r['p50'], r['p99'], r['p999'] = NUM(m.group(2)), NUM(m.group(4)), NUM(m.group(5))
    blk = s.split('Ожидание готового потока', 1)[-1].split('\n\n', 1)[0] if 'Ожидание готового потока' in s else ''
    m = re.search(r'дольше\s+50 мкс:\s+([\d,]+)\s+\(([\d.,]+)%\)', blk)
    if m: r['o50'] = NUM(m.group(2))
    m = re.search(r'дольше\s+100 мкс:\s+([\d,]+)', blk)
    if m: r['o100'] = NUM(m.group(1))
    gb = re.search(r'Только потоки [^\n]*\n\s+среднее [\d.,]+\s+p50 [\d.,]+\s+p90 [\d.,]+\s+p99 ([\d.,]+)[^\n]*\n\s+дольше\s+50 мкс:\s+([\d,]+)', s)
    if gb: r['gw_p99'], r['gw_o50'] = NUM(gb.group(1)), NUM(gb.group(2))
    m = re.search(r'Все процессы: ожиданий дольше 50 мкс.*?на ядре во время ожидания был DPC/ISR:\s+[\d,]+\s+\(\s*([\d.,]+)%\)', s, re.S)
    if m: r['dpc'] = NUM(m.group(1))
    m = re.search(r'Нагрузка Domain OS Toolbox за замер: ([\d.,]+)%', s)
    if m: r['tb'] = NUM(m.group(1))
    bg = re.findall(r'^\s+(steam|steamwebhelper|gameoverlayui|steamservice|discord)\s+\d+\s+([\d.,]+)\s+[\d.,]+\s+[\d.,]+\s+\S+\s+\S+\s+([\d.,]+|—)', s, re.M)
    if bg:
        r['bg'] = sum(NUM(c) for _, c, _ in bg)
        r['steal'] = sum(NUM(x) for _, _, x in bg if x != '—')
    r['mode'] = 'game' if fr else 'idle'
    if not fr and 'p99' not in r: return None
    return r


def group_of(label):
    # base-1, base 2, base_3, base#4 → base; a label without a separator (S1, D3) is a group of its own
    g = re.sub(r'[\s_\-#]+\(?\d+\)?$', '', label).strip()
    return g or label


def fmt(v):
    return f'{v:.0f}' if abs(v) >= 100 else f'{v:.1f}' if abs(v) >= 10 else f'{v:.2f}'


def chart(title, groups, n, metrics):
    """One panel per measurement (up to 8, 4 per row). 2+ groups: bar = average, dot = one run, pink = best.
    One group: a tile with the average, the min–max range and every run (nothing to compare against)."""
    fd = lambda f, z: ImageFont.truetype(os.path.join(FONTS, f), z)
    BG, PANEL, FG, DIM, PINKc, SIL, LINE = (11, 12, 16), (16, 17, 22), (236, 237, 240), (150, 154, 164), (244, 182, 203), (170, 174, 186), (46, 48, 56)
    names = list(groups); single = len(names) == 1
    cols = min(4, len(metrics)); rows = (len(metrics) + cols - 1) // cols
    W = 2400; PH = 380 if single else 620; H = 200 + rows * (PH + 30) + 40
    im = Image.new('RGB', (W, H), BG); d = ImageDraw.Draw(im)
    d.text((80, 56), title[:90], font=fd('Inter-SemiBold.ttf', 50), fill=FG)
    sub = (f'one group «{names[0]}» · {n} run(s) · одна группа, {n} прогон(а) · average, range and every run' if single else
           f'{n} run(s) per group · {n} прогон(а) на группу · dot = one run, bar = average · pink = best')
    d.text((80, 122), sub[:150], font=fd('Inter-Regular.ttf', 28), fill=DIM)
    d.text((W - 80, 60), 'Domain OS · RESULTS', font=fd('JetBrainsMono-Medium.ttf', 26), fill=PINKc, anchor='ra')
    pw = (W - 160) // cols

    def fit(text, width, size, font='JetBrainsMono-Medium.ttf', minsize=13):
        while size > minsize and d.textlength(text, font=fd(font, size)) > width: size -= 1
        f = fd(font, size)
        while d.textlength(text, font=f) > width and len(text) > 2: text = text[:-2] + '…'
        return text, f

    for i, (key, en, ru, hi, _) in enumerate(metrics):
        px = 80 + (i % cols) * pw; py = 200 + (i // cols) * (PH + 30)
        d.rounded_rectangle((px + 10, py, px + pw - 10, py + PH), radius=22, fill=PANEL)
        d.text((px + pw / 2, py + 22), en, font=fd('Inter-SemiBold.ttf', 30), fill=FG, anchor='ma')
        d.text((px + pw / 2, py + 62), ru + ('  ·  ↑ better' if hi else '  ·  ↓ better'), font=fd('Inter-Regular.ttf', 21), fill=DIM, anchor='ma')
        vals = [[r[key] for r in groups[g]] for g in names]
        if single:
            vs = vals[0]; m_ = mean(vs); lo, hi_ = min(vs), max(vs)
            d.text((px + pw / 2, py + 175), fmt(m_), font=fd('Inter-SemiBold.ttf', 76), fill=PINKc, anchor='mm')
            d.text((px + pw / 2, py + 238), f'range {fmt(lo)} – {fmt(hi_)} · разброс', font=fd('Inter-Regular.ttf', 22), fill=DIM, anchor='mm')
            # a strip: min–max with every run as a dot
            x0, x1, yy = px + 60, px + pw - 60, py + 300
            d.line((x0, yy, x1, yy), fill=LINE, width=4)
            span = (hi_ - lo) or 1
            for v in vs:
                xx = x0 + (v - lo) / span * (x1 - x0) if hi_ > lo else (x0 + x1) / 2
                d.ellipse((xx - 7, yy - 7, xx + 7, yy + 7), fill=(255, 255, 255), outline=BG, width=2)
            d.text((x0, yy + 22), fmt(lo), font=fd('JetBrainsMono-Medium.ttf', 18), fill=DIM, anchor='la')
            d.text((x1, yy + 22), fmt(hi_), font=fd('JetBrainsMono-Medium.ttf', 18), fill=DIM, anchor='ra')
            continue
        top, base = py + 150, py + PH - 80
        mx = max(max(v) for v in vals) * 1.18 or 1
        means = [mean(v) for v in vals]
        best = (max if hi else min)(range(len(names)), key=lambda j: means[j])
        step = (pw - 60) / len(names); bw = step * 0.62
        Y = lambda v: base - (v / mx) * (base - top)
        for j, (g, vs) in enumerate(zip(names, vals)):
            x = px + 30 + j * step + (step - bw) / 2; m_ = means[j]
            col = PINKc if j == best else (SIL if j == 0 else (150, 110, 124))
            d.rectangle((x, Y(m_), x + bw, base), fill=col)
            for k, v in enumerate(vs):
                xx = x + bw / 2 + (k - (len(vs) - 1) / 2) * 10
                d.ellipse((xx - 4, Y(v) - 4, xx + 4, Y(v) + 4), fill=(255, 255, 255), outline=BG, width=2)
            d.text((x + bw / 2, min(Y(m_), min(Y(v) for v in vs)) - 10), fmt(m_), font=fd('Inter-SemiBold.ttf', 22 if len(names) > 5 else 26), fill=FG, anchor='mb')
            lab, f = fit(g, step - 4, 21)
            d.text((x + bw / 2, base + 14), lab, font=f, fill=FG, anchor='ma')
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
    game = [r for r in runs if r['mode'] == 'game']
    runs = game or runs                                  # game runs win when a post mixes game and idle runs
    mode = 'game' if game else 'idle'
    runs.sort(key=lambda r: r['date'])
    groups = {}
    for r in runs: groups.setdefault(group_of(r['label']), []).append(r)
    groups = dict(list(groups.items())[:10])
    n = min(len(v) for v in groups.values())
    eq = {g: v[:n] for g, v in groups.items()}
    allr = [r for v in eq.values() for r in v]
    by = {m[0]: m for m in METRICS}
    mets = [by[k] for k in ORDER[mode] if all(k in r for r in allr) and any(r[k] for r in allr)][:MAX_PANELS]
    base = next(iter(eq))
    av = lambda g, k: mean(r[k] for r in eq[g])
    main3 = [m for m in mets[:3]]
    lines = []
    for g in eq:
        cells = ' · '.join(fmt(av(g, k)) for k, *_ in main3)
        if g == base: lines.append(f'`{g:<12}` {cells}')
        else:
            dif = ', '.join(f'{(av(g, k) / av(base, k) - 1) * 100:+.1f}% {k}' for k, *_ in main3[:2] if av(base, k))
            lines.append(f'`{g:<12}` {cells}   ({dif})')
    extra = '' if all(len(v) == n for v in groups.values()) else \
        f'\n-# 🇬🇧 Groups had different numbers of runs: the first {n} of each (by time) are compared. · 🇷🇺 В группах разное число прогонов: сравниваются первые {n} в каждой (по времени).'
    hw = runs[0]
    info = ' · '.join(x for x in (hw['cpu'], hw['windows'], hw['game'], ('Domain OS ' + hw['domainos']) if hw['domainos'] else '', 'idle · простой' if mode == 'idle' else '') if x)
    title = (t.get('name') or 'Results')[:80]
    png = chart(title + (' · idle' if mode == 'idle' else ''), eq, n, mets)
    single = len(eq) == 1
    head = ('🇬🇧 group · ' + ' · '.join(m[1] for m in main3) + ('' if single else ' (vs the first group)') + ' · 🇷🇺 группа · ' + ' · '.join(m[2] for m in main3) + ('' if single else ' (к первой группе)') + '\n'
            + '-# 🇬🇧 The chart shows all ' + str(len(mets)) + ' measurements. · 🇷🇺 На графике все ' + str(len(mets)) + ' показателей.\n')
    text = (f'## 📊 {title}\n-# {info}\n' + head + '\n'.join(lines) + extra +
            ('\n-# 🇬🇧 One group only: to compare, label the runs of the other variant differently (base-1 … test-1 …). · 🇷🇺 Группа одна: чтобы сравнить, подпишите прогоны другого варианта иначе (base-1 … test-1 …).' if single else
             '\n-# 🇬🇧 Differences under ~2% are usually noise. · 🇷🇺 Разница меньше ~2% — обычно разброс.'))
    m = reply(t['id'], [card([T(text[:3900]), {'type': 12, 'items': [{'media': {'url': 'attachment://chart.png'}}]},
                              T('-# 🗑️ Owner/Admin: react 🗑️ to this message to remove the result from the website. · Owner/Admin: реакция 🗑️ на это сообщение убирает замер с сайта.')])],
              [('chart.png', png)])
    store.append({'thread': t['id'], 'reply': (m or {}).get('id', ''), 'title': title, 'url': f'https://discord.com/channels/{GUILD}/{t["id"]}', 'date': runs[0]['date'][:10],
                  'cpu': hw['cpu'], 'windows': hw['windows'], 'game': hw['game'], 'domainos': hw['domainos'], 'runs': n, 'mode': mode,
                  'metrics': [{'key': k, 'en': en, 'ru': ru, 'hi': hi} for k, en, ru, hi, _ in mets],
                  'groups': [{'name': g, **{k: round(av(g, k), 3) for k, *_ in mets}} for g in eq]})


# ===================================================================================================================
# help
# ===================================================================================================================


FAQ = [
    (['что такое', 'что это', 'зачем', 'для чего', 'что делает', 'что даст', 'what is', 'what does', 'смысл', 'о сборке', 'что за сборк', 'что за плейбук'], '**What Domain OS is** · **Что такое Domain OS**',
     '🇬🇧 A playbook (installer) that cleans up a fresh Windows 11 Pro for games in ~10 min: removes ads, bloat and telemetry, sets up power and Game Mode. Windows protection stays, everything can be undone. Plus **Toolbox** — an app that helps the game while you play. https://6kane1.github.io/DomainOS/\n'
     '🇷🇺 Плейбук (установщик), который за ~10 минут приводит свежую Windows 11 Pro в порядок для игр: убирает рекламу, лишние программы и телеметрию, настраивает питание и игровой режим. Защита Windows остаётся, всё откатывается. Плюс **Toolbox** — программа, которая помогает игре, пока вы играете. https://6kane1.github.io/DomainOS/ru/'),
    (['скача', 'качат', 'качну', 'загруз', 'где взять', 'где найти', 'ссылк', 'линк', 'link', 'download', 'apbx', 'откуда'], '**Where to download** · **Где скачать**',
     '🇬🇧 Everything is in <#1572231027588333700> and on the website: No-WU-Drivers.reg, AME Wizard, Domain-OS.apbx. Toolbox comes with the build.\n'
     '🇷🇺 Всё в <#1572231027588333700> и на сайте: No-WU-Drivers.reg, AME Wizard, Domain-OS.apbx. Toolbox ставится вместе со сборкой.'),
    (['установ', 'устанав', 'постав', 'накат', 'install', 'ame', 'визард', 'wizard', 'инструкц', 'гайд', 'guide', 'как начать', 'с чего начать'], '**How to install** · **Как установить**',
     '🇬🇧 Step-by-step guide from a clean Windows: https://6kane1.github.io/DomainOS/install.html — short version in <#1572228626425057305>. AME Wizard needs the internet and, on a laptop, the charger plugged in.\n'
     '🇷🇺 Пошаговая инструкция с чистой Windows: https://6kane1.github.io/DomainOS/ru/install.html — коротко в <#1572228626425057305>. AME Wizard нужен интернет, а на ноутбуке — зарядка.'),
    (['25h2', '26h2', '24h2', 'винд', 'windows', 'win10', 'win 10', 'десятк', 'winver', 'какая версия', 'какая систем', 'редакц'], '**Which Windows** · **Какая Windows нужна**',
     '🇬🇧 Windows 11 **Pro**, version **25H2 or 26H2** (Win+R → `winver`). Windows 10 and 24H2 are not supported.\n'
     '🇷🇺 Windows 11 **Pro**, версия **25H2 или 26H2** (Win+R → `winver`). Windows 10 и 24H2 не поддерживаются.'),
    (['бан', 'забан', 'банят', 'ban', 'безопас', 'safe', 'вирус', 'virus', 'троян', 'defender', 'защитник', 'антивирус', 'опасн', 'vac'], '**Is it safe? Can I get banned?** · **Это безопасно? Не забанят?**',
     '🇬🇧 Domain OS does not touch Defender, Memory Integrity, Secure Boot or TPM and does not inject into games. Anti-cheat developers have not officially confirmed compatibility, so use it at your own risk — but nothing here works like a cheat.\n'
     '🇷🇺 Domain OS не трогает Defender, защиту памяти, Secure Boot и TPM и ничего не внедряет в игры. Разработчики античитов совместимость официально не подтверждали, поэтому — на свой риск, но ничего похожего на читы здесь нет.'),
    (['toolbox', 'тулбокс', 'тулбох', 'auto', 'авто', 'оптимизация устройств', 'optimize', 'как пользов', 'настро'], '**How to use Toolbox** · **Как пользоваться Toolbox**',
     '🇬🇧 Open Toolbox → **Turn on Auto** → start the game. Once, with the game closed: **Optimize devices** → restart. Details in <#1572338781812559903>.\n'
     '🇷🇺 Откройте Toolbox → **Включить Auto** → запустите игру. Один раз при закрытой игре: **Оптимизация устройств** → перезагрузка. Подробно в <#1572338781812559903>.'),
    (['не видит', 'не находит', 'не подхват', 'не реагир', 'не работает с игр', 'игру не', 'not found', 'не ловит', 'не цепляет'], '**Toolbox does not pick up the game** · **Toolbox не видит игру**',
     '🇬🇧 Auto must be on and the game in front (not minimised). Some games are protected by their anti-cheat — then Toolbox leaves the game alone but still quiets background programs.\n'
     '🇷🇺 Auto должен быть включён, игра — на переднем плане (не свёрнута). Некоторые игры защищены своим античитом — тогда Toolbox не трогает саму игру, но фоновые программы всё равно приглушает.'),
    (['ноут', 'laptop', 'notebook', 'батаре', 'аккумул', 'battery'], '**Laptops** · **Ноутбуки**',
     '🇬🇧 Laptop support is not confirmed yet — at your own risk. Keep the charger plugged in during the install.\n'
     '🇷🇺 Поддержка ноутбуков пока не подтверждена — на свой риск. Во время установки держите ноутбук на зарядке.'),
    (['обнов', 'апдейт', 'update', 'новая версия', 'new version', 'поверх', 'переустан'], '**Updates** · **Обновления**',
     '🇬🇧 Security updates keep coming; big feature updates are held on 26H2 (option). A new Domain OS version installs right over the old one in AME Wizard.\n'
     '🇷🇺 Обновления безопасности приходят как обычно; крупные обновления удерживаются на 26H2 (опция). Новая версия Domain OS ставится прямо поверх старой в AME Wizard.'),
    (['обои', 'обоев', 'wallpaper', 'фон', 'экран блокир', 'lock screen', 'слайд', 'картинк', 'заставк'], '**Wallpapers** · **Обои**',
     '🇬🇧 Change them as usual: Settings → Personalization. Lock screen slideshow: Personalization → Lock screen → Slideshow → `C:\\Windows\\Web\\Wallpaper\\Domain OS`.\n'
     '🇷🇺 Меняются как обычно: «Параметры → Персонализация». Слайд-шоу на экране блокировки: Персонализация → Экран блокировки → Слайд-шоу → `C:\\Windows\\Web\\Wallpaper\\Domain OS`.'),
    (['schedtest', 'замер', 'бенчмарк', 'benchmark', 'results', 'график', 'сравни'], '**Benchmarks** · **Замеры**',
     '🇬🇧 The benchmark tool and a beginner guide are in <#1572685486311342081>; post results in <#1572682487543365843> — the bot answers with a chart.\n'
     '🇷🇺 Программа замеров и инструкция для новичков — в <#1572685486311342081>; результаты выкладывайте в <#1572682487543365843> — бот ответит графиком.'),
    (['as-3', 'as3', 'epic', 'эпик', 'офлайн', 'оффлайн', 'offline', 'капч', 'captcha'], '**Epic Games Launcher offline / AS-3 / failed captcha** · **Epic офлайн / AS-3 / капча**',
     '🇬🇧 This is the internet provider blocking Epic servers, not Windows or Domain OS (check: does it work through a phone hotspot or a VPN?). Sign in once through a VPN with "Remember me".\n'
     '🇷🇺 Это провайдер блокирует серверы Epic, а не Windows или Domain OS (проверка: работает ли через раздачу с телефона или VPN?). Войдите один раз через VPN с «Запомнить меня».'),
    (['home', 'хоум', 'домашн', 'только pro', 'pro only', 'останов', 'halt', 'не ставится', 'не устанавлив', 'первом шаге'], '**The install stops at the first step** · **Установка остановилась на первом шаге**',
     '🇬🇧 Domain OS installs on **Windows 11 Pro** only. Check Settings → System → About. On Home: switch to Pro with a Pro key (Settings → System → Activation).\n'
     '🇷🇺 Domain OS ставится только на **Windows 11 Pro**. Проверьте «Параметры → Система → О системе». На Home — перейдите на Pro своим ключом («Параметры → Система → Активация»).'),
    (['откат', 'вернуть', 'верни', 'undo', 'restore', 'удалить сборк', 'снести', 'снест', 'убрать сборк', 'как было'], '**How to undo** · **Как откатить**',
     '🇬🇧 Start → Domain OS → **Undo Domain OS**, then restart. Toolbox changes: "Undo everything" in Toolbox.\n'
     '🇷🇺 «Пуск» → Domain OS → **Undo Domain OS** и перезагрузка. Изменения Toolbox: «Вернуть всё как было» в Toolbox.'),
    (['драйв', 'дрова', 'дров', 'driver', 'видюх', 'видеокарт', 'nvidia', 'нвидиа', 'радеон', 'чипсет'], '**Drivers** · **Драйверы**',
     '🇬🇧 Graphics and chipset drivers only from the official NVIDIA / AMD / Intel sites, no driver packs. The driver page opens after the first restart.\n'
     '🇷🇺 Драйверы видеокарты и чипсета — только с официальных сайтов NVIDIA / AMD / Intel, без сборников. Страница драйверов открывается после первой перезагрузки.'),
    (['fps', 'фпс', 'лаг', 'тормоз', 'фриз', 'рывк', 'дерга', 'статтер', 'stutter', 'просед', 'просадк', 'микрофриз', 'плавн', 'кадр'], '**FPS / stutter** · **FPS / рывки**',
     '🇬🇧 Toolbox: Auto on, then once "Optimize devices" with the game closed and restart. Steam: Settings → Interface → GPU acceleration in web views off. If the GPU is at 95–100%, average FPS will barely move — that is the card, not Windows.\n'
     '🇷🇺 Toolbox: Auto вкл., затем один раз «Оптимизация устройств» при закрытой игре и перезагрузка. Steam: Настройки → Интерфейс → GPU-ускорение веб-окон выкл. Если видеокарта загружена на 95–100%, средний FPS почти не изменится — это предел карты, а не Windows.'),
    (['faceit', 'фейсит', 'фейсет', 'vanguard', 'вангард', 'valorant', 'валорант', 'античит', 'anti-cheat', 'anticheat', 'eac', 'battleye'], '**Anti-cheat** · **Античит**',
     '🇬🇧 Domain OS keeps Defender, VBS/Memory Integrity, Secure Boot and TPM as Windows has them. If an anti-cheat refuses: check that TPM and Secure Boot are on in the BIOS and close third-party tools that load drivers.\n'
     '🇷🇺 Domain OS оставляет Defender, VBS/защиту памяти, Secure Boot и TPM как в Windows. Если античит не пускает: проверьте, что TPM и Secure Boot включены в BIOS, и закройте сторонние программы с драйверами.'),
    (['вылет', 'краш', 'crash', 'синий экран', 'бсод', 'bsod', 'не загруж', 'не грузит', 'черный экран', 'black screen', 'перезагруж', 'ребут', 'завис', 'freeze'], '**Crashes, blue screen, does not start** · **Вылеты, синий экран, не загружается**',
     '🇬🇧 If Windows did not start after "Optimize devices" in Toolbox, the changes are undone by themselves at the next start. Otherwise: Start → Domain OS → **Undo Domain OS** (in Safe Mode: `DomainScheduler.exe --revert-devices`). Please attach `%ProgramData%\\Domain OS\\Logs\\install.log` and the blue-screen code if there was one.\n'
     '🇷🇺 Если Windows не загрузилась после «Оптимизации устройств» в Toolbox, изменения откатятся сами при следующем запуске. Иначе: «Пуск» → Domain OS → **Undo Domain OS** (в безопасном режиме: `DomainScheduler.exe --revert-devices`). Приложите `%ProgramData%\\Domain OS\\Logs\\install.log` и код синего экрана, если он был.'),
]


def _norm(text):
    t = text.lower().replace('ё', 'е')
    t = re.sub(r'[^\w\s\-]', ' ', t)
    return ' ' + re.sub(r'\s+', ' ', t).strip() + ' '


def _close(a, b):
    """b is a with at most one letter wrong, missing or extra (typos)."""
    if abs(len(a) - len(b)) > 1: return False
    i = 0
    while i < min(len(a), len(b)) and a[i] == b[i]: i += 1
    return a[i + 1:] == b[i + 1:] or a[i + 1:] == b[i:] or a[i:] == b[i + 1:]


def faq_score(keys, norm, words):
    """Points for a topic: a phrase found = 2, a word that starts with a stem (or with one typo in a long stem) = 1."""
    score = 0; used = set()
    for k in keys:
        k = k.replace('ё', 'е')
        if ' ' in k or '-' in k:
            if k in norm: score += 2
            continue
        for n, w in enumerate(words):
            if n in used: continue
            if w.startswith(k) or (len(k) >= 5 and w[:2] == k[:2] and (_close(w[:len(k)], k) or _close(w[:len(k) + 1], k) or _close(w, k))):
                score += 1; used.add(n); break
    return score


def faq_reply(text):
    """The first answer for a help post: up to 4 FAQ topics matched by keywords, else what to add to the post."""
    norm = _norm(text); words = norm.split()
    # equal points: problem topics (FPS, crashes, undo, Epic, anti-cheat, drivers …) before the general ones
    ranked = sorted(((faq_score(k, norm, words), n, h, a) for n, (k, h, a) in enumerate(FAQ)), key=lambda x: (-x[0], x[1] < BASIC, x[1]))
    hits = [(None, h, a) for sc, _, h, a in ranked if sc > 0]
    body = '\n\n'.join(f'### {h}\n{a}' for _, h, a in hits[:4])
    if not body:
        body = ('🇬🇧 Thanks! While you wait for a reply, please add: playbook and Toolbox versions, `winver`, CPU and GPU, what you did and what happened, and attach `%ProgramData%\\Domain OS\\Logs\\install.log` and `%LOCALAPPDATA%\\DomainScheduler\\log.txt`.\n'
                '🇷🇺 Спасибо! Пока ждёте ответа, добавьте: версии сборки и Toolbox, `winver`, процессор и видеокарту, что делали и что произошло, и приложите `%ProgramData%\\Domain OS\\Logs\\install.log` и `%LOCALAPPDATA%\\DomainScheduler\\log.txt`.')
    return [card([T('## 🤖 First answer · Первый ответ\n' + body[:3500]),
                  T('-# 🇬🇧 An automatic answer from the FAQ — a person will look at your post too. · 🇷🇺 Автоматический ответ из частых вопросов — человек тоже посмотрит вашу тему.')])]


OWNER = '528659324193734659'
OWNER_ROLE = '1572228603498864734'   # @Owner


def say(tid, text, ref=None, ping_owner=False):
    """A plain message (so a mention really notifies), optionally a reply to a message."""
    body = {'content': text[:1990], 'allowed_mentions': {'roles': [OWNER_ROLE] if ping_owner else [], 'parse': []}}
    if ref: body['message_reference'] = {'message_id': ref, 'fail_if_not_exists': False}
    if DRY: print('DRY say', tid, text[:200]); return None
    return dc('POST', f'/channels/{tid}/messages', body)


def handle_help(t):
    """A new help post: a FAQ answer when it is a basic question, otherwise the author is called."""
    starter = dc('GET', f'/channels/{t["id"]}/messages/{t["id"]}')
    if (starter.get('content') or '').lstrip().startswith('!'):
        return False                                   # the post starts with a command: only the command is answered
    text = (t.get('name') or '') + ' ' + (starter.get('content') or '')
    if faq_hits(text):
        reply(t['id'], faq_reply(text) + [card([T(COMMANDS_HINT)])])
    else:
        say(t['id'], f'<@&{OWNER_ROLE}> 🙋 a new question needs a person · новый вопрос — нужен человек.\n'
                     '🇬🇧 Thanks! The author will answer here. Meanwhile add: versions, `winver`, CPU/GPU and the two logs (`!logs`). · '
                     '🇷🇺 Спасибо! Автор ответит здесь. Пока добавьте: версии, `winver`, процессор/видеокарту и два журнала (`!logs`).', ping_owner=True)


# ---------------------------------------------------------------------------------------------------------------
# ! commands in help discussions
CMD = {   # command → FAQ title (start), or a special action
    'about': 'What Domain OS is', 'download': 'Where to download', 'install': 'How to install', 'windows': 'Which Windows',
    'safe': 'Is it safe', 'toolbox': 'How to use Toolbox', 'nogame': 'Toolbox does not pick up', 'laptop': 'Laptops',
    'update': 'Updates', 'wallpaper': 'Wallpapers', 'bench': 'Benchmarks', 'pro': 'The install stops',
    'undo': 'How to undo', 'drivers': 'Drivers', 'fps': 'FPS / stutter', 'anticheat': 'Anti-cheat', 'crash': 'Crashes',
}
ALIAS = {
    'что': 'about', 'о': 'about', 'скачать': 'download', 'установка': 'install', 'установить': 'install', 'винда': 'windows', 'windows': 'windows',
    'безопасно': 'safe', 'бан': 'safe', 'тулбокс': 'toolbox', 'игра': 'nogame', 'ноутбук': 'laptop', 'ноут': 'laptop', 'обновления': 'update',
    'обои': 'wallpaper', 'замеры': 'bench', 'тест': 'bench', 'pro': 'pro', 'home': 'pro', 'откат': 'undo', 'вернуть': 'undo',
    'драйверы': 'drivers', 'драйвера': 'drivers', 'дрова': 'drivers', 'фпс': 'fps', 'лаги': 'fps', 'античит': 'anticheat', 'вылет': 'crash',
    'вылеты': 'crash', 'бсод': 'crash', 'журнал': 'logs', 'логи': 'logs', 'помощь': 'help', 'команды': 'help', 'вопрос': 'ask',
    'человек': 'human', 'автор': 'human', 'admin': 'human', 'owner': 'human',
}
COMMANDS_HINT = ('🙋 **Didn\'t help? Type `!human` — the author will answer. · Не помогло? Напишите `!человек` — ответит автор.**\n'
                 '-# 🇬🇧 All commands: `!help` · ask the bot: `!ask your question`. · 🇷🇺 Все команды: `!help` · спросить бота: `!ask ваш вопрос`.')
HUMAN_BLOCK = ('> ## 🙋 `!human` · `!человек`\n'
               '> 🇬🇧 **Remember this one: it calls the author.** The bot did not help, the answer does not fit, something is broken — type `!human` and the author answers right here.\n'
               '> 🇷🇺 **Запомните эту команду: она зовёт автора.** Бот не помог, ответ не подходит, что-то сломалось — напишите `!человек`, и автор ответит прямо здесь.\n')
HELP_TEXT = (HUMAN_BLOCK + '\n## ⌨️ All commands · Все команды\n'
             '🇬🇧 Type a command in this discussion — the bot answers in a few seconds. Russian names work too.\n'
             '🇷🇺 Напишите команду в этом обсуждении — бот ответит за несколько секунд. Русские названия тоже работают.\n'
             '```\n'
             '!install   !установка   how to install · как установить\n'
             '!download  !скачать     where to download · где скачать\n'
             '!windows   !винда       which Windows · какая Windows\n'
             '!pro       !home        stops at step 1 · остановилась на 1 шаге\n'
             '!undo      !откат       undo everything · откатить всё\n'
             '!drivers   !дрова       drivers · драйверы\n'
             '!fps       !лаги        FPS, stutter · FPS, рывки\n'
             '!crash     !вылеты      crashes, blue screen · вылеты, синий экран\n'
             '!toolbox   !тулбокс     how to use Toolbox · Toolbox\n'
             '!nogame    !игра        Toolbox does not see the game · не видит игру\n'
             '!anticheat !античит     FACEIT, Vanguard, EAC · античиты\n'
             '!safe      !бан         safe? bans? · безопасно? бан?\n'
             '!laptop    !ноут        laptops · ноутбуки\n'
             '!update    !обновления  updates · обновления\n'
             '!wallpaper !обои        wallpapers · обои\n'
             '!bench     !замеры      benchmarks · замеры\n'
             '!logs      !логи        which files to attach · какие файлы приложить\n'
             '!about     !что         what Domain OS is · что такое Domain OS\n'
             '!ask …     !вопрос …    the bot looks for an answer · бот ищет ответ\n'
             '```')
LOGS = ('### 📄 Logs to attach · Какие файлы приложить\n'
        '🇬🇧 `%ProgramData%\\Domain OS\\Logs\\install.log` (the install) and `%LOCALAPPDATA%\\DomainScheduler\\log.txt` (Toolbox). Paste the path into Win+R, the folder opens.\n'
        '🇷🇺 `%ProgramData%\\Domain OS\\Logs\\install.log` (установка) и `%LOCALAPPDATA%\\DomainScheduler\\log.txt` (Toolbox). Вставьте путь в Win+R — откроется папка.')


def faq_hits(text):
    norm = _norm(text); words = norm.split()
    return [n for n, (k, h, a) in enumerate(FAQ) if faq_score(k, norm, words) > 0]


def faq_by_title(start):
    return next(((h, a) for k, h, a in FAQ if h.strip('*').startswith(start)), None)


def answer_command(tid, m):
    raw = (m.get('content') or '').strip()
    word, _, rest = raw[1:].partition(' ')
    cmd = word.lower().strip('.,!?')
    cmd = ALIAS.get(cmd, cmd)
    ref = m['id']
    if cmd in ('help', 'commands', 'h'):
        reply_ref(tid, [card([T(HELP_TEXT)])], ref); return
    if cmd == 'logs':
        reply_ref(tid, [card([T(LOGS)])], ref); return
    if cmd in ('human', 'person'):
        say(tid, f'<@&{OWNER_ROLE}> 🙋 {m["author"].get("global_name") or m["author"]["username"]} asks for the author · просит автора.', ref, ping_owner=True); return
    if cmd == 'ask':
        if faq_hits(rest):
            reply_ref(tid, faq_reply(rest) + [card([T(COMMANDS_HINT)])], ref)
        else:
            say(tid, f'<@&{OWNER_ROLE}> 🙋 no basic answer for this question · на этот вопрос нет готового ответа: «{rest[:300]}»\n'
                     '-# 🇬🇧 The author will answer here. · 🇷🇺 Автор ответит здесь.', ref, ping_owner=True)
        return
    if cmd in CMD:
        hit = faq_by_title(CMD[cmd])
        if hit:
            reply_ref(tid, [card([T(f'### {hit[0]}\n{hit[1]}'), T(COMMANDS_HINT)])], ref); return
    reply_ref(tid, [card([T(f'🇬🇧 Unknown command `!{word[:30]}`. · 🇷🇺 Нет такой команды `!{word[:30]}`.\n' + HELP_TEXT)])], ref)


def reply_ref(tid, comps, ref):
    payload = {'flags': 1 << 15, 'components': comps, 'message_reference': {'message_id': ref, 'fail_if_not_exists': False},
               'allowed_mentions': {'parse': []}}
    if DRY: print('DRY reply_ref', tid, json.dumps(comps, ensure_ascii=False)[:300]); return None
    return dc('POST', f'/channels/{tid}/messages', payload)


_seen = {}


def commands_in(t, me):
    """Answers every '!' message in a help discussion that the bot has not answered yet (replies point to it)."""
    if _seen.get(t['id']) == t.get('last_message_id'): return 0
    msgs = dc('GET', f'/channels/{t["id"]}/messages?limit=50')
    done_refs = {(x.get('message_reference') or {}).get('message_id') for x in msgs if x['author']['id'] == me}
    n = 0
    now = datetime.now(timezone.utc)
    for m in sorted(msgs, key=lambda x: int(x['id'])):
        if m['author'].get('bot') or not (m.get('content') or '').startswith('!') or m['id'] in done_refs: continue
        when = datetime.fromisoformat(m['timestamp'].replace('Z', '+00:00'))
        if (now - when).total_seconds() > 3 * 3600: continue           # old commands from before the bot ran: skipped
        try: answer_command(t['id'], m); n += 1
        except Exception as e: print('cmd', t['id'], e)
    _seen[t['id']] = t.get('last_message_id')
    return n


BASIC = 11   # the first 11 FAQ topics are the general ones
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


def pass_results(me, store, known):
    done = 0
    for t in threads(RESULTS):
        if t.get('owner_id') == me or t['id'] in known or answered(t['id'], me): continue
        try: handle_result(t, me, store); known.add(t['id']); done += 1
        except Exception as e: print('result', t['id'], e)
    return done


def pass_help(me):
    done = 0
    for t in threads(HELP):
        if t.get('owner_id') == me: continue
        try:
            # commands first: a reply to the starter command then counts as "answered", so no second "first answer"
            done += commands_in(t, me)
            if not answered(t['id'], me) and handle_help(t) is not False: done += 1
        except Exception as e: print('help', t['id'], e)
    return done


def save(store):
    if OUT_JSON and not DRY:
        os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
        json.dump(store, open(OUT_JSON, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)


def publish(store):
    """Writes results.json and pushes it to the site at once (the workflow checked out gh-pages next to it)."""
    if not OUT_JSON or DRY: return
    save(store)
    import subprocess
    repo = os.path.dirname(os.path.dirname(os.path.abspath(OUT_JSON)))
    g = lambda *a: subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True)
    if not g('status', '--porcelain', 'results').stdout.strip(): return
    g('-c', 'user.name=Domain OS bot', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com', 'commit', '-qam', 'results: community benchmarks')
    for _ in range(3):
        if g('push', '-q').returncode == 0: print('published'); return
        g('pull', '-q', '--rebase')
    print('publish failed')


def main():
    if not TOKEN: sys.exit('DISCORD_TOKEN is not set')
    me = dc('GET', '/users/@me')['id']
    store = []
    if OUT_JSON and os.path.exists(OUT_JSON):
        try: store = json.load(open(OUT_JSON, encoding='utf-8'))
        except Exception: store = []
    known = {x['thread'] for x in store}
    watch = int(sys.argv[sys.argv.index('--watch') + 1]) if '--watch' in sys.argv else 0
    end = time.time() + watch
    done = 0; last_results = 0
    while True:
        try: done += pass_help(me)
        except Exception as e: print('help pass', e)
        if time.time() - last_results >= 300:
            before = json.dumps(store, sort_keys=True)
            try: done += pass_results(me, store, known)
            except Exception as e: print('results pass', e)
            try: store[:] = prune(store)
            except Exception as e: print('prune', e)
            if json.dumps(store, sort_keys=True) != before: publish(store)   # the site gets it right away
            last_results = time.time()
        if time.time() + 12 >= end: break
        time.sleep(12)
    publish(store)
    print('handled', done)


if __name__ == '__main__':
    main()
