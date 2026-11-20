"""Domain OS Discord helper, run by .github/workflows/discord-bot.yml as a short check (~2 minutes) every 10 minutes
(no server of our own and no bot running around the clock; a "shift" below is one such run).

results forum: a new post with DomainSchedTest results (zip / 7z / summary.txt) gets a reply with a chart: the runs
are grouped by their label (base-1, base-2, S2-1 … → base, S2), every group uses the same number of runs (the first N
by time, N = the smallest group), bar = average, dot = one run. The numbers go to the site's results page (results.json),
pushed right after every change.
help forum: a new post gets a first answer from the FAQ matched by keywords (EN + RU), then a person takes over.
A post is handled once: the bot looks for its own reply in the thread.

Attachments come from anyone, so they are unpacked and read in a separate process (--parse-worker) with hard limits:
at most 200 summary.txt files, 2 MB each, 20 MB together (checked from the archive's own list before anything is
unpacked), 1 GB of memory and 60 s; on GitHub that process runs as the user "nobody" with no tokens in its environment.
A results post that could not be read is tried at most twice (results/bot-state.json next to results.json), then the
author gets one "could not read" answer.
Needs the secret DISCORD_TOKEN and the bot's "Message Content" intent (to read attachments); GH_PUSH_TOKEN (the
workflow's token) is used only by the git fetch / push of results.json.
"""
import base64, io, json, math, os, re, shutil, subprocess, sys, tempfile, time, uuid, zipfile, urllib.request, urllib.error, urllib.parse
from datetime import datetime, timedelta, timezone
from statistics import mean

GUILD = '1572225088340889802'
RESULTS = '1572682487543365843'
HELP = '1572233501518991500'
# the secrets are taken out of the environment at once: no child process (git, the parser) inherits them
TOKEN = os.environ.pop('DISCORD_TOKEN', '').strip()
PUSH_TOKEN = os.environ.pop('GH_PUSH_TOKEN', '').strip()
OUT_JSON = os.environ.get('RESULTS_JSON', '')            # the site's results/results.json (checked out by the workflow)
STATE_JSON = os.path.join(os.path.dirname(OUT_JSON), 'bot-state.json') if OUT_JSON else ''
SITE_BRANCH = os.environ.get('SITE_BRANCH', 'results-data')   # holds only results/*.json, one commit, no history
HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, '..', 'discord-status', 'fonts')
API = 'https://discord.com/api/v10'
PINK = 0xF4B6CB
DRY = '--dry' in sys.argv

# limits for attachments (anyone can post them)
MAX_ATTACH = 25_000_000         # one attachment (Discord's own limit for normal servers)
MAX_TXT = 2_000_000             # a single summary.txt attachment
MAX_FILE = 2_000_000            # one summary.txt inside an archive (uncompressed)
MAX_SUMMARIES = 200             # summary.txt files per post
MAX_TOTAL = 20_000_000          # all summary.txt files of a post together (uncompressed)
MAX_LISTED = 20_000             # entries of any kind in one archive's list
MAX_7Z_ALL = 512_000_000        # everything in a 7z (a solid 7z unpacks the files before a summary.txt too)
WORKER_MEM = 1 << 30            # address space of the parser process
WORKER_TIMEOUT = 60             # seconds per post
MAX_TRIES = 2                   # a results post whose reading failed this often is not tried again
PING_EVERY = 600                # the owner is called at most once per discussion in 10 minutes
CMD_EVERY = 30                  # one command answer per person in 30 seconds


def retry_after(headers, body):
    """Seconds to wait after a 429: the JSON body's retry_after, else the Retry-After header, else 2 (never trusts either blindly)."""
    for get in (lambda: json.loads(body or b'{}').get('retry_after'), lambda: (headers or {}).get('Retry-After')):
        try:
            v = float(get())
            if math.isfinite(v) and v >= 0: return min(v, 60.0)
        except Exception:
            pass
    return 2.0


def http(url, method='GET', data=None, headers=None, ctype=None, limit=None):
    """GET/POST with retries: 429 waits as Discord asks, 5xx and network errors back off 1, 2, 4 … 30 s.
    limit: read at most limit + 1 bytes of the body (the caller checks the length)."""
    h = {'User-Agent': 'DomainOS-bot (github actions)'}
    h.update(headers or {})
    if ctype: h['Content-Type'] = ctype
    delay = 1.0
    for attempt in range(6):
        req = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, (r.read(limit + 1) if limit else r.read())
        except urllib.error.HTTPError as e:
            try: body = e.read(1_000_000)
            except Exception: body = b''
            if e.code == 429 and attempt < 5:
                time.sleep(retry_after(e.headers, body) + .5); continue
            if 500 <= e.code < 600 and attempt < 5:
                time.sleep(delay); delay = min(delay * 2, 30); continue
            return e.code, body
        except Exception:
            time.sleep(delay); delay = min(delay * 2, 30)
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


_answered = set()   # threads where the bot has a message: once true, it stays true (no second request)


def answered(tid, me):
    if tid in _answered: return True
    if any(m['author']['id'] == me for m in dc('GET', f'/channels/{tid}/messages?limit=50')):
        _answered.add(tid); return True
    return False


def reply(tid, comps, files=()):
    payload = {'flags': 1 << 15, 'components': comps, 'attachments': [{'id': i, 'filename': n} for i, (n, _) in enumerate(files)],
               'allowed_mentions': {'parse': []}}
    if DRY:
        print('DRY reply', tid, json.dumps(comps, ensure_ascii=False)[:600]); return None
    b = uuid.uuid4().hex
    parts = [f'--{b}\r\nContent-Disposition: form-data; name="payload_json"\r\nContent-Type: application/json\r\n\r\n'.encode(), json.dumps(payload).encode(), b'\r\n']
    for i, (n, data) in enumerate(files):
        parts += [f'--{b}\r\nContent-Disposition: form-data; name="files[{i}]"; filename="{n}"\r\nContent-Type: image/png\r\n\r\n'.encode(), data, b'\r\n']
    parts.append(f'--{b}--\r\n'.encode())
    m = dc('POST', f'/channels/{tid}/messages', raw=b''.join(parts), ctype=f'multipart/form-data; boundary={b}')
    _answered.add(tid)
    return m


def clean(s, limit=None):
    """User text that goes into a bot message or the website: no mentions (@everyone, @here, users, roles, channels),
    no custom emoji, masked links [text](url) become their text. The patterns are bounded (no slow regex)."""
    s = str(s or '')
    if limit: s = s[:limit * 2]
    s = re.sub(r'<(?:@[!&]?|#)\d{1,25}>', '', s)
    s = re.sub(r'<a?:\w{1,64}:\d{1,25}>', '', s)
    s = re.sub(r'@(everyone|here)', r'\1', s, flags=re.I)
    s = re.sub(r'\[([^\[\]\n]{0,300})\]\([^()\s]{0,2000}\)', r'\1', s)
    s = s.strip()
    return s[:limit] if limit else s


