#!/usr/bin/env python3
"""Domain OS - writes playbook/Executables/expected.json, the expected-state manifest Check-DomainOS.ps1 reads.

Run from anywhere: python3 tools/gen-expected.py   (build.sh runs it before packing)

It reads Configuration/main.yml, follows its !task includes in order (that order matters: when two actions set the same
registry value, service or task, the later one wins), and records every native AME action Check-DomainOS.ps1 can
verify, with the YAML file and line:
  registryValue  hive (HKLM / HKCU), path, value name, type, data (normalised), operation (add / delete)
  registryKey    hive, path, operation (add / delete; AME's default is delete)
  service        name, operation (change / stop / start / delete), startup
  scheduledTask  path, operation (disable / enable / delete)
  appx           name pattern, type, operation (remove)
  run            the script a !run starts (not checked itself; Check uses it to name the source of a script's result)
Each carries its conditions: option ('' = always, 'name', or '!name' = only when that option is NOT chosen) and builds.
Which actions are in effect is decided at check time, from the options recorded on the PC
(HKLM\\SOFTWARE\\Domain OS\\Options, written by Tasks/options.yml) and the Windows build.

DWORD / QWORD data are written as decimal strings (Windows PowerShell 5.1's ConvertFrom-Json turns big numbers into
doubles), binary data as upper-case hex, multi-strings as lists.

A comment containing "[check: warn]" on the action's line or in the comment block right above it makes Check report a
difference as WARN instead of FAIL (for a value Windows is known to refuse on some builds).

Build checks (exit code 1, nothing written): a task file that does not parse, an unknown hive or registry type, an
option used in a task file that playbook.conf does not offer, and Tasks/options.yml not recording exactly the options
of playbook.conf. Tasks/options.yml itself is not part of the manifest (it is the record, not a change).
"""
import datetime
import hashlib
import json
import os
import re
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAYBOOK = os.path.join(ROOT, 'playbook')
CONF_DIR = os.path.join(PLAYBOOK, 'Configuration')
OUT = os.path.join(PLAYBOOK, 'Executables', 'expected.json')
OPTIONS_FILE = 'Tasks/options.yml'
OPTIONS_KEY = 'HKLM\\SOFTWARE\\Domain OS\\Options'

errors = []


def err(msg):
    errors.append(msg)


def scalar(node):
    """Plain Python value of a YAML node (scalars stay strings, sequences become lists)."""
    if isinstance(node, yaml.ScalarNode):
        return node.value
    if isinstance(node, yaml.SequenceNode):
        return [scalar(x) for x in node.value]
    if isinstance(node, yaml.MappingNode):
        return {k.value: scalar(v) for k, v in node.value}
    return None


def actions_of(rel):
    """[(kind, fields, line)] of one YAML file, in order. kind = tag without '!' and ':'."""
    path = os.path.join(CONF_DIR, rel.replace('\\', '/'))
    try:
        with open(path, encoding='utf-8') as f:
            text = f.read()
        root = yaml.compose(text)
    except Exception as e:  # noqa: BLE001 - any parse error stops the build
        err(f'{rel}: does not parse: {e}')
        return [], []
    lines = text.splitlines()
    out = []
    if not isinstance(root, yaml.MappingNode):
        err(f'{rel}: not a mapping')
        return [], lines
    for k, v in root.value:
        if k.value != 'actions':
            continue
        for item in v.value:
            kind = (item.tag or '').lstrip('!').rstrip(':')
            if not isinstance(item, yaml.MappingNode):
                err(f'{rel}:{item.start_mark.line + 1}: action {kind} is not a mapping')
                continue
            out.append((kind, scalar(item), item.start_mark.line + 1))
    return out, lines


