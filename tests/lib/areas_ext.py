"""Areas G, H, J, K, L of tests/run-all.py: Toolbox tests, Discord bot, website + update feeds, DomainSchedTest,
GitHub workflows + status card. Everything offline; tokens are never set; network calls are made to fail."""
import base64, glob, hashlib, html.parser, importlib.util, io, json, os, re, subprocess, sys, tempfile, zipfile
from datetime import datetime, timezone, timedelta

from framework import PASS, FAIL, SKIP, INFO

G, H, J, K, L = ('G Toolbox (cargo test)', 'H Discord bot', 'J Website + update feeds', 'K DomainSchedTest', 'L Workflows + status card')


# =================================================================================================================
# G. Toolbox
# =================================================================================================================
# The native Toolbox (1.17.0+): cargo test of toolbox/core and toolbox/threadmap. 1.17.0 had 344 + 4 core tests and
# 28 thread map tests on Linux; the floor below catches lost tests, raise it when tests are added.
MIN_TOOLBOX_TESTS = 370


def area_G(R, ctx, proc_result):
    if proc_result is None:
        R.add(G, 'Toolbox test suite', SKIP, f'{ctx.toolbox} has no core/Cargo.toml or cargo is missing')
        return
    code, out, _, dur = proc_result
    res = [tuple(map(int, m)) for m in re.findall(r'test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored', out)]
    fails = re.findall(r'^test (\S+) \.\.\. FAILED$', out, re.M)
    if not res:
        R.add(G, 'cargo test (core + threadmap)', FAIL, f'exit {code}, no test summary: {out[-2500:]}')
        return
    passed, failed = sum(r[0] for r in res), sum(r[1] for r in res)
    R.ok(G, f'cargo test: all {passed} tests pass, core + threadmap ({dur:.0f} s)', code == 0 and failed == 0 and not fails,
         '\n'.join(fails[:30]) or out[-2500:])
    R.ok(G, f'the suite has at least {MIN_TOOLBOX_TESTS} tests (none lost)', passed >= MIN_TOOLBOX_TESTS, f'only {passed} tests ran')


# =================================================================================================================
# helpers: import a module from a file with the network switched off
# =================================================================================================================
class NoNetwork(Exception):
    pass


def _import(path, name):
    import urllib.request, socket
    def blocked(*a, **k):
        raise NoNetwork('network is blocked in the tests')
    urllib.request.urlopen = blocked
    socket.create_connection = blocked
    for k in ('DISCORD_TOKEN', 'GH_PUSH_TOKEN', 'GH_TOKEN', 'RESULTS_JSON'):
        os.environ.pop(k, None)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    old = sys.argv
    sys.argv = [path]
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.argv = old
    return mod


# =================================================================================================================
# H. Discord bot (and K: its parse() on real DomainSchedTest summaries)
# =================================================================================================================
def _indep(s):
    """Numbers of a summary.txt read independently of bot.parse (plain line scanning, no shared regex)."""
    s = s.lstrip('﻿').replace('\r\n', '\n')
    num = lambda x: float(x.replace(',', ''))
    r = {}
    lines = s.split('\n')
    for i, l in enumerate(lines):
        if l.startswith('Ожидание готового потока') and i + 1 < len(lines) and 'p50' not in r:
            t = lines[i + 1].split()
            d = dict(zip(t[0::2], t[1::2]))
            r['p50'], r['p99'], r['p999'] = num(d['p50']), num(d['p99']), num(d['p99.9'])
        if 'средний FPS' in l and 'fps' not in r:
            t = l.split()
            r['fps'] = num(t[t.index('FPS') + 1])
            r['low1'] = num(t[t.index('1%') + 2])
            r['low01'] = num(t[t.index('0.1%') + 2])
    return r