T = lambda s: {'type': 10, 'content': s}
SEP = {'type': 14, 'divider': True, 'spacing': 2}
card = lambda comps: {'type': 17, 'accent_color': PINK, 'components': comps}

# ===================================================================================================================
# results
# ===================================================================================================================


class Refused(Exception):
    """An attachment that is not read on purpose (too many / too big files, broken archive); the text says why."""


SIGN = b'Domain SchedTest'
KINDS = ('.zip', '.7z', '.txt')


def _looks_like_summary(head):
    return SIGN in head[:200]


def summaries_from(name, data, budget=None):
    """All DomainSchedTest summary.txt texts inside an attachment (zip, 7z or a single txt).
    Every limit is checked from the archive's own list BEFORE anything is unpacked; a file whose first bytes are not a
    DomainSchedTest summary is not read further. budget = {'n', 'bytes'} shared by all attachments of one post.
    Raises Refused when the attachment breaks a limit or cannot be read."""
    budget = budget if budget is not None else {'n': 0, 'bytes': 0}
    low = name.lower()
    out = []

    def take(sizes):
        """sizes: the uncompressed sizes of the summary.txt candidates, from the archive's list."""
        if any(s is None or s < 0 for s in sizes): raise Refused('a file without a size in the archive list')
        if any(s > MAX_FILE for s in sizes): raise Refused(f'a summary.txt larger than {MAX_FILE // 1_000_000} MB')
        if budget['n'] + len(sizes) > MAX_SUMMARIES: raise Refused(f'more than {MAX_SUMMARIES} summary.txt files')
        if budget['bytes'] + sum(sizes) > MAX_TOTAL: raise Refused(f'summary.txt files over {MAX_TOTAL // 1_000_000} MB in total')
        budget['n'] += len(sizes); budget['bytes'] += sum(sizes)

    def keep(body):
        if len(body) > MAX_FILE: raise Refused('a summary.txt is larger than the archive says')
        if _looks_like_summary(body):
            out.append(body.decode('utf-8-sig', 'replace'))

    try:
        if low.endswith('.zip'):
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                infos = z.infolist()
                if len(infos) > MAX_LISTED: raise Refused(f'more than {MAX_LISTED} files in the archive')
                cand = [i for i in infos if not i.is_dir() and i.filename.lower().endswith('summary.txt')]
                take([i.file_size for i in cand])
                for i in cand:
                    with z.open(i) as f:
                        head = f.read(256)
                        if not _looks_like_summary(head): continue
                        keep(head + f.read(MAX_FILE + 1 - len(head)))
        elif low.endswith('.7z'):
            import py7zr
            with py7zr.SevenZipFile(io.BytesIO(data), 'r') as z:
                if z.needs_password(): raise Refused('the archive has a password')
                infos = z.list()
                if len(infos) > MAX_LISTED: raise Refused(f'more than {MAX_LISTED} files in the archive')
                if sum(i.uncompressed or 0 for i in infos) > MAX_7Z_ALL: raise Refused(f'the 7z unpacks to over {MAX_7Z_ALL // 1_000_000} MB')
                cand = [i for i in infos if not i.is_directory and i.filename.lower().endswith('summary.txt')]
                take([i.uncompressed for i in cand])
                if cand:
                    for n, bio in (z.read([i.filename for i in cand]) or {}).items():
                        keep(bio.read(MAX_FILE + 1))
        elif low.endswith('.txt'):
            if len(data) > MAX_TXT: raise Refused(f'the txt file is larger than {MAX_TXT // 1_000_000} MB')
            if _looks_like_summary(data[:256]):
                take([len(data)]); keep(data)
    except Refused:
        raise
    except MemoryError:
        raise Refused('the archive needs too much memory')
    except Exception as e:
        raise Refused(f'the archive could not be read ({type(e).__name__})')
    return out


