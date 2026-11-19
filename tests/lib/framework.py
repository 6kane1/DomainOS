"""Tiny result collector for tests/run-all.py: every check is one named test with PASS / FAIL / SKIP / INFO.

FAIL and an exception inside a test both count as failures; SKIP says why something could not be tested here;
INFO is a finding the owner should know about that does not block the build.
"""
import os, sys, time, traceback

PASS, FAIL, SKIP, INFO = 'PASS', 'FAIL', 'SKIP', 'INFO'
COLOR = sys.stdout.isatty() and os.environ.get('NO_COLOR') is None
_C = {PASS: '\033[32m', FAIL: '\033[31;1m', SKIP: '\033[33m', INFO: '\033[36m'}


def paint(status, text=None):
    text = status if text is None else text
    return f'{_C[status]}{text}\033[0m' if COLOR else text


class Results:
    def __init__(self, verbose=False):
        self.items = []          # (area, name, status, message)
        self.verbose = verbose
        self.area_time = {}

    def add(self, area, name, status, msg=''):
        self.items.append((area, name, status, msg))
        if status == FAIL or self.verbose or status in (SKIP, INFO):
            line = f'  [{paint(status)}] {area}: {name}'
            if msg:
                pad = '\n        '
                line += pad + pad.join(str(msg).rstrip().split('\n'))
            print(line, flush=True)

    def check(self, area, name, problems, ok_msg=''):
        """problems: list of strings (empty = pass)."""
        problems = [p for p in (problems or []) if p]
        if problems:
            shown = problems[:40]
            more = f'\n... and {len(problems) - 40} more' if len(problems) > 40 else ''
            self.add(area, name, FAIL, '\n'.join(shown) + more)
        else:
            self.add(area, name, PASS, ok_msg)
        return not problems

    def ok(self, area, name, cond, msg):
        return self.check(area, name, [] if cond else [msg])

    def run(self, area, name, fn, *a, **kw):
        """Runs fn; an AssertionError or any exception is a failure with its message."""
        try:
            r = fn(*a, **kw)
            if isinstance(r, list):
                return self.check(area, name, r)
            self.add(area, name, PASS)
            return True
        except AssertionError as e:
            self.add(area, name, FAIL, str(e) or 'assertion failed')
        except Exception as e:  # a crash of the test itself is a failure too
            self.add(area, name, FAIL, f'{type(e).__name__}: {e}\n' + traceback.format_exc(limit=3))
        return False

    def failures(self):
        return [i for i in self.items if i[2] == FAIL]

    def summary(self, total_time):
        areas = {}
        for a, _, s, _ in self.items:
            areas.setdefault(a, {PASS: 0, FAIL: 0, SKIP: 0, INFO: 0})[s] += 1
        print('\n' + '=' * 78)
        print(f'{"area":<34}{"pass":>7}{"fail":>7}{"skip":>7}{"info":>7}{"time":>9}')
        for a in sorted(areas):
            c = areas[a]
            t = self.area_time.get(a[:1], 0)
            print(f'{a:<34}{c[PASS]:>7}{c[FAIL]:>7}{c[SKIP]:>7}{c[INFO]:>7}{t:>8.1f}s')
        tot = {k: sum(c[k] for c in areas.values()) for k in (PASS, FAIL, SKIP, INFO)}
        print('-' * 78)
        print(f'{"TOTAL":<34}{tot[PASS]:>7}{tot[FAIL]:>7}{tot[SKIP]:>7}{tot[INFO]:>7}{total_time:>8.1f}s')
        fails = self.failures()
        if fails:
            print('\nFAILED TESTS:')
            for a, n, _, m in fails:
                first = (m or '').strip().split('\n')[0]
                print(f'  {paint(FAIL, "FAIL")} {a}: {n}\n        {first}')
        infos = [i for i in self.items if i[2] == INFO]
        if infos:
            print('\nFINDINGS (info, not blocking):')
            for a, n, _, m in infos:
                print(f'  {paint(INFO, "INFO")} {a}: {n}: {(m or "").strip().splitlines()[0] if m else ""}')
        print('\nRESULT: ' + (paint(FAIL, 'FAIL') if fails else paint(PASS, 'PASS')) +
              f'  ({tot[PASS]} passed, {tot[FAIL]} failed, {tot[SKIP]} skipped, {tot[INFO]} info, {total_time:.1f} s)')
        return 1 if fails else 0


class Timer:
    def __init__(self, results, key):
        self.r, self.k = results, key

    def __enter__(self):
        self.t = time.time()

    def __exit__(self, *a):
        self.r.area_time[self.k] = self.r.area_time.get(self.k, 0) + time.time() - self.t