def area_H(R, ctx):
    bot_path = ctx.bot
    if not os.path.exists(bot_path):
        R.add(H, 'bot.py', SKIP, f'{bot_path} not found')
        return
    r = subprocess.run([sys.executable, '-m', 'py_compile', bot_path], capture_output=True, text=True)
    R.ok(H, 'bot.py compiles', r.returncode == 0, r.stderr)
    try:
        bot = _import(bot_path, 'dos_bot')
    except Exception as e:
        R.add(H, 'bot.py imports without tokens and network', FAIL, f'{type(e).__name__}: {e}')
        return
    R.add(H, 'bot.py imports without tokens and network', PASS)
    R.ok(H, 'no token is read into the module when none is set', not bot.TOKEN and not bot.PUSH_TOKEN, 'a token is set')

    def cmds():
        yes = ['/help', '!help', '  /install', '/человек', '/human please', '!faq x']
        no = ['', '/', '!', '/ help', '//x', 'help', 'http://x', '/1', '!!', 'hi /help', '/_x']
        bad = [x for x in yes if not bot.is_command(x)] + [f'NOT {x!r}' for x in no if bot.is_command(x)]
        assert not bad, f'is_command wrong for {bad}'
    R.run(H, 'is_command: /word and !word (also Cyrillic) are commands, plain text and "/" alone are not', cmds)

    def merge_cases():
        e = lambda t, v: {'thread': t, 'v': v}
        base = [e('1', 1), e('2', 2), e('3', 3)]
        ours = [e('1', 10), e('3', 3), e('4', 4)]           # bot: edited 1, removed 2, added 4
        theirs = [e('1', 1), e('2', 2), e('3', 30), e('5', 5)]  # hand: edited 3, added 5
        out = {x['thread']: x['v'] for x in bot.merge(base, ours, theirs)}
        assert out == {'1': 10, '3': 30, '4': 4, '5': 5}, f'merge gave {out}'
        # hand deletion stays deleted; both added the same entry: the bot's version once
        out2 = bot.merge([e('1', 1)], [e('1', 1), e('6', 'bot')], [e('6', 'hand')])
        assert [x['thread'] for x in out2].count('6') == 1 and [x for x in out2 if x['thread'] == '6'][0]['v'] == 'bot', out2
        assert all(x['thread'] != '1' for x in out2), 'a hand-deleted entry came back'
        # entries without thread are matched by content
        j = {'label': 'x'}
        assert bot.merge([j], [j], []) == [], 'a hand-deleted entry without thread came back'
        assert bot.merge([], [], [j]) == [j]
        assert bot.merge([], [], []) == []
    R.run(H, 'merge: three-way by entry (bot edits/removals/additions applied, hand edits/additions/deletions kept)', merge_cases)

    def groups():
        for label, g in (('base-1', 'base'), ('base 2', 'base'), ('base_3', 'base'), ('base#4', 'base'), ('S2-1', 'S2'), ('D3', 'D3'), ('7', '7')):
            assert bot.group_of(label) == g, f'group_of({label!r}) = {bot.group_of(label)!r}, expected {g!r}'
    R.run(H, 'group_of: base-1 / base 2 / base_3 / base#4 -> base; a label without separator is its own group', groups)

    def summaries():
        sample = '﻿Domain SchedTest 1.6.0\nПодпись: x\n'.encode('utf-8')
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, 'w') as z:
            z.writestr('run1/summary.txt', sample)
            z.writestr('run2/summary.txt', b'not a summary')
            z.writestr('other.txt', sample)
        got = bot.summaries_from('r.zip', buf.getvalue())
        assert len(got) == 1 and got[0].startswith('Domain SchedTest'), got
        assert bot.summaries_from('a.txt', sample) and not bot.summaries_from('a.txt', b'hello')
        big = io.BytesIO()
        with zipfile.ZipFile(big, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('summary.txt', b'Domain SchedTest' + b' ' * (bot.MAX_FILE + 10))
        try:
            bot.summaries_from('b.zip', big.getvalue())
            raise AssertionError('a summary.txt over MAX_FILE was not refused')
        except bot.Refused:
            pass
        try:
            bot.summaries_from('c.zip', b'PK\x03\x04garbage')
            raise AssertionError('a broken zip was not refused')
        except bot.Refused:
            pass
    R.run(H, 'summaries_from: reads summary.txt from zip/txt, ignores other files, refuses oversized and broken archives', summaries)

    def parse_edge():
        assert bot.parse('') is None and bot.parse('random text') is None
        t = 'x' * 3_000_000 + '\nсредний FPS 1 1% low 1 0.1% low 1'
        import time
        t0 = time.time(); bot.parse(t); assert time.time() - t0 < 2, 'parse is slow on a large input'
    R.run(H, 'parse: no numbers -> None; a 3 MB crafted text is cut and parsed fast', parse_edge)
    _parse_samples(R, H, ctx, bot)


def _parse_samples(R, area, ctx, bot):
    files = []
    for d in ('idle1', 'vbs1', 'fin', 'dm', 'nosvm'):
        files += sorted(glob.glob(os.path.join(ctx.scratch, d, 'x', '*', 'summary.txt')))
    if not files:
        R.add(area, 'parse() on real DomainSchedTest summaries', SKIP, f'no sample summary.txt under {ctx.scratch}/{{idle1,vbs1,fin,dm,nosvm}}/x')
        return
    probs = []
    for f in files:
        s = open(f, encoding='utf-8-sig').read()
        p = bot.parse(s)
        ref = _indep(s)
        name = os.path.relpath(f, ctx.scratch)
        if p is None:
            probs.append(f'{name}: parse() returned None')
            continue
        want_mode = 'game' if 'fps' in ref else 'idle'
        if p.get('mode') != want_mode:
            probs.append(f'{name}: mode {p.get("mode")}, expected {want_mode}')
        for k, v in ref.items():
            if k not in p or abs(p[k] - v) > 1e-9:
                probs.append(f'{name}: {k} = {p.get(k)}, the text says {v}')
        for k in ('label', 'date', 'cpu', 'windows'):
            if not p.get(k):
                probs.append(f'{name}: {k} is empty')
        for k, v in p.items():
            if isinstance(v, float) and (v != v or v < 0):
                probs.append(f'{name}: {k} = {v}')
    R.check(area, f'parse() on {len(files)} real summaries: p50/p99/p99.9 (idle) and FPS/1%/0.1% low (game) match the text', probs)


# =================================================================================================================
# J. Website + update feeds
# =================================================================================================================
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr'}


class _Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors, self.scripts, self.urls, self.csp, self.handlers, self.ids = [], [], [], [], None, [], []
        self._script = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag not in VOID:
            self.stack.append((tag, self.getpos()[0]))
        if tag == 'script':
            self._script = {'src': a.get('src'), 'text': '', 'line': self.getpos()[0], 'type': a.get('type')}
        if tag == 'meta' and (a.get('http-equiv') or '').lower() == 'content-security-policy':
            self.csp = a.get('content')
        for k, v in attrs:
            if k.startswith('on'):
                self.handlers.append((self.getpos()[0], tag, k))
            if k in ('href', 'src') and v is not None:
                self.urls.append((self.getpos()[0], tag, k, v))
            if k == 'id':
                self.ids.append(v)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack and self.stack[-1][0] == tag:
            self.stack.pop()

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack:
            self.errors.append(f'line {self.getpos()[0]}: </{tag}> without an open tag')
            return
        if self.stack[-1][0] != tag:
            # implicit closes HTML allows (p, li, td, tr, option, ...)
            while self.stack and self.stack[-1][0] in ('p', 'li', 'td', 'th', 'tr', 'option', 'dt', 'dd') and self.stack[-1][0] != tag:
                self.stack.pop()
            if not self.stack or self.stack[-1][0] != tag:
                self.errors.append(f'line {self.getpos()[0]}: </{tag}> closes <{self.stack[-1][0] if self.stack else "?"}> (line {self.stack[-1][1] if self.stack else "?"})')
                if any(t == tag for t, _ in self.stack):
                    while self.stack and self.stack[-1][0] != tag:
                        self.stack.pop()
                    self.stack.pop()
                return
        self.stack.pop()
        if tag == 'script' and self._script is not None:
            self.scripts.append(self._script)
            self._script = None

    def handle_data(self, data):
        if self._script is not None:
            self._script['text'] += data


def _node_check(js):
    with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as f:
        f.write(js)
    try:
        r = subprocess.run(['node', '--check', f.name], capture_output=True, text=True, timeout=30)
        return None if r.returncode == 0 else r.stderr.strip()[-600:]
    finally:
        os.unlink(f.name)


def _public_key(ctx):
    src = open(ctx.updater_cs, encoding='utf-8').read()
    # native updater.rs (1.17.0+): pub const PUBLIC_KEY: &'static str = "..."; C# Updater.cs: public const string PublicKey = "..."
    m = (re.search(r"pub const PUBLIC_KEY: &'static str =\s*\"([A-Za-z0-9+/=]+)\"", src)
         or re.search(r'public const string PublicKey\s*=\s*"([A-Za-z0-9+/=]+)"', src))
    assert m, f'the public update key was not found in {os.path.basename(ctx.updater_cs)}'
    return m.group(1)


def _verify(pub_b64, data, sig_b64):
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.exceptions import InvalidSignature
    key = serialization.load_der_public_key(base64.b64decode(pub_b64))
    assert isinstance(key, ec.EllipticCurvePublicKey) and key.curve.name == 'secp256r1', 'the public key is not ECDSA P-256'
    try:
        key.verify(base64.b64decode(sig_b64.strip()), data, ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False


def area_J(R, ctx):
    site = ctx.site
    if not os.path.isdir(site):
        R.add(J, 'website checkout', SKIP, f'{site} not found (gh-pages checkout)')
        return
    # The owner's hub is a password-encrypted page at a private path, not part of the public site: it is skipped and its
    # path is never printed in the (public) CI log.
    _hub = lambda f: '<title>Domain OS Пульт</title>' in open(f, encoding='utf-8', errors='ignore').read(4000)
    pages = sorted(p for p in glob.glob(os.path.join(site, '**', '*.html'), recursive=True) if '/.git/' not in p and not _hub(p))
    R.ok(J, f'website has pages ({len(pages)})', len(pages) >= 4, 'fewer than 4 pages')
    for p in pages:
        relp = os.path.relpath(p, site)
        txt = open(p, encoding='utf-8').read()
        pr = _Page()
        try:
            pr.feed(txt); pr.close()
        except Exception as e:
            R.add(J, f'{relp}: well-formed', FAIL, str(e)); continue
        probs = list(pr.errors) + [f'<{t}> (line {l}) is never closed' for t, l in pr.stack if t not in ('html', 'body', 'head')]
        if not txt.lstrip().lower().startswith('<!doctype html'):
            probs.append('no <!doctype html>')
        dup = sorted({i for i in pr.ids if pr.ids.count(i) > 1})
        if dup:
            probs.append(f'duplicate ids {dup}')
        R.check(J, f'{relp}: well-formed HTML', probs)
        stub = '/downloads/' in '/' + relp.replace('\\', '/')
        probs = []
        inline = [s for s in pr.scripts if not s['src'] and (s['type'] or 'text/javascript') in ('text/javascript', 'module')]
        for s in inline:
            err = _node_check(s['text'])
            if err:
                probs.append(f'line {s["line"]}: {err}')
        for s in pr.scripts:
            if s['src'] and not re.match(r'https?:', s['src']):
                path = os.path.normpath(os.path.join(os.path.dirname(p), s['src'].split('?')[0]))
                if os.path.exists(path):
                    err = _node_check(open(path, encoding='utf-8').read())
                    if err:
                        probs.append(f'{s["src"]}: {err}')
        R.check(J, f'{relp}: every script parses in node', probs)
        probs = []
        if not pr.csp:
            if not stub:
                probs.append('no Content-Security-Policy meta tag')
        else:
            csp = pr.csp
            ss = re.search(r'script-src([^;]*)', csp) or re.search(r'default-src([^;]*)', csp)
            src = ss.group(1) if ss else ''
            if "'unsafe-inline'" in src or "'unsafe-eval'" in src:
                probs.append(f"script-src allows unsafe-inline/eval: {src.strip()}")
            hashes = set(re.findall(r"'sha256-([A-Za-z0-9+/=]+)'", src))
            for s in inline:
                h = base64.b64encode(hashlib.sha256(s['text'].encode('utf-8')).digest()).decode()
                if h not in hashes:
                    probs.append(f'inline script at line {s["line"]} has sha256-{h}, which the CSP does not allow (the browser blocks it)')
            used = {base64.b64encode(hashlib.sha256(s['text'].encode('utf-8')).digest()).decode() for s in inline}
            for h in hashes - used:
                probs.append(f'CSP allows sha256-{h}, which matches no inline script (stale hash)')
            for line, tag, attr in pr.handlers:
                probs.append(f'line {line}: inline handler {attr} on <{tag}> is blocked by the CSP')
            for k in ("object-src 'none'", 'base-uri'):
                if k not in csp:
                    probs.append(f'CSP without {k}')
        R.check(J, f'{relp}: CSP present and its hashes match the inline scripts', probs)
        probs = []
        for line, tag, attr, url in pr.urls:
            u = url.strip()
            if re.match(r'^(https?:|mailto:|data:|#|javascript:)', u, re.I) or u == '':
                if u.lower().startswith('javascript:'):
                    probs.append(f'line {line}: javascript: URL')
                if u.lower().startswith('http:'):
                    probs.append(f'line {line}: plain http link {u}')
                continue
            path = u.split('#')[0].split('?')[0]
            if not path:
                continue
            target = os.path.normpath(os.path.join(site if path.startswith('/') else os.path.dirname(p), path.lstrip('/')))
            if path.startswith('/DomainOS/'):
                target = os.path.normpath(os.path.join(site, path[len('/DomainOS/'):]))
            if os.path.isdir(target):
                target = os.path.join(target, 'index.html')
            if not os.path.exists(target):
                probs.append(f'line {line}: <{tag} {attr}="{u}"> -> {os.path.relpath(target, site)} does not exist')
        R.check(J, f'{relp}: every local href/src resolves to a file', probs)
    # update feeds
    upd = os.path.join(site, 'update')
    if not os.path.isdir(upd):
        R.add(J, 'update feeds', SKIP, 'no update/ folder in the site checkout')
        return
    if not os.path.exists(ctx.updater_cs):
        R.add(J, 'update feeds: signature', SKIP, f'{ctx.updater_cs} not found (public key)')
        return
    try:
        pub = _public_key(ctx)
        import cryptography  # noqa
    except Exception as e:
        R.add(J, 'update feeds: public key / cryptography', FAIL, str(e))
        return
    # stable.json / test.bin: read by the C# Toolbox 1.16.x; stable-native.json / test-native.bin: the native Toolbox 1.17.0+
    for name in ('stable.json', 'test.bin', 'test.json', 'stable-native.json', 'test-native.bin'):
        f = os.path.join(upd, name)
        if not os.path.exists(f):
            continue
        sig = f + '.sig'
        if not os.path.exists(sig):
            R.add(J, f'update/{name}: signed', FAIL, f'{name}.sig is missing: Toolbox refuses the feed')
            continue
        data = open(f, 'rb').read()
        R.ok(J, f'update/{name}: signature verifies with the public key of the Toolbox updater (ECDSA P-256)', _verify(pub, data, open(sig).read()), 'INVALID signature: Toolbox refuses this feed')
        R.ok(J, f'update/{name}: a changed byte breaks the signature (self-test)', not _verify(pub, data + b' ', open(sig).read()), 'the verification accepts modified data')
        R.ok(J, f'update/{name}: at most 1 MB (Updater limit)', len(data) <= 1_000_000, f'{len(data)} bytes')
    for feed_name in ('stable.json', 'stable-native.json'):
        f = os.path.join(upd, feed_name)
        if not os.path.exists(f):
            continue
        def stable(f=f):
            d = json.load(open(f, encoding='utf-8'))
            probs = []
            assert set(d) <= {'toolbox', 'playbook', 'tables'} and d, f'unexpected keys {list(d)}'
            for k, v in d.items():
                if k == 'tables':
                    continue
                if not re.fullmatch(r'\d+\.\d+\.\d+(-test\d+(\.\d+)?)?', str(v.get('version', ''))):
                    probs.append(f'{k}.version "{v.get("version")}" is not a version')
                url = str(v.get('url', ''))
                if not re.fullmatch(r'https://github\.com/6kane1/DomainOS/releases/download/[\w.\-]+/[\w.\-]+', url):
                    probs.append(f'{k}.url "{url}" is not a GitHub release download of 6kane1/DomainOS')
                if v.get('version') and v['version'] not in url:
                    probs.append(f'{k}: the url does not name version {v["version"]}')
                if not re.fullmatch(r'[0-9a-f]{64}', str(v.get('sha256', ''))):
                    probs.append(f'{k}.sha256 is not 64 lower-case hex characters')
                if not (isinstance(v.get('size'), int) and 1_000_000 < v['size'] < 500_000_000):
                    probs.append(f'{k}.size {v.get("size")} is not plausible')
                for n in ('notes_en', 'notes_ru'):
                    if not v.get(n):
                        probs.append(f'{k}.{n} is empty')
                if k == 'toolbox' and not url.endswith('.exe'):
                    probs.append('toolbox url is not an .exe')
                if k == 'playbook' and not url.endswith('.apbx'):
                    probs.append('playbook url is not an .apbx')
            assert not probs, '\n'.join(probs)
        R.run(J, f'update/{feed_name}: versions, https GitHub release URLs, sha256, sizes, notes', stable)
    # Owner's decision 2026-11-27: the C# Toolbox is never offered the native exe (it moves to it only through the
    # playbook): stable.json keeps a C# Toolbox 1.16.x entry once the native feed exists.
    cs, nat = os.path.join(upd, 'stable.json'), os.path.join(upd, 'stable-native.json')
    if os.path.exists(cs) and os.path.exists(nat):
        def separate():
            a, b = json.load(open(cs, encoding='utf-8')), json.load(open(nat, encoding='utf-8'))
            ta, tb = a.get('toolbox') or {}, b.get('toolbox') or {}
            assert str(ta.get('version', '')).startswith('1.16.'), f'stable.json offers Toolbox {ta.get("version")} to C# clients (must stay 1.16.x)'
            assert ta.get('url') != tb.get('url') and ta.get('sha256') != tb.get('sha256'), 'stable.json and stable-native.json offer the same exe'
        R.run(J, 'update/stable.json (C# clients) never offers the native Toolbox of stable-native.json', separate)


# =================================================================================================================
# K. DomainSchedTest
# =================================================================================================================
def area_K(R, ctx, proc_result):
    if proc_result is None:
        R.add(K, 'DomainSchedTest builds', SKIP, f'{ctx.schedtest} not found or dotnet missing')
    else:
        code, out, _, dur = proc_result
        errs = re.findall(r'error [A-Z]+\d+: [^\r\n]+', out)
        R.ok(K, f'DomainSchedTest builds (dotnet build -p:EnableWindowsTargeting=true, {dur:.0f} s)', code == 0, '\n'.join(errs[:20]) or out[-2000:])
        warns = sorted(set(re.findall(r'warning [A-Z]+\d+: [^\r\n\[]+', out)))
        if warns:
            R.add(K, f'DomainSchedTest build warnings ({len(warns)})', INFO, '\n'.join(warns[:10]))
    prog = os.path.join(ctx.schedtest, 'Program.cs')
    if os.path.exists(prog):
        src = open(prog, encoding='utf-8').read()
        flags = sorted(set(re.findall(r'"(--[a-z][\w-]*)"', src)))
        rejects = re.search(r'unknown (option|argument|flag)|неизвестн', src, re.I)
        if not rejects:
            R.add(K, 'argument handling: unknown flags', INFO, f'unknown flags (e.g. --second, a typo of --seconds) are silently ignored; known: {", ".join(flags)}')
        else:
            R.add(K, 'argument handling: unknown flags are rejected', PASS)
        R.ok(K, 'the flags the bot and README rely on exist (--mode, --seconds, --label, --process, --out)',
             all(f in flags for f in ('--mode', '--seconds', '--label', '--process', '--out')), f'flags: {flags}')
    if os.path.exists(ctx.bot):
        try:
            bot = _import(ctx.bot, 'dos_bot_k')
            _parse_samples(R, K, ctx, bot)
        except Exception as e:
            R.add(K, 'bot parse() of the summaries', FAIL, str(e))
        # every metric the bot charts is produced by at least one sample of its mode
        try:
            files = sum((glob.glob(os.path.join(ctx.scratch, d, 'x', '*', 'summary.txt')) for d in ('idle1', 'vbs1', 'fin', 'dm', 'nosvm')), [])
            if files:
                got = {}
                for f in files:
                    p = bot.parse(open(f, encoding='utf-8-sig').read()) or {}
                    for k in p:
                        got.setdefault(p.get('mode'), set()).add(k)
                miss = [f'{key} ({mode})' for key, _, _, _, mode in bot.METRICS for m in (['game', 'idle'] if mode == 'both' else [mode])
                        if m in got and key not in got[m] and key not in ('steal', 'bg', 'tb', 'gw_p99', 'gw_o50', 'dpc', 'hitch')]
                R.check(K, 'the main metrics of each mode are found in the samples (summary format still matches the bot)', miss)
        except Exception as e:
            R.add(K, 'metrics coverage', FAIL, str(e))


# =================================================================================================================
# L. GitHub workflows + status card
# =================================================================================================================
def area_L(R, ctx):
    import yaml
    wf = sorted(glob.glob(os.path.join(ctx.gh, 'workflows', '*.yml')) + glob.glob(os.path.join(ctx.gh, 'workflows', '*.yaml')))
    if not wf:
        R.add(L, 'workflows', SKIP, f'no workflows under {ctx.gh}/workflows')
    for f in wf:
        name = os.path.relpath(f, os.path.dirname(ctx.gh))
        text = open(f, encoding='utf-8').read()
        try:
            d = yaml.load(text, Loader=yaml.BaseLoader)   # BaseLoader: "on" stays a string key
        except Exception as e:
            R.add(L, f'{name}: parses', FAIL, str(e)); continue
        R.ok(L, f'{name}: parses and has jobs', isinstance(d, dict) and 'jobs' in d and 'on' in d, 'no "on" or "jobs"')
        probs = []
        for i, line in enumerate(text.split('\n'), 1):
            m = re.match(r'\s*(-\s*)?uses:\s*([^\s#]+)', line)
            if m:
                u = m.group(2)
                if u.startswith('./') or u.startswith('docker://') and '@sha256:' in u:
                    continue
                if not re.fullmatch(r'[\w.\-]+/[\w.\-/]+@[0-9a-f]{40}', u):
                    probs.append(f'{name}:{i}: {u} is not pinned to a full commit SHA')
        R.check(L, f'{name}: every action is pinned to a full commit SHA', probs)
        probs = []
        jobs = d.get('jobs') or {}
        top = d.get('permissions')
        if top is None and any('permissions' not in (j or {}) for j in jobs.values()):
            probs.append(f'{name}: no top-level permissions and a job without its own (gets the default token rights)')
        for scope, perms in [('top', top)] + [(f'job {k}', (j or {}).get('permissions')) for k, j in jobs.items()]:
            if isinstance(perms, str):
                if perms in ('write-all', 'read-all'):
                    probs.append(f'{name}: {scope} permissions {perms}')
            elif isinstance(perms, dict):
                for k, v in perms.items():
                    if v != 'write':
                        continue
                    # writes the used actions need by their documentation
                    if k in ('pages', 'id-token') and 'actions/deploy-pages@' in text:
                        continue
                    if k in ('attestations', 'id-token') and 'actions/attest-build-provenance@' in text:
                        continue
                    ln = next((l for l in text.split('\n') if re.match(rf'\s*{re.escape(k)}:\s*write', l)), '')
                    if '#' not in ln:
                        probs.append(f'{name}: {scope} {k}: write, not needed by a used action and without a comment saying why')
        R.check(L, f'{name}: permissions minimal (explicit, no write-all, every write explained)', probs)
        probs = []
        for i, line in enumerate(text.split('\n'), 1):
            if re.search(r'\$\{\{\s*secrets\.', line) and not re.match(r'\s*[\w-]+:\s*\$\{\{\s*secrets\.[\w]+\s*\}\}\s*(#.*)?$', line):
                probs.append(f'{name}:{i}: a secret is used inline instead of through env/with: {line.strip()[:100]}')
            if re.search(r'\b(echo|printf|cat)\b.*\$\{?(DISCORD_TOKEN|GH_PUSH_TOKEN|GH_TOKEN|GITHUB_TOKEN|TOKEN)\b', line):
                probs.append(f'{name}:{i}: a token is printed: {line.strip()[:100]}')
            if re.search(r'\$\{\{\s*github\.event\.(issue|comment|pull_request|head_commit|review)', line):
                probs.append(f'{name}:{i}: untrusted event text in a step (script injection)')
            if re.search(r'set -x|ACTIONS_STEP_DEBUG', line):
                probs.append(f'{name}:{i}: shell tracing can print secrets')
        R.check(L, f'{name}: no secret echoed or used inline, no event text injection', probs)
    st = os.path.join(ctx.gh, 'discord-status', 'status.py')
    if not os.path.exists(st):
        R.add(L, 'status.py card()', SKIP, f'{st} not found')
        return
    try:
        import PIL  # noqa
    except ImportError:
        R.add(L, 'status.py card()', SKIP, 'Pillow is not installed')
        return
    try:
        mod = _import(st, 'dos_status')
    except Exception as e:
        R.add(L, 'status.py imports without tokens and network', FAIL, f'{type(e).__name__}: {e}')
        return
    R.add(L, 'status.py imports without tokens and network', PASS)
    from PIL import Image
    now = datetime.now(timezone.utc)
    cases = {
        'all known, bot running now': {'playbook': '2.1.8', 'toolbox': '1.15.0', 'released': now - timedelta(days=3), 'members': 123, 'online': 45, 'site': True, 'bot': 'now'},
        'bot seen 10 min ago, released today': {'playbook': '2.1.8', 'toolbox': '1.15.0', 'released': now, 'members': 1, 'online': 0, 'site': True, 'bot': now - timedelta(minutes=10)},
        'nothing known (all requests failed)': {'playbook': '?', 'toolbox': '?', 'released': None, 'members': None, 'online': None, 'site': False, 'bot': None},
        'bot silent for 5 h': {'playbook': '10.20.30', 'toolbox': '9.99.99', 'released': now - timedelta(days=400), 'members': 99999, 'online': 9999, 'site': False, 'bot': now - timedelta(hours=5)},
    }
    for label, f in cases.items():
        def render(f=f):
            png = mod.card(f)
            assert png[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
            im = Image.open(io.BytesIO(png))
            assert im.size == (1600, 520), f'size {im.size}'
            assert len(png) < 8_000_000, 'card larger than Discord accepts'
            assert len(set(im.convert('L').resize((64, 20)).getdata())) > 3, 'the card is blank'
        R.run(L, f'status.py card() renders offline: {label}', render)

    def no_token():
        try:
            old = sys.argv; sys.argv = ['status.py', '--dry']
            mod.main()
            raise AssertionError('main() ran without DISCORD_TOKEN')
        except SystemExit as e:
            assert 'DISCORD_TOKEN' in str(e.code), e.code
        finally:
            sys.argv = old
    R.run(L, 'status.py main() stops without DISCORD_TOKEN (never posts unauthenticated)', no_token)
