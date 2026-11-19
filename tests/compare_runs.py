#!/usr/bin/env python3
"""Domain OS: compares groups of DomainSchedTest game runs (for example the Win32PrioritySeparation A/B test).

    python compare_runs.py C:\\PS-Test                      every group found under the folder
    python compare_runs.py C:\\PS-Test --groups ps18,ps26   only these groups (the first one is the reference)

It reads every summary.txt under the folder (DomainSchedTest output folders), groups runs by label without the run
number ("ps18-1", "ps18 2" -> "ps18"), and uses the SAME number of runs per group: the smallest group's count, taking
the first runs of every group by their date. Per group it prints the mean and the min..max of average FPS, 1% low,
0.1% low, frame time p99, hitches and the game threads' ready-wait p99.

A difference is called real only when it is larger than the run-to-run spread: the two groups' min..max ranges do
not overlap AND the difference of the means is larger than the wider of the two ranges (never taken as smaller than
the last printed digit). Everything else is reported
as "no measurable difference" (with 3 runs per group this is strict on purpose: noise must not become a verdict).
Standard library only; Python 3.8+.
"""
import argparse, os, re, sys

# metric key, title, unit, True if higher is better, resolution (the last digit summary.txt prints; a spread is never
# taken as smaller than this, so two groups that only differ by rounding are not called different)
METRICS = [
    ('fps', 'средний FPS', '', True, 0.1),
    ('low1', '1% low', 'FPS', True, 0.1),
    ('low01', '0.1% low', 'FPS', True, 0.1),
    ('ft_p99', 'кадр p99', 'мс', False, 0.01),
    ('hitch', 'рывков', '', False, 1),
    ('gw_p99', 'ожидание потоков игры p99', 'мкс', False, 0.1),
]
MAX_FILE = 2_000_000
NUM = lambda x: float(x.replace(',', '').replace(' ', '').replace('\u00a0', ''))


def parse(text):
    """The numbers this comparison needs from one DomainSchedTest summary.txt (1.4-1.6). None for a non-game run."""
    s = text[:MAX_FILE].replace('\r\n', '\n')
    r = {}
    m = re.search(r'Подпись: ([^\n]+)', s); r['label'] = m.group(1).strip() if m else 'run'
    m = re.search(r'Дата: ([\d\- :]+)', s); r['date'] = m.group(1).strip() if m else ''
    m = re.search(r'Процессор: ([^\n]+)', s); r['cpu'] = m.group(1).strip() if m else ''
    m = re.search(r'Windows: ([^\n]+)', s); r['windows'] = m.group(1).strip() if m else ''
    m = re.search(r'процесс: (\S+) \(', s); r['game'] = m.group(1) if m else ''
    m = re.search(r'замер (\d+) с', s); r['seconds'] = int(m.group(1)) if m else 0
    fr = re.search(r'средний FPS ([\d.,]+)\s+1% low ([\d.,]+)\s+0\.1% low ([\d.,]+)', s)
    if not fr:
        return None
    r['fps'], r['low1'], r['low01'] = (NUM(x) for x in fr.groups())
    m = re.search(r'время кадра: медиана [\d.,]+ мс, p99 ([\d.,]+) мс', s)
    if m: r['ft_p99'] = NUM(m.group(1))
    m = re.search(r'рывков \([^)\n]*\): ([\d,]+)', s)
    if m: r['hitch'] = NUM(m.group(1))
    m = re.search(r'Только потоки [^\n]*\n\s+среднее [\d.,]+\s+p50 [\d.,]+\s+p90 [\d.,]+\s+p99 ([\d.,]+)', s)
    if m: r['gw_p99'] = NUM(m.group(1))
    return r


def group_of(label):
    # ps18-1, ps18 2, ps18_3, ps18#4 -> ps18; a label without a run number is a group of its own
    g = re.sub(r'[\s_\-#]+\(?\d+\)?$', '', label).strip()
    return g or label


def load(folder):
    runs = []
    for root, _dirs, files in os.walk(folder):
        if 'summary.txt' in files:
            p = os.path.join(root, 'summary.txt')
            with open(p, encoding='utf-8-sig', errors='replace') as f:
                r = parse(f.read(MAX_FILE))
            if r is None:
                print(f'  пропущен (не игровой замер): {p}')
                continue
            r['path'] = root
            runs.append(r)
    return runs


def fmt(v):
    return f'{v:.0f}' if abs(v) >= 100 else f'{v:.1f}' if abs(v) >= 10 else f'{v:.2f}'


def stats(vals):
    return sum(vals) / len(vals), min(vals), max(vals)