def _finite(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


TEXT_KEYS = ('label', 'date', 'cpu', 'windows', 'game', 'domainos', 'mode')


def worker_main(wd):
    """--parse-worker DIR: reads every attachment in DIR (000.zip, 001.txt …) and prints {"runs", "refused"} as JSON.
    Runs in its own process with limits on memory, CPU time and file writes, so a hostile archive can only kill this
    process, never the bot."""
    import resource
    resource.setrlimit(resource.RLIMIT_AS, (WORKER_MEM, WORKER_MEM))
    resource.setrlimit(resource.RLIMIT_CPU, (WORKER_TIMEOUT, WORKER_TIMEOUT + 5))
    resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    runs, refused, budget = [], [], {'n': 0, 'bytes': 0}
    for f in sorted(os.listdir(wd)):
        stem, ext = os.path.splitext(f)
        if not stem.isdigit() or ext not in KINDS: continue
        with open(os.path.join(wd, f), 'rb') as fh:
            data = fh.read(MAX_ATTACH + 1)
        try:
            texts = summaries_from(f, data, budget)
        except Refused as e:
            refused.append({'i': int(stem), 'why': str(e)}); continue
        for s in texts:
            try:
                r = parse(s)
            except Exception:
                r = None
            if r: runs.append(r)
    secret = sorted(k for k in os.environ if any(w in k.upper() for w in ('TOKEN', 'SECRET', 'PASSWORD', 'KEY')))
    sys.stdout.buffer.write(json.dumps({'runs': runs, 'refused': refused, 'uid': os.getuid(), 'secret_env': secret}).encode())


class WorkerFailed(Exception):
    """The parser process crashed, ran out of memory or time: counts as a failed attempt for the post.
    .public is the short reason shown to the author (the full one, with the process's last words, goes to the log)."""
    def __init__(self, msg, public='the archive could not be read'):
        super().__init__(msg); self.public = public


_prefix = None


def _worker_env():
    env = {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8', 'HOME': '/tmp'}
    if os.environ.get('LD_LIBRARY_PATH'): env['LD_LIBRARY_PATH'] = os.environ['LD_LIBRARY_PATH']   # setup-python's libpython
    return env


def _run_worker(files, prefix):
    """files: [(name, bytes)]. A fresh directory readable by everyone, the bot's own code copied there, the parser
    started with an environment built from scratch (no tokens) and isolated mode (-I: no PYTHON* variables, the
    attachments' folder is not on the import path)."""
    wd = tempfile.mkdtemp(prefix='domainos-parse-')
    try:
        os.chmod(wd, 0o755)
        src = os.path.join(wd, 'worker.py')
        shutil.copyfile(os.path.abspath(__file__), src); os.chmod(src, 0o644)
        for i, (name, data) in enumerate(files):
            ext = next(k for k in KINDS if name.lower().endswith(k))
            p = os.path.join(wd, f'{i:03d}{ext}')
            with open(p, 'wb') as fh: fh.write(data)
            os.chmod(p, 0o644)
        env = _worker_env()
        cmd = prefix + ['/usr/bin/env', '-i', *(f'{k}={v}' for k, v in env.items()), sys.executable, '-I', src, '--parse-worker', wd]
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=wd, env=env)
        try:
            out, err = p.communicate(timeout=WORKER_TIMEOUT)
        except subprocess.TimeoutExpired:
            p.terminate()                                # sudo passes SIGTERM on to the parser
            try: p.communicate(timeout=5)
            except subprocess.TimeoutExpired: p.kill(); p.communicate()
            raise WorkerFailed(f'no answer in {WORKER_TIMEOUT} s', f'reading took longer than {WORKER_TIMEOUT} s')
        if p.returncode != 0:
            raise WorkerFailed(f'exit code {p.returncode}: {err.decode("utf-8", "replace")[-300:]}', 'reading stopped (too much memory or a broken archive)')
        try:
            res = json.loads(out)
        except Exception:
            raise WorkerFailed('no JSON from the parser')
        if not isinstance(res, dict): raise WorkerFailed('wrong answer from the parser')
        return res
    finally:
        shutil.rmtree(wd, ignore_errors=True)


def worker_prefix():
    """On GitHub Actions the parser runs as the user "nobody" (sudo -n): it cannot read the bot's memory or environment
    (/proc), the workspace's git files or anything the runner user owns. Checked once with an empty run; when that
    does not work (or locally), a plain process with the same limits and the same clean environment."""
    global _prefix
    if _prefix is not None: return _prefix
    _prefix = []
    if os.environ.get('GITHUB_ACTIONS') == 'true' and shutil.which('sudo'):
        pre = ['sudo', '-n', '-u', 'nobody', '--']
        try:
            res = _run_worker([], pre)
            if res.get('uid') not in (None, os.getuid()) and not res.get('secret_env'):
                _prefix = pre; print('parser: runs as nobody, uid', res.get('uid'))
            else:
                print('!!! parser: the nobody check gave', res, '- using a plain process')
        except Exception as e:
            print('!!! parser: cannot run as nobody (', e, ') - using a plain process')
    return _prefix


def read_attachments(files):
    """[(name, bytes)] → (runs, refused) read in the parser process. Raises WorkerFailed when that process fails."""
    if not files: return [], []
    res = _run_worker(files, worker_prefix())
    if res.get('secret_env'): print('!!! parser environment has', res['secret_env'])
    runs = []
    for r in res.get('runs') or []:                       # only plain strings and finite numbers come back
        if not isinstance(r, dict): continue
        x = {k: str(r.get(k) or '')[:200] for k in TEXT_KEYS}
        if x['mode'] not in ('game', 'idle'): continue
        x['label'] = x['label'] or 'run'
        for m in METRICS:
            if _finite(r.get(m[0])): x[m[0]] = float(r[m[0]])
        runs.append(x)
    refused = []
    for f in res.get('refused') or []:
        try: refused.append((files[int(f['i'])][0], str(f.get('why', ''))[:200]))
        except Exception: pass
    return runs, refused


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


MAX_LINE = 400   # real summary lines are under 250 characters


def parse(s):
    """All numbers of one DomainSchedTest summary.txt (versions 1.4–1.6); missing ones stay absent.
    The text comes from anyone: it is cut to MAX_FILE, every line to MAX_LINE characters, and no pattern spans more
    than one line or block, so every search is linear (a crafted 2 MB text takes milliseconds, not minutes)."""
    s = s[:MAX_FILE].replace('\r\n', '\n')
    s = '\n'.join(l[:MAX_LINE] for l in s.split('\n'))
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
    m = re.search(r'рывков \([^)\n]*\): ([\d,]+)', s)
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
    i = s.find('Все процессы: ожиданий дольше 50 мкс')       # the block of all processes, up to its blank line
    if i >= 0:
        cause = s[i:i + 8000]; cause = cause[:cause.find('\n\n')] if '\n\n' in cause else cause
        m = re.search(r'на ядре во время ожидания был DPC/ISR:[ \t]+[\d,]+[ \t]+\([ \t]*([\d.,]+)%\)', cause)
        if m: r['dpc'] = NUM(m.group(1))
    m = re.search(r'Нагрузка Domain OS Toolbox за замер: ([\d.,]+)%', s)
    if m: r['tb'] = NUM(m.group(1))
    bg = re.findall(r'^[ \t]+(steam|steamwebhelper|gameoverlayui|steamservice|discord)[ \t]+\d+[ \t]+([\d.,]+)[ \t]+[\d.,]+[ \t]+[\d.,]+[ \t]+\S+[ \t]+\S+[ \t]+([\d.,]+|—)', s, re.M)
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
    from PIL import Image, ImageDraw, ImageFont          # here, so the parser process never loads Pillow
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


def could_not_read(reasons=()):
    why = '; '.join(dict.fromkeys(clean(r, 120) for r in reasons if r))[:600]
    return [card([T('🇬🇧 **Could not read this archive.** Please check: a normal zip or 7z of the `results` folder (no password), '
                    f'at most {MAX_SUMMARIES} runs, every `summary.txt` under {MAX_FILE // 1_000_000} MB and {MAX_TOTAL // 1_000_000} MB of `summary.txt` files in total '
                    '(the other files of the folder do not count). Then make a new post with the fixed archive.\n'
                    '🇷🇺 **Не удалось прочитать этот архив.** Проверьте: обычный zip или 7z папки `results` (без пароля), '
                    f'не больше {MAX_SUMMARIES} прогонов, каждый `summary.txt` меньше {MAX_FILE // 1_000_000} МБ, все `summary.txt` вместе — не больше {MAX_TOTAL // 1_000_000} МБ '
                    '(остальные файлы папки не считаются). Затем создайте новый пост с исправленным архивом.'
                    + (f'\n-# {why}' if why else ''))])]


def handle_result(t, me, store):
    starter = dc('GET', f'/channels/{t["id"]}/messages/{t["id"]}')
    files = []
    for a in starter.get('attachments', []):
        name = str(a.get('filename') or '')
        if not name.lower().endswith(KINDS): continue
        cap = MAX_TXT if name.lower().endswith('.txt') else MAX_ATTACH
        if int(a.get('size') or 0) > cap: continue
        st, data = http(a['url'], limit=cap)               # the CDN link needs no token
        if st != 200: raise RuntimeError(f'download {name}: {st}')
        if len(data) > cap: continue
        files.append((name, data))
    runs, refused = read_attachments(files)              # WorkerFailed counts as a failed attempt (pass_results)
    if not runs and refused:
        reply(t['id'], could_not_read(f'{n}: {w}' for n, w in refused))
        return
    if not runs:
        reply(t['id'], [card([T('🇬🇧 No DomainSchedTest runs found in this post. Attach the **zipped `results` folder** (zip or 7z) with all runs — every run folder has a `summary.txt`.\n'
                                '🇷🇺 В посте не нашлось прогонов DomainSchedTest. Приложите **архив папки `results`** (zip или 7z) со всеми прогонами — в каждой папке прогона есть `summary.txt`.')])])
        return
    for r in runs:                                        # text from the post goes into messages: no pings, no links
        for k in ('cpu', 'windows', 'game', 'domainos'): r[k] = clean(r[k], 120)
        r['label'] = clean(r['label'], 60).replace('`', "'") or 'run'
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
    if refused:
        extra += '\n-# 🇬🇧 Not read · 🇷🇺 Не прочитано: ' + '; '.join(f'{clean(n_, 60)} ({clean(w, 80)})' for n_, w in refused)[:400]
    hw = runs[0]
    info = ' · '.join(x for x in (hw['cpu'], hw['windows'], hw['game'], ('Domain OS ' + hw['domainos']) if hw['domainos'] else '', 'idle · простой' if mode == 'idle' else '') if x)
    title = clean(t.get('name'), 80) or 'Results'
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
    store.append({'thread': t['id'], 'reply': (m or {}).get('id', ''), 'title': title, 'note': note_of(starter), 'week': week_for_new(t['id']), 'url': f'https://discord.com/channels/{GUILD}/{t["id"]}', 'date': runs[0]['date'][:10],
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
     '🇬🇧 Windows protection stays as it is: Defender, memory integrity, Secure Boot and TPM are not changed. Domain OS does not touch game files and injects nothing into games: it changes only Windows settings, and every change can be undone. Anti-cheat developers have not officially confirmed compatibility, so the decision is yours.\n'
     '🇷🇺 Защита Windows остаётся как есть: Defender, целостность памяти, Secure Boot и TPM не меняются. Domain OS не трогает файлы игр и ничего в них не внедряет: меняются только настройки Windows, и любое изменение можно откатить. Разработчики античитов официально совместимость не подтверждали, поэтому решение остаётся за вами.'),
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
     '🇬🇧 The benchmark tool and a beginner guide are in <#1572685486311342081>; post results in <#1572682487543365843> — the bot answers with a chart. '
     'How to measure fairly (the same number of runs, a repeatable demo): https://6kane1.github.io/DomainOS/measure.html\n'
     '🇷🇺 Программа замеров и инструкция для новичков — в <#1572685486311342081>; результаты выкладывайте в <#1572682487543365843> — бот ответит графиком. '
     'Как мерить честно (поровну прогонов, повторяемое демо): https://6kane1.github.io/DomainOS/ru/measure.html'),
    (['home', 'хоум', 'домашн', 'только pro', 'pro only', 'останов', 'halt', 'не ставится', 'не устанавлив', 'первом шаге'], '**The install stops at the first step** · **Установка остановилась на первом шаге**',
     '🇬🇧 Domain OS installs on **Windows 11 Pro** only. Check Settings → System → About. On Home: switch to Pro with a Pro key (Settings → System → Activation).\n'
     '🇷🇺 Domain OS ставится только на **Windows 11 Pro**. Проверьте «Параметры → Система → О системе». На Home — перейдите на Pro своим ключом («Параметры → Система → Активация»).'),
    (['откат', 'вернуть', 'верни', 'undo', 'restore', 'удалить сборк', 'снести', 'снест', 'убрать сборк', 'как было'], '**How to undo** · **Как откатить**',
     '🇬🇧 Start → Domain OS → **Undo Domain OS**, then restart. Toolbox changes: "Undo everything" in Toolbox. '
     'Step by step and how to check that everything is back: <#1573077842302996550> · https://6kane1.github.io/DomainOS/undo.html\n'
     '🇷🇺 «Пуск» → Domain OS → **Undo Domain OS** и перезагрузка. Изменения Toolbox: «Вернуть всё как было» в Toolbox. '
     'Пошагово и как проверить, что всё вернулось: <#1573077842302996550> · https://6kane1.github.io/DomainOS/ru/undo.html'),
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
    m = dc('POST', f'/channels/{tid}/messages', body)
    _answered.add(tid)
    return m


def is_command(text):
    """A bot command: /word (shown everywhere) or !word (the old prefix, still understood). Typed as a plain message:
    the bot registers no Discord slash commands (those need a server that answers within 3 s), so Discord sends
    "/install" as text when no registered command has that name."""
    t = text.lstrip()
    return len(t) > 1 and t[0] in '/!' and (t[1].isalpha())


def handle_help(t):
    """A new help post: a FAQ answer when it is a basic question, otherwise the author is called."""
    starter = dc('GET', f'/channels/{t["id"]}/messages/{t["id"]}')
    if is_command(starter.get('content') or ''):
        return False                                   # the post starts with a command: only the command is answered
    text = (t.get('name') or '') + ' ' + (starter.get('content') or '')
    if faq_hits(text):
        reply(t['id'], faq_reply(text) + [card([T(COMMANDS_HINT)])])
    else:
        say(t['id'], f'<@&{OWNER_ROLE}> 🙋 a new question needs a person · новый вопрос — нужен человек.\n'
                     '🇬🇧 Thanks! The author will answer here. Meanwhile add: versions, `winver`, CPU/GPU and the two logs (`/logs`). · '
                     '🇷🇺 Спасибо! Автор ответит здесь. Пока добавьте: версии, `winver`, процессор/видеокарту и два журнала (`/logs`).', ping_owner=True)


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
COMMANDS_HINT = ('🙋 **Didn\'t help? Type `/human` — the author will answer. · Не помогло? Напишите `/человек` — ответит автор.**\n'
                 '-# 🇬🇧 All commands: `/help` · ask the bot: `/ask your question`. · 🇷🇺 Все команды: `/help` · спросить бота: `/ask ваш вопрос`.')
HUMAN_BLOCK = ('> ## 🙋 `/human` · `/человек`\n'
               '> 🇬🇧 **Remember this one: it calls the author.** The bot did not help, the answer does not fit, something is broken — type `/human` and the author answers right here.\n'
               '> 🇷🇺 **Запомните эту команду: она зовёт автора.** Бот не помог, ответ не подходит, что-то сломалось — напишите `/человек`, и автор ответит прямо здесь.\n')
HELP_TEXT = (HUMAN_BLOCK + '\n## ⌨️ All commands · Все команды\n'
             '🇬🇧 Type a command in this discussion — the bot answers within about 5 minutes (it checks the server every 5 minutes). Russian names work too.\n'
             '🇷🇺 Напишите команду в этом обсуждении — бот ответит в течение ~5 минут (он проверяет сервер раз в 5 минут). Русские названия тоже работают.\n'
             '```\n'
             '/install   /установка   how to install · как установить\n'
             '/download  /скачать     where to download · где скачать\n'
             '/windows   /винда       which Windows · какая Windows\n'
             '/pro       /home        stops at step 1 · остановилась на 1 шаге\n'
             '/undo      /откат       undo everything · откатить всё\n'
             '/drivers   /дрова       drivers · драйверы\n'
             '/fps       /лаги        FPS, stutter · FPS, рывки\n'
             '/crash     /вылеты      crashes, blue screen · вылеты, синий экран\n'
             '/toolbox   /тулбокс     how to use Toolbox · Toolbox\n'
             '/nogame    /игра        Toolbox does not see the game · не видит игру\n'
             '/anticheat /античит     FACEIT, Vanguard, EAC · античиты\n'
             '/safe      /бан         safe? bans? · безопасно? бан?\n'
             '/laptop    /ноут        laptops · ноутбуки\n'
             '/update    /обновления  updates · обновления\n'
             '/wallpaper /обои        wallpapers · обои\n'
             '/bench     /замеры      benchmarks · замеры\n'
             '/logs      /логи        which files to attach · какие файлы приложить\n'
             '/about     /что         what Domain OS is · что такое Domain OS\n'
             '/ask …     /вопрос …    the bot looks for an answer · бот ищет ответ\n'
             '```')
LOGS = ('### 📄 Logs to attach · Какие файлы приложить\n'
        '🇬🇧 `%ProgramData%\\Domain OS\\Logs\\install.log` (the install) and `%LOCALAPPDATA%\\DomainScheduler\\log.txt` (Toolbox). Paste the path into Win+R, the folder opens.\n'
        '🇷🇺 `%ProgramData%\\Domain OS\\Logs\\install.log` (установка) и `%LOCALAPPDATA%\\DomainScheduler\\log.txt` (Toolbox). Вставьте путь в Win+R — откроется папка.')


def faq_hits(text):
    norm = _norm(text); words = norm.split()
    return [n for n, (k, h, a) in enumerate(FAQ) if faq_score(k, norm, words) > 0]


def faq_by_title(start):
    return next(((h, a) for k, h, a in FAQ if h.strip('*').startswith(start)), None)


def answer_command(tid, m, may_ping=True):
    """may_ping: False when the bot already called the owner in this discussion in the last 10 minutes."""
    raw = (m.get('content') or '').strip()
    word, _, rest = raw.lstrip()[1:].partition(' ')
    cmd = word.lower().strip('.,!?')
    cmd = ALIAS.get(cmd, cmd)
    ref = m['id']
    if cmd in ('help', 'commands', 'h'):
        reply_ref(tid, [card([T(HELP_TEXT)])], ref); return
    if cmd == 'logs':
        reply_ref(tid, [card([T(LOGS)])], ref); return
    who = clean(m['author'].get('global_name') or m['author'].get('username'), 40) or '?'
    called = '-# 🇬🇧 The author was already called a few minutes ago and will answer here. · 🇷🇺 Автора уже позвали несколько минут назад, он ответит здесь.'
    if cmd in ('human', 'person'):
        if may_ping:
            say(tid, f'<@&{OWNER_ROLE}> 🙋 {who} asks for the author · просит автора.', ref, ping_owner=True)
        else:
            say(tid, f'🙋 {who} asks for the author · просит автора.\n' + called, ref)
        return
    if cmd == 'ask':
        if faq_hits(rest):
            reply_ref(tid, faq_reply(rest) + [card([T(COMMANDS_HINT)])], ref)
        else:
            q = clean(rest, 300)
            if may_ping:
                say(tid, f'<@&{OWNER_ROLE}> 🙋 no basic answer for this question · на этот вопрос нет готового ответа: «{q}»\n'
                         '-# 🇬🇧 The author will answer here. · 🇷🇺 Автор ответит здесь.', ref, ping_owner=True)
            else:
                say(tid, f'🙋 no basic answer for this question · на этот вопрос нет готового ответа: «{q}»\n' + called, ref)
        return
    if cmd in CMD:
        hit = faq_by_title(CMD[cmd])
        if hit:
            reply_ref(tid, [card([T(f'### {hit[0]}\n{hit[1]}'), T(COMMANDS_HINT)])], ref); return
    w = clean(word, 30).replace('`', "'")
    reply_ref(tid, [card([T(f'🇬🇧 Unknown command `/{w}`. · 🇷🇺 Нет такой команды `/{w}`.\n' + HELP_TEXT)])], ref)


def reply_ref(tid, comps, ref):
    payload = {'flags': 1 << 15, 'components': comps, 'message_reference': {'message_id': ref, 'fail_if_not_exists': False},
               'allowed_mentions': {'parse': []}}
    if DRY: print('DRY reply_ref', tid, json.dumps(comps, ensure_ascii=False)[:300]); return None
    m = dc('POST', f'/channels/{tid}/messages', payload)
    _answered.add(tid)
    return m


_seen = {}
_last_cmd = {}      # person → time of the bot's last command answer to them (this shift)


def _when(m):
    return datetime.fromisoformat(m['timestamp'].replace('Z', '+00:00'))


def commands_in(t, me):
    """Answers the command messages (/word or !word) in a help discussion that the bot has not answered yet (replies point to it).
    Against spam: per person only their newest command counts and gets at most one answer in CMD_EVERY seconds
    (a command that has to wait is answered on a later pass); the owner is called at most once in PING_EVERY seconds
    per discussion (the bot's own recent messages with the role mention are the memory, so it holds across shifts)."""
    if _seen.get(t['id']) == t.get('last_message_id'): return 0
    msgs = dc('GET', f'/channels/{t["id"]}/messages?limit=50')
    mine = [x for x in msgs if x['author']['id'] == me]
    done_refs = {(x.get('message_reference') or {}).get('message_id') for x in mine}
    pings = [_when(x) for x in mine if f'<@&{OWNER_ROLE}>' in (x.get('content') or '')]
    last_ping = max(pings) if pings else None
    n = 0
    now = datetime.now(timezone.utc)
    cmds = [m for m in sorted(msgs, key=lambda x: int(x['id']))
            if not m['author'].get('bot') and is_command(m.get('content') or '')
            and (now - _when(m)).total_seconds() <= 3 * 3600]                 # old commands from before the bot ran: skipped
    newest = {m['author']['id']: m['id'] for m in cmds}
    waiting = False
    for m in cmds:
        uid = m['author']['id']
        if m['id'] in done_refs or newest[uid] != m['id']: continue
        if time.time() - _last_cmd.get(uid, 0) < CMD_EVERY: waiting = True; continue
        may_ping = last_ping is None or (now - last_ping).total_seconds() >= PING_EVERY
        try:
            answer_command(t['id'], m, may_ping); n += 1; _last_cmd[uid] = time.time()
            if may_ping and answer_pings(m): last_ping = now
        except Exception as e: print('cmd', t['id'], e)
    if not waiting: _seen[t['id']] = t.get('last_message_id')
    return n


def answer_pings(m):
    """Whether the answer to this command called the owner (/human, or /ask without a FAQ answer)."""
    raw = (m.get('content') or '').strip()
    word, _, rest = raw.lstrip()[1:].partition(' ')
    cmd = ALIAS.get(word.lower().strip('.,!?'), word.lower().strip('.,!?'))
    return cmd in ('human', 'person') or (cmd == 'ask' and not faq_hits(rest))


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


# ---- weekly top 5 -----------------------------------------------------------------------------------------------
# Results of the current week (Monday–Sunday, Moscow time) all stay on the website. When a week is over, the bot keeps
# its 5 most interesting results there and the rest stay only on Discord. "Interesting" is measured, not guessed:
#   * the biggest clear difference between a variant and the first group (the base) in the main measurements —
#     better OR worse, both are worth knowing; under 2 % counts as noise, more than 30 % counts as 30 %;
#   * times 1 + 0.1 per run (up to 5 runs): more runs, more trust;
#   * +5 for a real comparison (2 or more variants), +1 per variant (up to 6);
#   * when two results are close, a processor that is not in the week's top yet goes first (-3 for a repeat).
# A finished week is never scored again (bot-state.json: finished_weeks): a result posted late for it counts for the
# current week, so there is never a second top for the same week.
MSK = timezone(timedelta(hours=3))
TOP_N = 5
MAIN_KEYS = {'game': ['low1', 'low01', 'ft_p99', 'hitch', 'fps', 'gw_p99'], 'idle': ['p99', 'p999', 'o50', 'p50']}
OLD_METS = [{'key': 'fps', 'hi': True}, {'key': 'low1', 'hi': True}, {'key': 'low01', 'hi': True}]

# The bot's own small memory, kept next to results.json on gh-pages (results/bot-state.json):
#   failed:         {thread: {'n': attempts, 'at': time, 'done': gave up}} — results posts whose reading failed
#   finished_weeks: weeks whose top 5 is chosen (never scored again)
#   announce:       {week: [thread, …]} — finished weeks whose top post is not in Discord yet
STATE = {'failed': {}, 'finished_weeks': [], 'announce': {}}


def posted_of(tid):
    return datetime.fromtimestamp(((int(tid) >> 22) + 1420070400000) / 1000, MSK)


def week_of(dt):
    y, w, _ = dt.isocalendar()
    return f'{y}-W{w:02d}'


def week_for_new(tid):
    """The week a new result counts for: the week of its post, or the current week when that one is finished already."""
    wk = week_of(posted_of(tid))
    return week_of(datetime.now(MSK)) if wk in STATE['finished_weeks'] else wk


def _num(v):
    return v if _finite(v) else None


def score_of(x):
    """(score, why): why = {'key', 'group', 'diff'} — the difference that made the result interesting, or None.
    Tolerates entries without groups / names / metrics (added by hand or by an older bot)."""
    groups = [g for g in (x.get('groups') if isinstance(x.get('groups'), list) else []) if isinstance(g, dict)]
    mlist = x.get('metrics') if isinstance(x.get('metrics'), list) else OLD_METS
    mets = {m.get('key'): m for m in mlist if isinstance(m, dict)}
    best = None
    if len(groups) >= 2:
        base = groups[0]
        for k in MAIN_KEYS.get(x.get('mode') or 'game', MAIN_KEYS['game']):
            b = _num(base.get(k))
            if k not in mets or not b: continue
            for g in groups[1:]:
                v = _num(g.get(k))
                if v is None: continue
                diff = (v / b - 1) * 100                  # as measured (+ = the number went up)
                d = min(abs(diff), 30.0)
                if d >= 2 and (best is None or d > best[0]): best = (d, {'key': k, 'group': str(g.get('name', '?')), 'diff': round(diff, 1)})
    eff = best[0] if best else 0.0
    try: runs = int(x.get('runs') or 1)
    except (TypeError, ValueError): runs = 1
    s = eff * (1 + 0.1 * max(0, min(runs, 5))) + (5 if len(groups) >= 2 else 0) + min(len(groups), 6)
    return round(s, 1), (best[1] if best else None)


def entry_key(x):
    t = str(x.get('thread', '') or '')
    return 'thread:' + t if t else 'json:' + json.dumps(x, sort_keys=True, ensure_ascii=False)


def finish_weeks(store):
    """Every week that is over keeps only its top 5 on the website. The picked entries wait in STATE['announce'] for
    their post (sent after the website has them). Returns the weeks finished now."""
    now = week_of(datetime.now(MSK))
    fin = set(STATE['finished_weeks'])
    fin |= {x['week'] for x in store if isinstance(x.get('week'), str) and 'top' in x}      # older files without the list
    for x in store:
        if not x.get('week') and str(x.get('thread', '')).isdigit():
            wk = week_of(posted_of(x['thread']))
            x['week'] = now if wk in fin else wk
    done = []
    for wk in sorted({x['week'] for x in store if isinstance(x.get('week'), str) and x['week'] < now} - fin):
        items = [x for x in store if x.get('week') == wk]
        for x in items:
            try: x['score'], x['why'] = score_of(x)
            except Exception as e: x['score'], x['why'] = 0.0, None; print('score', x.get('thread'), e)
        left, picked, cpus = list(items), [], set()
        while left and len(picked) < TOP_N:
            x = max(left, key=lambda y: y['score'] - (3 if y.get('cpu') in cpus else 0))
            left.remove(x); picked.append(x); cpus.add(x.get('cpu'))
        for i, x in enumerate(picked, 1): x['top'] = i
        for x in left: store.remove(x); print('week', wk, 'not in top 5, left on Discord only:', x.get('thread'))
        fin.add(wk); done.append(wk)
        STATE['announce'][wk] = [entry_key(x) for x in picked]
    STATE['finished_weeks'] = sorted(fin)
    return done


WEEKLY_TITLE = '🏆 Weekly top 5 · Топ-5 недели'


def announce_weeks(store, me):
    """One post per finished week in the results forum thread "Weekly top 5" (created by the bot on first use).
    Only weeks in STATE['announce']; a week leaves the list once its post is sent, so it is never posted twice."""
    if not STATE['announce'] or DRY: return False
    by = {entry_key(x): x for x in store}
    th = next((t for t in threads(RESULTS) if t.get('owner_id') == me and t.get('name') == WEEKLY_TITLE), None)
    sent = False
    for wk in sorted(STATE['announce']):
        picked = [by[k] for k in STATE['announce'][wk] if k in by]
        if not picked:
            del STATE['announce'][wk]; sent = True; continue
        mon = datetime.strptime(wk + '-1', '%G-W%V-%u'); sun = mon + timedelta(days=6)
        span = f'{mon:%d.%m}–{sun:%d.%m.%Y}'

        def line(x, ru):
            w = x.get('why') if isinstance(x.get('why'), dict) else None
            m = next((m for m in (x.get('metrics') or []) if isinstance(m, dict) and m.get('key') == (w or {}).get('key')), None)
            why = ''
            if w and _finite(w.get('diff')):
                why = f" · `{clean(w.get('group'), 30).replace('`', '')}` {w['diff']:+.1f}% {(m or {}).get('ru' if ru else 'en') or w.get('key', '')}"
            title = clean(x.get('title'), 80).replace('[', '(').replace(']', ')') or 'Results'
            url = str(x.get('url') or '')
            link = f'[{title}]({url})' if url.startswith('https://discord.com/') else title
            return f"**{x.get('top', '?')}.** {link}{why}"
        en = (f'## 🇬🇧 🏆 Top {len(picked)} of the week {span}\n' + '\n'.join(line(x, False) for x in picked)
              + '\n-# Chosen by the bot: the biggest clear difference between variants (over 2 % noise), more runs, different processors. These stay on the website; the other results of the week stay here on Discord.')
        ru = (f'## 🇷🇺 🏆 Топ-{len(picked)} недели {span}\n' + '\n'.join(line(x, True) for x in picked)
              + '\n-# Выбирает бот: самая заметная разница между вариантами (больше 2 % разброса), больше прогонов, разные процессоры. Эти замеры остаются на сайте, остальные замеры недели остаются здесь, в Discord.')
        comps = [card([T(en[:3900]), {'type': 14, 'divider': True, 'spacing': 2}, T(ru[:3900])])]
        if th is None:
            th = dc('POST', f'/channels/{RESULTS}/threads', {'name': WEEKLY_TITLE, 'message': {'flags': 1 << 15, 'components': comps, 'allowed_mentions': {'parse': []}}})
        else:
            reply(th['id'], comps)
        del STATE['announce'][wk]; sent = True
    return sent


def note_of(starter):
    """The author's own words from the forum post (what was tested and how), shown on the website with the numbers.
    Mentions are dropped; at most 1500 characters."""
    t = clean(starter.get('content') or '')
    t = '\n'.join(l.rstrip() for l in t.strip().splitlines())
    return t[:1500] + ('…' if len(t) > 1500 else '')


def pass_results(me, store):
    done = 0
    # entries saved before 2026-11-18 have no author text yet: fetch it once
    for x in store:
        if 'note' not in x and str(x.get('thread', '')).isdigit():
            try: x['note'] = note_of(dc('GET', f'/channels/{x["thread"]}/messages/{x["thread"]}'))
            except Exception as e: print('note', x.get('thread'), e)
    known = {str(x.get('thread', '')) for x in store}
    failed = STATE['failed']
    for t in threads(RESULTS):
        tid = t['id']
        try:
            if t.get('owner_id') == me or tid in known or (failed.get(tid) or {}).get('done') or answered(tid, me): continue
        except Exception as e:
            print('result', tid, e); continue
        # the attempt is written down BEFORE the risky part: a post that kills the bot is not tried forever
        n = int((failed.get(tid) or {}).get('n') or 0) + 1
        failed[tid] = {'n': n, 'at': datetime.now(timezone.utc).isoformat(timespec='seconds')}
        save_local(store)
        try:
            handle_result(t, me, store); done += 1
            failed.pop(tid, None)
        except Exception as e:
            print('result', tid, 'attempt', n, 'of', MAX_TRIES, type(e).__name__, e)
            if n >= MAX_TRIES:
                failed[tid]['done'] = True
                try: reply(tid, could_not_read([e.public] if isinstance(e, WorkerFailed) else ()))
                except Exception as e2: print('could-not-read reply', tid, e2)
    # forget old failures (the bot only sees active threads anyway)
    cut = (datetime.now(timezone.utc) - timedelta(days=60)).isoformat()
    for tid in [k for k, v in failed.items() if str((v or {}).get('at', '')) < cut]: failed.pop(tid)
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


# ---- results.json / bot-state.json on the branch results-data ----------------------------------------------------
# The branch holds only these two files in ONE commit without parents: every publish replaces it (force push with a
# lease), so a removed post or a changed author note is gone from GitHub's history too, not only from the page. The
# site (gh-pages) has no results data; .github/workflows/pages.yml puts results.json next to the page when it
# publishes the site, and the bot's workflow starts it after every publish (marker file .published next to the repo).
# The files are only ever replaced whole (temp file + rename). publish() never loses a hand edit: it fetches the
# branch, takes what the bot changed since its last sync (the commit the worktree stands on) and applies just that to
# the current remote file, entry by entry (thread id), then pushes; when someone pushed in between it starts over.


def valid_store(d):
    return isinstance(d, list) and all(isinstance(x, dict) for x in d)


def load_store():
    """results.json → list of dicts; [] when there is none yet; None when it is broken (then the bot does NOT touch
    the results this shift, so a broken file can never turn into an empty website)."""
    if not OUT_JSON or not os.path.exists(OUT_JSON): return []
    try:
        with open(OUT_JSON, encoding='utf-8') as f: d = json.load(f)
    except Exception as e:
        print(f'!!! {OUT_JSON} cannot be read ({e}): results are NOT handled or published in this shift — fix the file on the branch results-data'); return None
    if not valid_store(d):
        print(f'!!! {OUT_JSON} is not a list of entries: results are NOT handled or published in this shift — fix the file on the branch results-data'); return None
    return d


def load_state():
    if not STATE_JSON or not os.path.exists(STATE_JSON): return
    try:
        with open(STATE_JSON, encoding='utf-8') as f: d = json.load(f)
        if not isinstance(d, dict): raise ValueError('not an object')
    except Exception as e:
        print(f'!!! {STATE_JSON} cannot be read ({e}): starting with an empty one (finished weeks come from results.json)'); return
    STATE['failed'] = {str(k): v for k, v in (d.get('failed') or {}).items() if isinstance(v, dict)} if isinstance(d.get('failed'), dict) else {}
    STATE['finished_weeks'] = sorted({w for w in (d.get('finished_weeks') or []) if isinstance(w, str)}) if isinstance(d.get('finished_weeks'), list) else []
    STATE['announce'] = {k: [str(i) for i in v] for k, v in (d.get('announce') or {}).items() if isinstance(v, list)} if isinstance(d.get('announce'), dict) else {}


def write_atomic(path, obj):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)