def check_marker(lines, line):
    """'warn' when the action line or the comment block right above it holds [check: warn]."""
    i = line - 1
    if 0 <= i < len(lines) and '[check: warn]' in lines[i]:
        return 'warn'
    i -= 1
    while i >= 0 and lines[i].strip().startswith('#'):
        if '[check: warn]' in lines[i]:
            return 'warn'
        i -= 1
    return 'fail'


HIVES = {'HKLM': 'HKLM', 'HKEY_LOCAL_MACHINE': 'HKLM', 'HKCU': 'HKCU', 'HKEY_CURRENT_USER': 'HKCU'}
TYPES = {'REG_SZ', 'REG_EXPAND_SZ', 'REG_DWORD', 'REG_QWORD', 'REG_MULTI_SZ', 'REG_BINARY'}


def split_path(where, p):
    p = (p or '').strip().rstrip('\\')
    hive, _, sub = p.partition('\\')
    h = HIVES.get(hive.upper())
    if not h:
        err(f'{where}: hive "{hive}" is not HKLM or HKCU')
        return None, None
    return h, sub


def number(where, data, bits):
    try:
        if isinstance(data, str) and data.strip().lower().startswith('0x'):
            n = int(data.strip(), 16)
        else:
            n = int(str(data).strip())
    except ValueError:
        err(f'{where}: "{data}" is not a number')
        return None
    if n < 0:
        n += 1 << bits      # a negative value is stored as its two's complement
    if not 0 <= n < (1 << bits):
        err(f'{where}: {data} does not fit in {bits} bits')
        return None
    return str(n)


def normalise(where, rtype, data):
    if rtype == 'REG_DWORD':
        return number(where, data, 32)
    if rtype == 'REG_QWORD':
        return number(where, data, 64)
    if rtype == 'REG_MULTI_SZ':
        if data is None:
            return []
        if isinstance(data, list):
            return [str(x) for x in data]
        return str(data).replace('\\0', '\0').split('\0')
    if rtype == 'REG_BINARY':
        if isinstance(data, list):
            return ''.join('%02X' % int(str(x), 0) for x in data)
        h = re.sub(r'0x|[\s,]', '', str(data or ''), flags=re.I).upper()
        if not re.fullmatch(r'([0-9A-F]{2})*', h):
            err(f'{where}: "{data}" is not hex bytes')
            return None
        return h
    return '' if data is None else str(data)