def compare(a_vals, b_vals, higher_better, resolution):
    """'A', 'B' (the better group) or None when the difference is within the run-to-run spread."""
    ma, lo_a, hi_a = stats(a_vals)
    mb, lo_b, hi_b = stats(b_vals)
    spread = max(hi_a - lo_a, hi_b - lo_b, resolution)
    overlap = not (lo_a > hi_b or lo_b > hi_a)
    if overlap or abs(ma - mb) <= spread:
        return None
    return 'A' if (ma > mb) == higher_better else 'B'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('folder', help='folder with DomainSchedTest-*-game result folders (searched recursively)')
    ap.add_argument('--groups', default='', help='comma-separated groups to compare, e.g. ps18,ps26 (first = reference)')
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(errors='replace')
    except Exception:
        pass
    if not os.path.isdir(args.folder):
        print(f'Нет такой папки: {args.folder}'); return 2
    runs = load(args.folder)
    groups = {}
    for r in sorted(runs, key=lambda r: (r['date'], r['path'])):
        groups.setdefault(group_of(r['label']), []).append(r)
    if args.groups:
        want = [g.strip() for g in args.groups.split(',') if g.strip()]
        missing = [g for g in want if g not in groups]
        if missing:
            print(f'Нет замеров для групп: {", ".join(missing)}. Найдены: {", ".join(groups) or "ничего"}'); return 2
        groups = {g: groups[g] for g in want}
    if not groups:
        print('Не найдено ни одного игрового замера (summary.txt).'); return 2

    n = min(len(v) for v in groups.values())
    print(f'Групп: {len(groups)}; замеров в каждой берётся поровну: {n} (первые по времени)')
    for g, v in groups.items():
        extra = len(v) - n
        print(f'  {g}: найдено {len(v)}' + (f', лишних {extra} не учитываются: ' + ', '.join(x['date'] for x in v[n:]) if extra else ''))
        groups[g] = v[:n]
    used = [r for v in groups.values() for r in v]
    for key, what in (('cpu', 'процессоры'), ('windows', 'сборки Windows'), ('game', 'игры'), ('seconds', 'длительность замера')):
        vals = sorted({str(r[key]) for r in used})
        if len(vals) > 1:
            print(f'  ВНИМАНИЕ: разные {what}: {" | ".join(vals)} — сравнение не один к одному')
    if n < 3:
        print(f'  ВНИМАНИЕ: всего {n} замер(а) на группу — разброс почти не виден, вывод ненадёжен (нужно 3+)')

    names = list(groups)
    w = max(12, max(len(g) for g in names) + 2)
    print()
    print('показатель'.ljust(28) + ''.join(g.rjust(w + 14) for g in names))
    for key, title, unit, _hb, _res in METRICS:
        row = (title + (f', {unit}' if unit else '')).ljust(28)
        for g in names:
            vals = [r[key] for r in groups[g] if key in r]
            if len(vals) < n:
                row += '—'.rjust(w + 14)
                continue
            m, lo, hi = stats(vals)
            row += f'{fmt(m)} ({fmt(lo)}..{fmt(hi)})'.rjust(w + 14)
        print(row)
    print('  в скобках: худший..лучший замер (min..max) — это разброс от замера к замеру')
    print()
    for g in names:
        print(f'  {g}: ' + '; '.join(f'{r["date"][11:]} fps {fmt(r["fps"])} 1% {fmt(r["low1"])} 0.1% {fmt(r["low01"])}' for r in groups[g]))

    if len(names) < 2:
        print('\nОдна группа — сравнивать не с чем.'); return 0
    ref = names[0]
    for other in names[1:]:
        print(f'\nИТОГ {ref} против {other} (разница засчитывается, только если она больше разброса замеров):')
        wins = {ref: [], other: []}
        for key, title, _unit, hb, res in METRICS:
            a = [r[key] for r in groups[ref] if key in r]
            b = [r[key] for r in groups[other] if key in r]
            if len(a) < n or len(b) < n:
                print(f'  {title}: нет данных'); continue
            c = compare(a, b, hb, res)
            ma, mb = sum(a) / n, sum(b) / n
            if c is None:
                print(f'  {title}: нет измеримой разницы ({fmt(ma)} против {fmt(mb)})')
            else:
                best = ref if c == 'A' else other
                pct = f', {abs(ma - mb) / min(ma, mb) * 100:.1f}%' if min(ma, mb) >= 1 and key != 'hitch' else ''
                print(f'  {title}: лучше {best} ({fmt(ma)} против {fmt(mb)}{pct})')
                wins[best].append(title)
        if not wins[ref] and not wins[other]:
            print(f'ВЕРДИКТ: нет измеримой разницы между {ref} и {other}.')
        elif wins[ref] and wins[other]:
            print(f'ВЕРДИКТ: смешанный — {ref} лучше по: {", ".join(wins[ref])}; {other} лучше по: {", ".join(wins[other])}.')
        else:
            best = ref if wins[ref] else other
            print(f'ВЕРДИКТ: {best} лучше по: {", ".join(wins[best])}; по остальным показателям разницы нет.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