def save_local(store):
    """The bot's current view on disk (so that the workflow's last step can still publish it if the bot dies)."""
    if not OUT_JSON or DRY: return
    write_atomic(OUT_JSON, store)
    write_atomic(STATE_JSON, STATE)


def _git(repo, *a, auth=False):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    if auth and PUSH_TOKEN:
        # the token goes to this one git process only, in its environment (not on the command line, not in .git/config)
        env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='http.https://github.com/.extraheader',
                   GIT_CONFIG_VALUE_0='AUTHORIZATION: basic ' + base64.b64encode(f'x-access-token:{PUSH_TOKEN}'.encode()).decode())
    return subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True, env=env)


def _git_json(repo, rev, rel):
    """The file at a commit: list, [] when the commit has no such file, None when it cannot be read or is broken."""
    r = _git(repo, 'show', f'{rev}:{rel}')
    if r.returncode != 0:
        return [] if ('does not exist' in r.stderr or 'exists on disk, but not in' in r.stderr) else None
    try: d = json.loads(r.stdout)
    except Exception: return None
    return d if valid_store(d) else None


def merge(base, ours, theirs):
    """Three-way merge by entry: what the bot changed since base (added, edited, removed) is applied to theirs;
    everything else in theirs (hand edits, hand-added entries, hand deletions) stays."""
    canon = lambda x: json.dumps(x, sort_keys=True, ensure_ascii=False)
    b = {entry_key(x): canon(x) for x in base}
    o = {entry_key(x): x for x in ours}
    out, seen = [], set()
    for x in theirs:
        k = entry_key(x)
        if k in b and (k not in o or canon(o[k]) != b[k]):
            if k in o and k not in seen: out.append(o[k]); seen.add(k)          # changed by the bot: the bot's version
            continue                                                              # removed by the bot
        if k in o and k not in b:                                                 # added on both sides: the bot's
            if k not in seen: out.append(o[k]); seen.add(k)
            continue
        out.append(x); seen.add(k)
    for x in ours:                                                                # new from the bot
        k = entry_key(x)
        if k not in b and k not in seen: out.append(x); seen.add(k)
    return out