def main():
    conf = open(os.path.join(PLAYBOOK, 'playbook.conf'), encoding='utf-8').read()
    version = re.search(r'<Version>([^<]+)</Version>', conf).group(1)
    # Every option the wizard offers: CheckboxOption and RadioOption names, with the default tick.
    offered = []
    for m in re.finditer(r'<(CheckboxOption|RadioOption)([^>]*)>(.*?)</\1>', conf, re.S):
        name = re.search(r'<Name>([^<]+)</Name>', m.group(3))
        if name:
            offered.append({'name': name.group(1).strip(), 'kind': m.group(1),
                            'default': 'IsChecked="false"' not in m.group(2)})
    names = {o['name'] for o in offered}

    main_actions, _ = actions_of('main.yml')
    order = []
    for kind, f, line in main_actions:
        if kind == 'task':
            order.append(f.get('path', '').replace('\\', '/'))
    if OPTIONS_FILE not in order:
        err(f'main.yml does not include {OPTIONS_FILE}')

    items, hashes = [], {}
    for rel in order:
        full = os.path.join(CONF_DIR, rel)
        if not os.path.isfile(full):
            err(f'main.yml includes {rel}, which is not there')
            continue
        hashes[rel] = hashlib.sha256(open(full, 'rb').read()).hexdigest().upper()
        acts, lines = actions_of(rel)
        if rel == OPTIONS_FILE:
            recorded, deleted_first = set(), False
            for kind, f, line in acts:
                if kind == 'registryKey' and f.get('path') == OPTIONS_KEY and f.get('operation', 'delete') == 'delete':
                    deleted_first = deleted_first or not recorded
                elif kind == 'registryValue' and f.get('path') == OPTIONS_KEY:
                    if f.get('option') != f.get('value') or str(f.get('data')) != '1':
                        err(f'{rel}:{line}: an option value must be named like its option and hold 1')
                    recorded.add(f.get('value'))
                else:
                    err(f'{rel}:{line}: only the Options key belongs here')
            if not deleted_first:
                err(f'{rel}: the Options key must be deleted before the options are written')
            for n in sorted(names - recorded):
                err(f'{rel}: option "{n}" of playbook.conf is not recorded')
            for n in sorted(recorded - names):
                err(f'{rel}: records "{n}", which playbook.conf does not offer')
            continue
        for kind, f, line in acts:
            where = f'{rel}:{line}'
            opt = f.get('option', '') or ''
            if not isinstance(opt, str):
                err(f'{where}: option must be one name')
                opt = ''
            if opt and opt.lstrip('!') not in names:
                err(f'{where}: option "{opt}" is not offered by playbook.conf')
            builds = f.get('builds') or []
            if isinstance(builds, str):
                builds = [builds]
            base = {'kind': kind, 'file': rel, 'line': line, 'option': opt, 'builds': [str(b) for b in builds],
                    'check': check_marker(lines, line)}
            if kind == 'registryValue':
                hive, sub = split_path(where, f.get('path'))
                rtype = (f.get('type') or 'REG_SZ').upper()
                if rtype not in TYPES:
                    err(f'{where}: registry type {rtype} is not handled')
                    continue
                op = (f.get('operation') or 'add').lower()
                if op not in ('add', 'delete'):
                    err(f'{where}: operation {op} is not handled')
                    continue
                if not hive:
                    continue
                base.update(hive=hive, path=hive + '\\' + sub, sub=sub, value=str(f.get('value') or ''),
                            type=rtype, operation=op, data=normalise(where, rtype, f.get('data')) if op == 'add' else None)
            elif kind == 'registryKey':
                hive, sub = split_path(where, f.get('path'))
                if not hive:
                    continue
                op = (f.get('operation') or 'delete').lower()
                if op not in ('add', 'delete'):
                    err(f'{where}: operation {op} is not handled')
                    continue
                base.update(hive=hive, path=hive + '\\' + sub, sub=sub, operation=op)
            elif kind == 'service':
                op = (f.get('operation') or 'change').lower()
                st = f.get('startup')
                base.update(name=str(f.get('name')), operation=op, startup=None if st is None else int(st))
            elif kind == 'scheduledTask':
                base.update(path=str(f.get('path')), operation=(f.get('operation') or 'delete').lower())
            elif kind == 'appx':
                base.update(name=str(f.get('name')), type=str(f.get('type') or 'family'),
                            operation=(f.get('operation') or 'remove').lower())
            elif kind == 'run':
                m = re.search(r'-File\s+"\.\\([^"]+)"\s*(.*)$', f.get('args') or '')
                base.update(exe=str(f.get('exe')), script=m.group(1) if m else '', args=m.group(2).strip() if m else str(f.get('args') or ''))
            elif kind in ('writeStatus', 'task'):
                continue
            else:
                err(f'{where}: action !{kind} is not known to gen-expected.py: add it there (and to Check-DomainOS.ps1)')
                continue
            items.append(base)

    if errors:
        for e in errors:
            print('gen-expected:', e)
        return 1
    manifest = {
        'version': version,
        'generated': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'optionsKey': OPTIONS_KEY,
        'options': offered,
        'taskFiles': hashes,
        'items': items,
    }
    with open(OUT, 'w', encoding='ascii', newline='\r\n') as f:
        json.dump(manifest, f, indent=1, ensure_ascii=True)
        f.write('\n')
    counts = {}
    for i in items:
        counts[i['kind']] = counts.get(i['kind'], 0) + 1
    print('expected.json:', version, ', '.join(f'{v} {k}' for k, v in sorted(counts.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