def publish(store):
    """Pushes results.json and bot-state.json to the branch results-data at once (the workflow checked it out).
    Returns True when the site has the bot's view (or there was nothing to push)."""
    if not OUT_JSON or DRY: return True
    repo = os.path.dirname(os.path.dirname(os.path.abspath(OUT_JSON)))
    rel = os.path.relpath(os.path.abspath(OUT_JSON), repo)
    rel_state = os.path.relpath(os.path.abspath(STATE_JSON), repo)
    remote = f'refs/remotes/origin/{SITE_BRANCH}'
    for attempt in range(3):
        base = _git_json(repo, 'HEAD', rel)
        f = _git(repo, 'fetch', '-q', '--depth=1', 'origin', f'+refs/heads/{SITE_BRANCH}:{remote}', auth=True)
        if f.returncode != 0:
            print('publish: fetch failed', f.stderr.strip()[:300]); time.sleep(5 * (attempt + 1)); continue
        theirs = _git_json(repo, remote, rel)
        if base is None or theirs is None:
            print(f'!!! publish: {rel} on {SITE_BRANCH} is broken or unreadable — NOT publishing; fix the file by hand'); return False
        merged = merge(base, store, theirs)
        _git(repo, 'reset', '-q', '--hard', remote)                             # the worktree = the site right now
        store[:] = merged
        save_local(store)
        if not _git(repo, 'status', '--porcelain', '--', rel, rel_state).stdout.strip(): return True
        _git(repo, 'add', '--', rel, rel_state)
        tree = _git(repo, 'write-tree').stdout.strip()
        lease = _git(repo, 'rev-parse', remote).stdout.strip()
        ident = dict(GIT_AUTHOR_NAME='Domain OS bot', GIT_COMMITTER_NAME='Domain OS bot',
                     GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com',
                     GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com')
        c = subprocess.run(['git', '-C', repo, 'commit-tree', tree, '-m', 'results: community benchmarks (the only commit: no history)'],
                           capture_output=True, text=True, env=dict(os.environ, **ident))
        if c.returncode != 0 or not tree or not lease:
            print('!!! publish: the commit could not be made', c.stderr.strip()[:300]); return False
        sha = c.stdout.strip()
        p = _git(repo, 'push', '-q', f'--force-with-lease=refs/heads/{SITE_BRANCH}:{lease}', 'origin', f'{sha}:refs/heads/{SITE_BRANCH}', auth=True)
        if p.returncode == 0:
            _git(repo, 'reset', '-q', sha)                                        # the new base for the next merge
            try: open(os.path.join(repo, '.published'), 'w').close()             # tells the workflow to publish the site
            except OSError: pass
            print('published'); return True
        print('publish: push refused, merging again', p.stderr.strip()[:300])
        _git(repo, 'reset', '-q', '--hard', remote)                             # back to the base of `merged` …
        save_local(store)                                                         # … with the bot's view on disk
    print('!!! publish failed (will try again)')
    return False


def results_cycle(me, store):
    """One results pass: new posts, removed posts, finished weeks, then the site, then the weekly post."""
    done = 0
    before = json.dumps([store, STATE], sort_keys=True)
    try: done += pass_results(me, store)
    except Exception as e: print('results pass', e)
    try: store[:] = prune(store)
    except Exception as e: print('prune', e)
    try: finish_weeks(store)
    except Exception as e: print('weekly top', e)
    ok = True
    if json.dumps([store, STATE], sort_keys=True) != before:
        save_local(store); ok = publish(store)                                  # the site gets it right away
    if ok and STATE['announce']:                                                  # the weekly post only after the site has the top
        try:
            if announce_weeks(store, me): save_local(store); publish(store)
        except Exception as e: print('weekly post', e)
    return done


def main():
    if '--parse-worker' in sys.argv:
        worker_main(sys.argv[sys.argv.index('--parse-worker') + 1]); return
    if '--publish-only' in sys.argv:                  # the workflow's last step: whatever a dead shift left on disk
        store = load_store()
        if store is None: sys.exit(1)
        load_state()
        sys.exit(0 if publish(store) else 1)
    if not TOKEN: sys.exit('DISCORD_TOKEN is not set')
    me = dc('GET', '/users/@me')['id']
    store = load_store()
    results_ok = store is not None
    load_state()
    watch = int(sys.argv[sys.argv.index('--watch') + 1]) if '--watch' in sys.argv else 0
    end = time.time() + watch
    done = 0; last_results = 0
    while True:
        try: done += pass_help(me)
        except Exception as e: print('help pass', e)
        if time.time() - last_results >= 300:
            if results_ok: done += results_cycle(me, store)
            else: print('!!! results.json is broken: the results forum is NOT handled in this shift')
            last_results = time.time()
        if time.time() + 12 >= end: break
        time.sleep(12)
    if results_ok: publish(store)
    print('handled', done)


if __name__ == '__main__':
    main()
