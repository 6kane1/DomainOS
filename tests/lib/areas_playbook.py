"""Areas A-F and I of tests/run-all.py: the playbook itself (conf, YAML, Undo consistency, PowerShell, Pester, pages,
built archive)."""
import copy, glob, ntpath, hashlib, json, os, re, shutil, subprocess, sys, tempfile
import xml.etree.ElementTree as ET

import ame
from framework import PASS, FAIL, SKIP, INFO

A, B, C, D, E, F, I = ('A playbook.conf', 'B YAML tasks', 'C Undo consistency', 'D PowerShell static',
                       'E Pester (scripts run)', 'F Guide pages', 'I built .apbx')


def rel(ctx, p):
    return os.path.relpath(p, ctx.repo)


# =================================================================================================================
# A. playbook.conf
# =================================================================================================================
def area_A(R, ctx):
    pb = ctx.pb
    R.check(A, 'playbook.conf is well-formed XML with the expected elements', [] if pb.conf.version else ['no <Version>'])
    for p in ame.check_conf(pb.conf):
        pass
    probs = ame.check_conf(pb.conf)
    groups = {'version / title / name / UniqueId': ('Version', 'Title', 'Name', 'UniqueId'),
              'SupportedBuilds (25H2 + 26H2 only)': ('SupportedBuilds',),
              'feature pages: at most 4 options, description 50-85 characters': ('page', 'option name', 'has no <Text>', 'is used'),
              'UseKernelDriver false (memory integrity stays on)': ('UseKernelDriver',),
              'uac-no-prompt is off by default': ('uac-no-prompt',)}
    used = set()
    for name, keys in groups.items():
        mine = [p for p in probs if any(k in p for k in keys)]
        used.update(mine)
        R.check(A, name, mine)
    R.check(A, 'no other playbook.conf problem', [p for p in probs if p not in used])
    # every option does something
    refs = set()
    for a in pb.actions():
        for r_ in ame.option_refs(a):
            refs.add(r_.lstrip('!'))
    real = {o for a in pb.actions() if not a.file.endswith('options.yml') for r_ in ame.option_refs(a) for o in [r_.lstrip('!')]}
    R.check(A, 'every option of playbook.conf is used by at least one action (outside options.yml)',
            [f'option "{n}" is offered but no action uses it' for n in pb.conf.option_names() if n not in real])
    R.ok(A, 'Description / ProgressText do not promise removed features (no "Ultra", no placebo claims)',
         not re.search(r'\bultra\b|timer resolution|MMCSS', pb.conf.text, re.I), 'playbook.conf mentions Ultra / timer / MMCSS')
    # negative self-tests: the checker finds broken confs
    base = pb.conf.text

    def mutated(fn):
        return ame.check_conf(ame.Conf(fn(base)))
    cases = [
        ('5 options on a page', lambda t: t.replace('</Options>', '<CheckboxOption><Text>x</Text><Name>x1</Name></CheckboxOption>' * 5 + '</Options>', 1), 'options (max 4)'),
        ('short page description', lambda t: re.sub(r'Description="[^"]*"', 'Description="too short"', t, 1), 'description has'),
        ('Title without version', lambda t: re.sub(r'<Title>[^<]*</Title>', '<Title>Domain OS</Title>', t), '<Title>'),
        ('kernel driver on', lambda t: t.replace('<UseKernelDriver>false', '<UseKernelDriver>true'), 'UseKernelDriver'),
        ('24H2 supported', lambda t: t.replace('<string>26200</string>', '<string>26100</string>'), 'SupportedBuilds'),
        ('duplicate option name', lambda t: t.replace('<Name>ui-dark</Name>', '<Name>taskbar-clean</Name>'), 'used 2 times'),
        ('uac-no-prompt on by default', lambda t: re.sub(r'<CheckboxOption IsChecked="false">(\s*<Text>[^<]*</Text>\s*<Name>uac-no-prompt)', r'<CheckboxOption>\1', t), 'uac-no-prompt'),
        ('bad version', lambda t: re.sub(r'<Version>[^<]*</Version>', '<Version>2.1</Version>', t), 'Version'),
    ]
    bad = []
    for name, fn, expect in cases:
        out = mutated(fn)
        if not any(expect in p for p in out):
            bad.append(f'the checker did not report "{name}" (expected a message with "{expect}", got {out[:3]})')
    R.check(A, f'self-test: the conf checker catches {len(cases)} kinds of broken playbook.conf', bad)
    try:
        ET.fromstring(b'<Playbook><Version>1</Version>')
        R.add(A, 'self-test: malformed XML is refused', FAIL, 'ElementTree accepted broken XML')
    except ET.ParseError:
        R.add(A, 'self-test: malformed XML is refused', PASS)
    # expected.json and options.yml of the final check (another work package): consistent with the conf when present
    exp = os.path.join(pb.exe, 'expected.json')
    if os.path.exists(exp):
        try:
            e = json.load(open(exp, encoding='utf-8-sig'))
            probs = []
            if e.get('version') != pb.conf.version:
                probs.append(f'Executables/expected.json: version {e.get("version")} but playbook.conf is {pb.conf.version} (run tools/gen-expected.py)')
            eo = {o['name']: o.get('default') for o in e.get('options', [])}
            co = {o['name']: o['checked'] for o in pb.conf.options()}
            if set(eo) != set(co):
                probs.append(f'expected.json options differ from playbook.conf: only in expected {sorted(set(eo) - set(co))}, only in conf {sorted(set(co) - set(eo))}')
            for n in set(eo) & set(co):
                if eo[n] is not None and bool(eo[n]) != co[n]:
                    probs.append(f'expected.json: option {n} default {eo[n]} but playbook.conf IsChecked={co[n]}')
            R.check(A, 'expected.json matches playbook.conf (version, options, defaults)', probs)
        except Exception as ex:
            R.add(A, 'expected.json matches playbook.conf (version, options, defaults)', FAIL, f'expected.json does not parse: {ex}')
        gen = os.path.join(ctx.repo, 'tools', 'gen-expected.py')
        if os.path.exists(gen):
            R.run(A, 'expected.json is current: tools/gen-expected.py on a copy produces the same manifest', _gen_expected_current, ctx, gen, exp)
    else:
        R.add(A, 'expected.json matches playbook.conf', SKIP, 'Executables/expected.json is not there (final check not added yet)')
    ymlopt = [k for k in pb.docs if k.replace('\\', '/').endswith('Tasks/options.yml')]
    if ymlopt:
        acts = [a for a in pb.actions() if a.file == ymlopt[0]]
        probs = []
        vals = [a for a in acts if a.tag == '!registryValue']
        names = [str(a.get('value')) for a in vals]
        for n in pb.conf.option_names():
            if names.count(n) != 1:
                probs.append(f'{ymlopt[0]}: option {n} recorded {names.count(n)} times (expected once)')
        for a in vals:
            if str(a.get('option')) != str(a.get('value')):
                probs.append(f'{a.where()}: records "{a.get("value")}" but is gated by option {a.get("option")!r}')
            if not str(a.get('path', '')).startswith('HKLM\\SOFTWARE\\Domain OS\\'):
                probs.append(f'{a.where()}: options are recorded outside HKLM\\SOFTWARE\\Domain OS')
        for a in acts:
            if a.tag not in ('!registryValue', '!registryKey'):
                probs.append(f'{a.where()}: options.yml must only record options, has {a.tag}')
        R.check(A, 'Tasks/options.yml records every option of playbook.conf exactly once, under HKLM\\SOFTWARE\\Domain OS', probs)
    else:
        R.add(A, 'Tasks/options.yml records every option', SKIP, 'Configuration/Tasks/options.yml is not there')


def _gen_expected_current(ctx, gen, exp):
    with tempfile.TemporaryDirectory() as t:
        os.makedirs(os.path.join(t, 'tools'))
        shutil.copy(gen, os.path.join(t, 'tools'))
        shutil.copytree(ctx.pb.root, os.path.join(t, 'playbook'), ignore=shutil.ignore_patterns('DomainScheduler.exe', 'Wallpaper'))
        r = subprocess.run([sys.executable, os.path.join(t, 'tools', 'gen-expected.py')], capture_output=True, text=True, timeout=120)
        assert r.returncode == 0, f'gen-expected.py failed (exit {r.returncode}): {(r.stdout + r.stderr)[-800:]}'
        new = json.load(open(os.path.join(t, 'playbook', 'Executables', 'expected.json'), encoding='utf-8-sig'))
        old = json.load(open(exp, encoding='utf-8-sig'))
        for d in (new, old):
            for k in ('generated', 'sha256', 'source', 'hash'):
                d.pop(k, None)
        assert new == old, 'Executables/expected.json is out of date: run python3 tools/gen-expected.py (it differs from what the task files give)'


# =================================================================================================================
# B. YAML task files
# =================================================================================================================
def area_B(R, ctx):
    pb = ctx.pb
    R.check(B, 'every YAML file parses (AME tags, no duplicate keys)', pb.errors)
    names = set(pb.conf.option_names())
    builds = set(pb.conf.builds)
    main = pb.docs.get(os.path.join('Configuration', 'main.yml'))
    probs = []
    if not isinstance(main, dict):
        probs.append('Configuration/main.yml is missing or not a mapping')
    else:
        for k in ('title', 'description', 'actions'):
            if k not in main:
                probs.append(f'main.yml has no "{k}"')
        if str(main.get('privilege', '')).lower() not in ('trustedinstaller', ''):
            probs.append(f'main.yml privilege "{main.get("privilege")}"')
    for relp, d in pb.docs.items():
        if not isinstance(d, dict) or not isinstance(d.get('actions'), list):
            probs.append(f'{relp}: no "actions" list')
            continue
        for k in d:
            if k not in ('title', 'description', 'actions', 'privilege', 'features'):
                probs.append(f'{relp}: unknown top-level key "{k}"')
        for a in d['actions']:
            if not isinstance(a, ame.Action):
                probs.append(f'{relp}: an action without an AME tag: {str(a)[:80]}')
    R.check(B, 'every file has title/description/actions and every action is tagged', probs)
    acts = pb.actions()
    groups = {}
    for a in acts:
        for p in ame.check_action(a, names, builds):
            groups.setdefault(a.tag, []).append(p)
    for tag in sorted({a.tag for a in acts} | set(groups)):
        n = sum(1 for a in acts if a.tag == tag)
        R.check(B, f'{tag}: schema, required fields and values ({n} actions)', groups.get(tag, []))
    R.check(B, 'every option: / options: refers to an option of playbook.conf',
            [p for g in groups.values() for p in g if 'option' in p and 'not an option' in p] or [])
    # !task includes
    probs, reached = [], set()

    def walk(relp, depth=0):
        d = pb.docs.get(relp)
        if not isinstance(d, dict) or depth > 5:
            return
        for a in d.get('actions') or []:
            if getattr(a, 'tag', '') == '!task':
                tp = pb.task_path(a)
                r_ = os.path.relpath(tp, pb.root)
                if not os.path.isfile(tp):
                    probs.append(f'{a.where()}: !task path {a.get("path")} does not exist')
                elif '/' in str(a.get('path')):
                    probs.append(f'{a.where()}: !task path uses "/" (AME paths use backslashes)')
                else:
                    if r_ in reached:
                        probs.append(f'{a.where()}: {r_} is included twice')
                    reached.add(r_)
                    walk(r_, depth + 1)
    walk(os.path.join('Configuration', 'main.yml'))
    R.check(B, 'every !task path exists and is included once', probs)
    R.check(B, 'every task file is reached from main.yml (no forgotten file that Save-State still reads)',
            [f'{r_} is not included by main.yml' for r_ in pb.docs if r_ != os.path.join('Configuration', 'main.yml') and r_ not in reached])
    # !run actions
    probs, argprobs = [], []
    for a in acts:
        if a.tag != '!run':
            continue
        inv = ame.ps_invocation(a)
        exe = str(a.get('exe', ''))
        if 'powershell' in exe.lower():
            if exe != ame.PS_EXE:
                probs.append(f'{a.where()}: PowerShell must be started by its full path {ame.PS_EXE}, not "{exe}"')
            args = str(a.get('args', ''))
            for flag in ('-NoProfile', '-NonInteractive', '-ExecutionPolicy Bypass'):
                if flag not in args:
                    probs.append(f'{a.where()}: powershell.exe without {flag}')
            if not inv:
                probs.append(f'{a.where()}: powershell.exe without -File "<script>"')
                continue
            script, params, _ = inv
            if script.startswith('.\\'):
                if a.get('exeDir') is not True:
                    probs.append(f'{a.where()}: relative script {script} needs exeDir: true')
                path = os.path.join(pb.exe, script[2:].replace('\\', '/'))
                if not os.path.isfile(path):
                    probs.append(f'{a.where()}: {script} is not in Executables')
                    continue
                info = ctx.static.get(path)
                if info is None:
                    argprobs.append(f'{a.where()}: no static info for {script}')
                    continue
                declared = {p['name'].lower(): p for p in info['params']}
                for pn, pv in params:
                    d = declared.get(pn.lower())
                    if not d:
                        argprobs.append(f'{a.where()}: {script} has no parameter -{pn} (declared: {sorted(declared) or "none"})')
                    elif d['type'].lower() in ('switch', 'switchparameter') and pv is not None:
                        argprobs.append(f'{a.where()}: -{pn} is a switch but gets the value "{pv}"')
                    elif d['type'].lower() not in ('switch', 'switchparameter') and pv is None:
                        argprobs.append(f'{a.where()}: -{pn} needs a value')
                    elif d['set'] and pv is not None and pv.lower() not in [x.lower() for x in d['set']]:
                        argprobs.append(f'{a.where()}: -{pn} {pv} is not one of {d["set"]}')
                given = {p.lower() for p, _ in params}
                for p in info['params']:
                    if p['mandatory'] and p['name'].lower() not in given:
                        argprobs.append(f'{a.where()}: {script} needs -{p["name"]} (mandatory) and does not get it')
                if params and not info['hasParamBlock']:
                    argprobs.append(f'{a.where()}: {script} gets parameters but has no param() block')
            else:
                probs.append(f'{a.where()}: script path {script} should be .\\<file> inside Executables')
        elif a.get('exeDir') and not re.search(r'[\\%]', exe) and os.path.exists(os.path.join(pb.exe, exe)):
            probs.append(f'{a.where()}: "{exe}" with exeDir also exists in Executables (would shadow the Windows program)')
    R.check(B, '!run: every script exists, full powershell.exe path, safe flags, exeDir', probs)
    R.check(B, '!run: arguments match the script\'s param() block (names, switches, ValidateSet, mandatory)', argprobs)
    # Halt on steps before any change
    order = []
    for a in (main or {}).get('actions', []):
        order.append(a)
    probs = []
    firsts = [a for a in order if a.tag == '!run'][:3]
    for a in firsts:
        h = {str(k): str(v).lower() for k, v in (a.get('handleExitCodes') or {}).items()}
        if not (str(a.get('errorAction', '')).lower() == 'halt' or 'halt' in h.values()):
            probs.append(f'{a.where()}: {ame.ps_invocation(a)[0] if ame.ps_invocation(a) else a.get("exe")} runs before any change and must halt the install when it fails')
    names_first = [ame.ps_invocation(a)[0] for a in firsts if ame.ps_invocation(a)]
    if names_first[:2] != ['.\\Test-Edition.ps1', '.\\Save-State.ps1']:
        probs.append(f'main.yml: the first scripts must be Test-Edition then Save-State, are {names_first}')
    idx_task = next((i for i, a in enumerate(order) if a.tag == '!task'), len(order))
    if not any(ame.ps_invocation(a) and 'Install-DomainOS.ps1' in ame.ps_invocation(a)[0] and '-Part Tools' in str(a.get('args')) for a in order[:idx_task]):
        probs.append('main.yml: Install-DomainOS.ps1 -Part Tools (the Undo tools) must run before the first task file')
    R.check(B, 'main.yml: edition check, state save and Undo tools run first and halt on failure', probs)
    R.check(B, 'no contradicting or duplicated actions for the same target under overlapping conditions', ame.check_contradictions(acts))
    R.check(B, 'owner rules: Defender, SmartScreen, VBS/HVCI, TPM, Secure Boot untouched; SysMain on; Game Mode on; '
               'Win32PrioritySeparation 0x18; UAC no-prompt only behind uac-no-prompt', ame.check_forbidden(acts, pb.conf))
    _B_selftests(R, ctx, acts, names, builds)


def _B_selftests(R, ctx, acts, names, builds):
    """The validators must catch broken actions: each case is a YAML snippet and the text its report must contain."""
    cases = [
        ("!service: {name: 'X', operation: change, startup: 7}", 'startup 0-4'),
        ("!service: {name: 'X', startup: 4}", 'without operation'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\X', value: 'V', data: '1', type: REG_DWROD}", 'not one of'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\X', value: 'V', data: 'abc', type: REG_DWORD}", 'not a number'),
        ("!registryValue: {path: 'HKEY_LOCAL_MACHINE\\SOFTWARE\\X', value: 'V', data: '1', type: REG_DWORD}", 'must start with HKLM'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\X', value: 'V', data: '1'}", 'without type'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\X', value: 'V', data: '1', type: REG_DWORD, option: 'no-such-option'}", 'not an option'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\X', value: 'V', data: '1', type: REG_DWORD, option: '!no-such'}", 'not an option'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\X', value: 'V', data: '1', type: REG_DWORD, builds: ['26100']}", 'not a supported build'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\X', value: 'V', data: '1', type: REG_DWORD, errorAction: Retry}", 'errorAction'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\X', valeu: 'V', data: '1', type: REG_DWORD}", 'unknown field'),
        ("!run: {exe: 'x.exe', handleExitCodes: {'abc': Halt}}", 'not an exit-code expression'),
        ("!run: {exe: 'x.exe', handleExitCodes: {'!0': explode}}", 'handleExitCodes value'),
        ("!run: {exe: 'x.exe', runas: admin}", 'runas'),
        ("!run: {exe: 'x.exe', wait: 'yes'}", 'true/false'),
        ("!scheduledTask: {path: 'Microsoft\\Windows\\X'}", 'backslash'),
        ("!appx: {name: 'X', type: everything}", 'not one of'),
        ("!foo: {name: 'X'}", 'unknown action type'),
    ]
    bad = []
    for snippet, expect in cases:
        a = ame.load_yaml_text('actions:\n  - ' + snippet + '\n', '<selftest>')['actions'][0]
        out = ame.check_action(a, names, builds)
        if not any(expect in p for p in out):
            bad.append(f'not caught: {snippet}  (expected "{expect}", got {out})')
    R.check(B, f'self-test: the schema checker catches {len(cases)} kinds of broken actions', bad)
    forb = [
        ("!service: {name: 'SysMain', operation: change, startup: 4}", 'SysMain'),
        ("!service: {name: 'WinDefend', operation: change, startup: 4}", 'WinDefend'),
        ("!service: {name: 'DiagTrack', operation: delete}", 'deleting service'),
        ("!registryValue: {path: 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\PriorityControl', value: 'Win32PrioritySeparation', data: '38', type: REG_DWORD}", 'Win32PrioritySeparation'),
        ("!registryValue: {path: 'HKCU\\Software\\Microsoft\\GameBar', value: 'AutoGameModeEnabled', data: '0', type: REG_DWORD}", 'Game Mode'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System', value: 'ConsentPromptBehaviorAdmin', data: '0', type: REG_DWORD}", 'uac-no-prompt'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System', value: 'EnableLUA', data: '0', type: REG_DWORD}", 'EnableLUA'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows Defender', value: 'DisableAntiSpyware', data: '1', type: REG_DWORD}", 'Defender'),
        ("!registryValue: {path: 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\DeviceGuard', value: 'EnableVirtualizationBasedSecurity', data: '0', type: REG_DWORD}", 'VBS'),
        ("!registryValue: {path: 'HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\System', value: 'EnableSmartScreen', data: '0', type: REG_DWORD}", 'SmartScreen'),
        ("!registryValue: {path: 'HKLM\\SYSTEM\\CurrentControlSet\\Control\\SecureBoot\\State', value: 'X', data: '0', type: REG_DWORD}", 'Secure Boot'),
        ("!scheduledTask: {path: '\\Microsoft\\Windows\\TPM\\Tpm-Maintenance', operation: disable}", 'TPM'),
        ("!scheduledTask: {path: '\\Microsoft\\Windows\\X\\Y', operation: delete}", 'deleting task'),
        ("!appx: {name: 'Microsoft.XboxIdentityProvider*'}", 'Xbox'),
        ("!run: {exe: 'powershell.exe', args: '-Command Set-MpPreference -DisableRealtimeMonitoring $true'}", 'Defender'),
        ("!run: {exe: '%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', args: '-File \".\\Set-Hypervisor.ps1\"'}", '-Restore'),
    ]
    bad = []
    for snippet, expect in forb:
        a = ame.load_yaml_text('actions:\n  - ' + snippet + '\n', '<selftest>')['actions'][0]
        good = [x for x in acts if x.tag == '!registryValue' and str(x.get('value')).lower() in ('win32priorityseparation', 'autogamemodeenabled', 'allowautogamemode')]
        out = ame.check_forbidden(good + [a], ctx.pb.conf)
        if not any(expect in p for p in out):
            bad.append(f'not caught: {snippet} (expected "{expect}", got {out})')
    R.check(B, f'self-test: the safety rules catch {len(forb)} forbidden changes', bad)
    contra = [
        ("!service: {name: 'X', operation: change, startup: 4}\n  - !service: {name: 'X', operation: change, startup: 2}", 'contradicts'),
        ("!registryValue: {path: 'HKCU\\X', value: 'V', data: '0', type: REG_DWORD, option: 'ui-dark'}\n  - !registryValue: {path: 'HKCU\\X', value: 'V', data: '1', type: REG_DWORD}", 'contradicts'),
        ("!scheduledTask: {path: '\\A\\B', operation: disable}\n  - !scheduledTask: {path: '\\A\\B', operation: enable}", 'contradicts'),
        ("!registryValue: {path: 'HKCU\\X', value: 'V', data: '0', type: REG_DWORD}\n  - !registryValue: {path: 'HKCU\\X', value: 'V', data: '0', type: REG_DWORD}", 'duplicate'),
    ]
    ok_pairs = [
        "!registryValue: {path: 'HKCU\\X', value: 'V', data: '0', type: REG_DWORD, option: 'ui-dark'}\n  - !registryValue: {path: 'HKCU\\X', value: 'V', data: '1', type: REG_DWORD, option: '!ui-dark'}",
        "!registryValue: {path: 'HKCU\\X', value: 'V', data: 'a', type: REG_SZ, builds: ['26200']}\n  - !registryValue: {path: 'HKCU\\X', value: 'V', data: 'b', type: REG_SZ, builds: ['26300']}",
        "!service: {name: 'X', operation: stop}\n  - !service: {name: 'X', operation: change, startup: 4}",
    ]
    bad = []
    for snippet, expect in contra:
        out = ame.check_contradictions(ame.load_yaml_text('actions:\n  - ' + snippet + '\n')['actions'])
        if not any(expect in p for p in out):
            bad.append(f'not caught: {snippet!r}')
    for snippet in ok_pairs:
        out = ame.check_contradictions(ame.load_yaml_text('actions:\n  - ' + snippet + '\n')['actions'])
        if out:
            bad.append(f'false alarm on exclusive conditions: {out}')
    R.check(B, 'self-test: contradiction check (4 conflicts caught, 3 exclusive pairs accepted)', bad)


# =================================================================================================================
# C. Undo consistency
# =================================================================================================================
# registryKey actions that Undo does not restore through the saved state, and why (a new one fails until listed here)
KNOWN_KEY_ACTIONS = [
    (r'^HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\Deprovisioned\\(.+)$', 'deprovisioned', 'Undo deletes it ($ours list in Undo-DomainOS.ps1)'),
    (r'^HKLM\\SOFTWARE\\Microsoft\\WindowsUpdate\\Orchestrator\\UScheduler_Oobe\\(DevHomeUpdate|CrossDeviceUpdate|OutlookUpdate)$', 'oobe', 'documented as not restored (Windows writes it again)'),
    (r'^HKLM\\SOFTWARE\\Domain OS\\Options$', 'own', 'Domain OS\'s own record of the chosen options'),
]
# registry values not captured by Save-State on purpose, each with its own handling
KNOWN_UNCAPTURED_VALUES = {
    ('HKCU\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32', ''):
        ('classicMenu', 'the classic right-click menu: Save-State records classicMenu, Undo removes the key'),
}
# what each !run script changes and where Undo puts it back
RUN_UNDO = {
    'Test-Edition.ps1': None, 'Save-State.ps1': None, 'Install-DomainOS.ps1': 'RemoveTools', 'Restore-Defaults.ps1': None,
    'Set-Hypervisor.ps1': 'Set-Hypervisor.ps1', 'Set-TrkWks.ps1': None, 'Install-Runtimes.ps1': None,
    'Remove-OneDrive.ps1': 'OneDrive', 'Set-Wallpapers.ps1': 'Set-Wallpapers.ps1', 'Set-PowerPlan.ps1': 'Set-PowerPlan.ps1',
    'Remove-AppLeftovers.ps1': 'AppLeftovers', 'Set-StartPins.ps1': 'Set-StartPins.ps1', 'Set-Taskbar.ps1': 'Taskbar',
    'Check-DomainOS.ps1': None, 'powercfg.exe /hibernate off': 'hibernate',
}


def area_C(R, ctx):
    pb = ctx.pb
    r = subprocess.run([ctx.pwsh, '-NoProfile', '-NonInteractive', '-File', os.path.join(ctx.tests, 'ps', 'Items.ps1'), pb.exe,
                        os.path.join(pb.cfg, 'Tasks')], capture_output=True, text=True, timeout=120, env=ctx.env)
    if r.returncode != 0:
        R.add(C, 'Get-DomainOSPlaybookItems / New-DomainOSAllowListLines run on the real task files', FAIL, (r.stdout + r.stderr)[-1500:])
        return
    R.add(C, 'Get-DomainOSPlaybookItems / New-DomainOSAllowListLines run on the real task files', PASS)
    d = json.loads(r.stdout)
    items = d['items'] or []
    allow = set(d['allow'] or [])
    tasks_dir_actions = [a for a in pb.actions() if a.file.replace('\\', '/').startswith('Configuration/Tasks/')]
    own = re.compile(r'^HKLM\\SOFTWARE\\Domain OS(\\|$)', re.I)
    have = {(i['kind'], i['path'], i['name']) for i in items}
    probs, own_captured = [], []
    for a in tasks_dir_actions:
        if a.tag == '!registryValue':
            key = ('R', str(a.get('path')), str(a.get('value')))
            if own.match(key[1]):
                if key in have:
                    own_captured.append(f'{a.where()}: Domain OS\'s own key {key[1]} is recorded by Save-State and allowed for Undo')
                continue
            if (key[1], key[2]) in KNOWN_UNCAPTURED_VALUES:
                continue
            if key not in have:
                probs.append(f'{a.where()}: {key[1]}\\{key[2]} is changed but Save-State does not record it (Get-DomainOSPlaybookItems misses the line)')
            elif f'R|{key[1]}|{key[2]}' not in allow:
                probs.append(f'{a.where()}: {key[1]}\\{key[2]} is recorded but not in the Undo allow-list')
        elif a.tag == '!service':
            if ('S', '', str(a.get('name'))) not in have or f'S|{a.get("name")}' not in allow:
                probs.append(f'{a.where()}: service {a.get("name")} is not recorded / allowed for Undo')
        elif a.tag == '!scheduledTask':
            if ('T', str(a.get('path')), '') not in have or f'T|{a.get("path")}' not in allow:
                probs.append(f'{a.where()}: task {a.get("path")} is not recorded / allowed for Undo')
    R.check(C, 'every registry value, service and task of the task files is recorded by Save-State and allowed for Undo', probs)
    R.check(C, 'Domain OS\'s own option record (HKLM\\SOFTWARE\\Domain OS) is not part of the saved Windows state', own_captured)
    # nothing extra: every item read by the regex is a real action (catches a regex matching commented or foreign text)
    real = set()
    for a in tasks_dir_actions:
        if a.tag == '!registryValue':
            real.add(('R', str(a.get('path')), str(a.get('value'))))
        elif a.tag == '!service':
            real.add(('S', '', str(a.get('name'))))
        elif a.tag == '!scheduledTask':
            real.add(('T', str(a.get('path')), ''))
    R.check(C, 'Save-State reads nothing that is not an action of the task files',
            [f'{k} is read by Get-DomainOSPlaybookItems but is not an action' for k in have - real])
    # special cases are really handled
    ss = open(os.path.join(pb.exe, 'Save-State.ps1'), encoding='utf-8-sig').read()
    un = open(os.path.join(pb.exe, 'Undo-DomainOS.ps1'), encoding='utf-8-sig').read()
    probs = []
    for (path, val), (marker, why) in KNOWN_UNCAPTURED_VALUES.items():
        if marker not in ss or marker not in un or '86ca1aa0-34aa-4e8b-a509-50c905bae2a2' not in un:
            probs.append(f'{path}\\{val}: expected handling "{marker}" ({why}) is missing in Save-State/Undo')
    R.check(C, 'values Save-State cannot read by name (default value of the classic-menu key) have their own handling', probs)
    # registryKey actions
    m = re.search(r'\$ours\s*=\s*@\(([^)]*)\)', un)
    ours = set(re.findall(r"'([^']+)'", m.group(1))) if m else set()
    probs = []
    for a in tasks_dir_actions:
        if a.tag != '!registryKey':
            continue
        p = str(a.get('path'))
        hit = None
        for rx, kind, why in KNOWN_KEY_ACTIONS:
            mm = re.match(rx, p, re.I)
            if mm:
                hit = (kind, mm)
                break
        if not hit:
            probs.append(f'{a.where()}: registryKey {p} ({a.get("operation", "delete (default)")}) is neither restored by Undo nor listed as known in tests/lib/areas_playbook.py')
        elif hit[0] == 'deprovisioned' and hit[1].group(1) not in ours:
            probs.append(f'{a.where()}: Deprovisioned\\{hit[1].group(1)} is added but Undo-DomainOS.ps1 does not delete it ($ours)')
    deprov_added = {re.match(KNOWN_KEY_ACTIONS[0][0], str(a.get('path'))).group(1) for a in tasks_dir_actions
                    if a.tag == '!registryKey' and re.match(KNOWN_KEY_ACTIONS[0][0], str(a.get('path')))}
    for o in sorted(ours - deprov_added):
        probs.append(f'Undo-DomainOS.ps1 $ours lists {o}, which no task file touches (stale)')
    if not ours:
        probs.append('Undo-DomainOS.ps1: the $ours list of Deprovisioned keys was not found')
    R.check(C, 'registryKey actions: Deprovisioned keys match Undo\'s $ours list, others are known and documented', probs)
    # !run scripts: each has a known undo story
    probs = []
    for a in pb.actions():
        if a.tag != '!run':
            continue
        inv = ame.ps_invocation(a)
        name = ntpath.basename(inv[0]) if inv else f'{a.get("exe")} {a.get("args", "")}'.strip()
        if name not in RUN_UNDO:
            probs.append(f'{a.where()}: {name} changes the system but has no entry in RUN_UNDO (tests/lib/areas_playbook.py): how does Undo put it back?')
        elif RUN_UNDO[name] and RUN_UNDO[name] not in un:
            probs.append(f'{a.where()}: {name}: Undo-DomainOS.ps1 does not contain "{RUN_UNDO[name]}"')
    R.check(C, 'every script step has a matching part in Undo-DomainOS.ps1 (or is documented as not needing one)', probs)
    # legacy lists
    ls, lt, lr = d['legacyServices'] or [], d['legacyTasks'] or [], d['legacyRegistry'] or []
    probs = []
    for name, lst in (('services', ls), ('tasks', lt)):
        if len(set(x.lower() for x in lst)) != len(lst):
            probs.append(f'legacy {name} list has duplicates')
    for s in ls:
        if not re.fullmatch(r'[\w.\-]+', s):
            probs.append(f'legacy service "{s}" is not a plain name')
        if s.lower() in ame.FORBIDDEN_SERVICES or s.lower() == 'sysmain':
            probs.append(f'legacy service {s} is protected')
    for t in lt:
        if not t.startswith('\\Microsoft\\Windows\\'):
            probs.append(f'legacy task "{t}" is not under \\Microsoft\\Windows\\')
    for x in lr:
        if len(x) != 2 or not re.match(r'(HKLM|HKCU)\\', x[0]) or not x[1]:
            probs.append(f'legacy registry entry {x} is malformed')
    cur_s = {str(a.get('name')).lower() for a in tasks_dir_actions if a.tag == '!service'}
    cur_t = {str(a.get('path')).lower() for a in tasks_dir_actions if a.tag == '!scheduledTask'}
    cur_r = {(str(a.get('path')).lower(), str(a.get('value')).lower()) for a in tasks_dir_actions if a.tag == '!registryValue'}
    for s in ls:
        if s.lower() in cur_s:
            probs.append(f'legacy service {s} is also changed by the current task files: Restore-Defaults.ps1 would undo it on every install')
    for t in lt:
        if t.lower() in cur_t:
            probs.append(f'legacy task {t} is also changed by the current task files')
    for x in lr:
        if (x[0].lower(), x[1].lower()) in cur_r:
            probs.append(f'legacy value {x} is also changed by the current task files')
    R.check(C, 'legacy lists are sane: no duplicates, plain names, protected items absent, no overlap with current actions', probs)
    n_cur = len([x for x in allow if x.split('|')[0] in 'RST']) - len(ls) - len(lt) - len(lr)
    inst = open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), 'playbook', 'Executables', 'Install-DomainOS.ps1'), encoding='utf-8-sig').read()
    guard_on_tasks = 'Get-DomainOSPlaybookItems' in inst and '-lt 50' in inst and '$allow.Count -lt 50' not in inst
    R.ok(C, 'the install guard "< 50" counts the CURRENT task-file items only (not the legacy lists) and they are more than 50',
         n_cur >= 50 and guard_on_tasks,
         f'allow-list: {len(allow)} entries, {len(ls) + len(lt) + len(lr)} from the legacy lists, {n_cur} from the task files; '
         f'guard counts task-file items: {guard_on_tasks}')


# =================================================================================================================
# D. PowerShell static
# =================================================================================================================
def area_D(R, ctx):
    pb = ctx.pb
    files = ctx.ps_files
    st = ctx.static
    if not st:
        R.add(D, 'PowerShell AST analysis ran', FAIL, ctx.static_error or 'no output')
        return
    R.add(D, f'PowerShell AST analysis ran on {len(files)} scripts', PASS)
    # Log scanning must be case-sensitive: "Restored: 0 items. Failed: 0." (Undo's summary) is not a failure. 2.1.9's check
    # used -match (case-insensitive) and reported its own Undo dry run as FAIL.
    probs = []
    for f in files:
        txt = open(f, encoding='utf-8-sig').read()
        for i, line in enumerate(txt.split('\n'), 1):
            if re.search(r"-match\s+'[^']*FAILED", line) or re.search(r'-match\s+"[^"]*FAILED', line):
                probs.append(f'{rel(ctx, f)}:{i}: FAILED matched with -match (case-insensitive) - use -cmatch')
    R.check(D, 'log lines are searched for FAILED case-sensitively (-cmatch), so "Failed: 0" is not a failure', probs)
    for f in files:
        r = st.get(f)
        rp = rel(ctx, f)
        R.check(D, f'{rp}: parses without errors', [f'{rp}:{e}' for e in r['errors']])
    R.check(D, 'Windows PowerShell 5.1 compatibility (no ??, ?:, &&, ?., PS7-only cmdlets/parameters/.NET APIs)',
            [f'{rel(ctx, f)}:{c}' for f in files for c in st[f]['compat']])
    R.check(D, 'no $null passed to a .NET string parameter ([NullString]::Value instead; the 2.1.4 bug)',
            [f'{rel(ctx, f)}:{c}' for f in files for c in st[f]['nullArgs']])
    # UTF-8 BOM
    probs, comment_only = [], []
    for f in files:
        b = open(f, 'rb').read()
        if any(c > 127 for c in b) and not b.startswith(b'\xef\xbb\xbf'):
            lines = [i + 1 for i, l in enumerate(b.split(b'\n')) if any(c > 127 for c in l)]
            probs.append(f'{rel(ctx, f)}: non-ASCII on line(s) {lines[:8]} but no UTF-8 BOM (Windows PowerShell 5.1 reads it in the ANSI code page, e.g. 1251: "—" becomes "вЂ”")')
    R.check(D, 'every script with non-ASCII characters has a UTF-8 BOM', probs)
    # the AME environment: scripts the playbook runs get SYSTEM's environment for %USERNAME% etc.
    ame_scripts = set()
    for a in pb.actions():
        inv = ame.ps_invocation(a)
        if inv and inv[0].startswith('.\\'):
            ame_scripts.add(os.path.join(pb.exe, inv[0][2:]))
    common = os.path.join(pb.exe, 'DomainOS-Common.ps1')
    probs, infos = [], []
    for f in files:
        for e in st[f]['env']:
            loc = f'{rel(ctx, f)}:{e["line"]}'
            in_log = re.search(r'Write-(Log|Host|DomainOSNote)\s+["(].*\$env:' + e['var'], e['text'], re.I)
            if e['var'] in ('USERNAME', 'USERDOMAIN'):
                if e['explained'] or in_log:
                    continue
                if f in ame_scripts or f == common:
                    probs.append(f'{loc}: $env:{e["var"]} in a script the playbook runs (AME gives SYSTEM\'s environment: it is the computer account): {e["text"][:140]}')
                else:
                    infos.append(f'{loc}: $env:{e["var"]} (runs as the user, but must match what the AME-run scripts wrote): {e["text"][:120]}')
            elif e['var'] in ('APPDATA', 'LOCALAPPDATA', 'USERPROFILE') and f in ame_scripts and not e['explained']:
                infos.append(f'{loc}: $env:{e["var"]} in a script AME runs (SYSTEM\'s profile if the environment is SYSTEM\'s): {e["text"][:120]}')
    R.check(D, '$env:USERNAME / USERDOMAIN not used for per-user paths in scripts AME runs (or explained in a comment)', probs)
    if infos:
        R.add(D, 'per-user environment variables in AME-run / Undo scripts (verify on Windows)', INFO, '\n'.join(infos))
    # forbidden commands in script code (comments are not code: only command and string tokens of the AST)
    probs = []
    for f in files:
        for c in st[f]['commands']:
            for rx, what in ame.FORBIDDEN_COMMANDS:
                if re.search(rx, c['text'], re.I):
                    probs.append(f'{rel(ctx, f)}:{c["line"]}: {what}: {c["text"][:120]}')
            if re.match(r'(Set|Add|Remove)-MpPreference|Disable-WindowsOptionalFeature|Uninstall-WindowsFeature', c['name'], re.I):
                probs.append(f'{rel(ctx, f)}:{c["line"]}: {c["name"]}')
        for s in st[f]['strings']:
            t = s['text'] if isinstance(s['text'], str) else ''
            if re.search(r'(sc(\.exe)?\s+(config|delete)\s+(sysmain|windefend|wscsvc))|DisableAntiSpyware|EnableVirtualizationBasedSecurity|HypervisorEnforcedCodeIntegrity', t, re.I):
                probs.append(f'{rel(ctx, f)}:{s["line"]}: string touches a protected component: {t[:100]}')
    R.check(D, 'no script touches Defender, VBS/HVCI, TPM, Secure Boot or SysMain (code, not comments)', probs)
    # every script is used; Install -Part Tools copies what Undo needs
    inst = open(os.path.join(pb.exe, 'Install-DomainOS.ps1'), encoding='utf-8-sig').read()
    copied = set()
    for line in inst.split('\n'):
        if 'Copy-Item' in line and '$tools' in line:
            copied |= set(re.findall(r"Join-Path \$here '([^']+\.(?:ps1|json))'", line))
    if not copied:
        R.add(D, 'Install-DomainOS -Part Tools copy list found', FAIL, 'no "Copy-Item ... -Destination $tools" line in Install-DomainOS.ps1')
    alltext = '\n'.join(open(f, encoding='utf-8-sig', errors='replace').read() for f in files) + '\n'.join(
        open(os.path.join(pb.root, r_), encoding='utf-8').read() for r_ in pb.docs)
    probs = []
    for f in files:
        b = os.path.basename(f)
        if b not in alltext.replace(open(f, encoding='utf-8-sig', errors='replace').read(), ''):
            probs.append(f'{rel(ctx, f)} is not used by any task file or script')
    R.check(D, 'every script is used by a task file or another script', probs)
    probs = []
    undo = open(os.path.join(pb.exe, 'Undo-DomainOS.ps1'), encoding='utf-8-sig').read()
    for need in set(re.findall(r"Join-Path \$PSScriptRoot '([^']+\.ps1)'", undo)):
        if need not in copied:
            probs.append(f'Undo-DomainOS.ps1 uses {need} from its own folder but Install-DomainOS.ps1 -Part Tools does not copy it')
    for c in copied:
        if not os.path.isfile(os.path.join(pb.exe, c)):
            probs.append(f'Install-DomainOS.ps1 -Part Tools copies {c}, which does not exist')
    R.check(D, 'Install-DomainOS -Part Tools copies every script Undo runs from Program Files', probs)
    # scripts that write the protected data folder use DomainOS-Common and never trust a file without Test-DomainOSFile
    probs = []
    for f in files:
        t = open(f, encoding='utf-8-sig').read()
        if re.search(r'ConvertFrom-Json', t) and re.search(r"DomainOSData|ProgramData", t) and 'Test-DomainOSFile' not in t \
                and os.path.basename(f) not in ('DomainOS-Common.ps1', 'Check-DomainOS.ps1'):
            probs.append(f'{rel(ctx, f)} reads JSON from the data folder without Test-DomainOSFile')
        for c in st[f]['commands']:
            if re.search(r'reg(\.exe)?["\']?\s+import', c['text'], re.I):
                probs.append(f'{rel(ctx, f)}:{c["line"]}: "reg import" (Import-DomainOSRegFile checks each value instead)')
    R.check(D, 'saved files are read only after Test-DomainOSFile; no reg.exe import', probs)
    chk = os.path.join(pb.exe, 'Check-DomainOS.ps1')
    if not os.path.exists(chk):
        R.add(D, 'Check-DomainOS.ps1 (final check) analysed', SKIP, 'Executables/Check-DomainOS.ps1 is not there yet')
    # self-test of the analyzer on a sample of bad code
    sample = os.path.join(ctx.tmp, 'bad-sample.ps1')
    with open(sample, 'w', encoding='utf-8') as fh:
        fh.write('$a = $b ?? 1\n$c = $x ? 1 : 2\ngit pull && echo ok\n$d = ${o}?.Name\n[IO.File]::Replace("a", "b", $null)\n'
                 'Get-Content x | ConvertFrom-Json -AsHashtable\n1..3 | ForEach-Object -Parallel { $_ }\n$p = [IO.Path]::GetRelativePath("a","b")\n'
                 'Join-Path a b c\n"a--b".Split("--")\nif ($IsWindows) { }\n$u = "$env:USERNAME"\n')
    r = subprocess.run([ctx.pwsh, '-NoProfile', '-File', os.path.join(ctx.tests, 'ps', 'Static.ps1'), sample], capture_output=True, text=True, timeout=120, env=ctx.env)
    try:
        s = json.loads(r.stdout)[sample]
        need = ['??', '?:', '&&', '?.', 'AsHashtable', 'Parallel', 'GetRelativePath', 'more than two paths', 'EACH character', 'IsWindows']
        miss = [n for n in need if not any(n in c for c in s['compat'])]
        if not s['nullArgs']:
            miss.append('$null into File.Replace')
        if not any(e['var'] == 'USERNAME' for e in s['env']):
            miss.append('$env:USERNAME')
        R.check(D, f'self-test: the analyzer finds {len(need) + 2} kinds of problems in a bad sample', [f'not found: {m}' for m in miss])
    except Exception as ex:
        R.add(D, 'self-test: the analyzer finds problems in a bad sample', FAIL, f'{ex}: {r.stdout[:300]} {r.stderr[:300]}')


# =================================================================================================================
# E. Pester
# =================================================================================================================
def area_E(R, ctx, proc_result):
    code, out, xml_path, dur = proc_result
    if not os.path.exists(xml_path):
        R.add(E, 'Pester ran', FAIL, f'no result file (exit {code}): {out[-2000:]}')
        return
    root = ET.parse(xml_path).getroot()
    n = 0
    for tc in root.iter('test-case'):
        n += 1
        name = tc.get('name') or tc.get('description')
        res = tc.get('result')
        if res == 'Success':
            R.add(E, name, PASS)
        elif res in ('Ignored', 'Inconclusive', 'Skipped', 'NotRunnable'):
            R.add(E, name, SKIP, res)
        else:
            msg = tc.find('.//message')
            st = tc.find('.//stack-trace')
            R.add(E, name, FAIL, ((msg.text if msg is not None else '') + '\n' + (st.text if st is not None else ''))[:1500])
    if n == 0:
        R.add(E, 'Pester ran tests', FAIL, out[-2000:])
    bad_containers = re.findall(r'\[-\] (/\S+\.Tests\.ps1) failed', out)
    for c in bad_containers:
        R.add(E, f'{os.path.basename(c)} loads', FAIL, out[out.find(c):][:1500])


# =================================================================================================================
# F. Guide pages
# =================================================================================================================
def _page(ctx, path, lang='en-US', *actions):
    r = subprocess.run(['node', os.path.join(ctx.tests, 'js', 'run-page.js'), path, lang, *actions], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise AssertionError(f'node failed: {r.stderr[-800:]}')
    return json.loads(r.stdout)


def area_F(R, ctx):
    g = os.path.join(ctx.pb.exe, 'Guide')
    wn = os.path.join(g, 'whats-new.html')
    if not shutil.which('node'):
        R.add(F, 'node is available', FAIL, 'node not found: install Node.js')
        return
    text = open(wn, encoding='utf-8').read()

    def first_note():
        m = re.search(r'NOTES = \[\s*\{ v: "([^"]+)", date: "(\d{4}-\d\d-\d\d)"', text)
        assert m, 'whats-new.html: NOTES[0] not found'
        assert m.group(1) == ctx.pb.conf.version, f'whats-new.html: first entry is {m.group(1)}, playbook.conf is {ctx.pb.conf.version}'
    R.run(F, 'whats-new.html: the first NOTES entry is the playbook version', first_note)

    def both(lang, act, expect_lang, word):
        d = _page(ctx, wn, lang, *act)
        assert d['ok'], d['error']
        assert d['lang'] == expect_lang, f'language {d["lang"]}, expected {expect_lang}'
        assert d['langOn'] == [expect_lang], f'highlighted button {d["langOn"]}'
        assert ctx.pb.conf.version in d['text']['h1'], f'h1 "{d["text"]["h1"]}" does not name {ctx.pb.conf.version}'
        assert word in d['text']['h1'], f'h1 "{d["text"]["h1"]}" is not in the expected language'
        lst = d['html']['list']
        assert lst.count('<section') >= 1 and '<li>' in lst, 'no entries rendered'
        assert 'undefined' not in lst and 'null' not in lst, 'an entry is missing a translation (undefined/null rendered)'
        return d
    R.run(F, 'whats-new.html renders in English (browser en-US)', both, 'en-US', [], 'en', "What's new")
    R.run(F, 'whats-new.html renders in Russian (browser ru-RU)', both, 'ru-RU', [], 'ru', 'Что нового')
    R.run(F, 'whats-new.html: the language buttons switch en -> ru', both, 'en-US', ['lang:ru'], 'ru', 'Что нового')

    def notes_complete():
        # every item has both languages, versions are descending and dates ISO
        script = re.search(r'const NOTES = (\[[\s\S]*?\n\]);', text)
        assert script, 'NOTES array not found'
        js = f'const N = {script.group(1)}; const bad = []; let prev = null;' \
             'for (const n of N) { if (!/^\\d+\\.\\d+\\.\\d+$/.test(n.v)) bad.push("version " + n.v);' \
             'if (prev && prev.localeCompare(n.v, undefined, {numeric: true}) <= 0) bad.push("order " + prev + " then " + n.v); prev = n.v;' \
             'for (const g of n.groups) { if (!g.en || !g.ru) bad.push(n.v + ": group without en/ru");' \
             'for (const x of g.items) if (!x.en || !x.ru) bad.push(n.v + ": item without en/ru: " + (x.en || x.ru)); } }' \
             'console.log(JSON.stringify(bad));'
        r = subprocess.run(['node', '-e', js], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr[-500:]
        bad = json.loads(r.stdout)
        assert not bad, '; '.join(bad)
    R.run(F, 'whats-new.html: every entry and item has English and Russian, versions descending', notes_complete)
    guide = os.path.join(g, 'guide.html')

    def guide_sample():
        d = _page(ctx, guide, 'en-US', 'click:0')
        assert d['ok'], d['error']
        assert re.match(r'\d+ of \d+ done', d['text']['count']), d['text']['count']
        assert d['storage'], 'clicking a step did not save it'
        assert d['clicks'] == ['net'], d['clicks']
    R.run(F, 'guide.html (preview data) runs in node, a step can be marked done and is saved', guide_sample)
    # the guide generated by New-DriverGuide.ps1 with fake hardware
    profiles = {'amd-nvidia': ('en', 'asus', 'amd', 'nvidia'), 'intel-amd-ru': ('ru', 'msi', 'intel', 'amd'), 'basic': ('en', '', '', 'intel')}
    for prof, (lang, board, cpu, gpu) in profiles.items():
        def gen(prof=prof, lang=lang, board=board, cpu=cpu, gpu=gpu):
            out = os.path.join(ctx.tmp, 'guide-' + prof)
            r = subprocess.run([ctx.pwsh, '-NoProfile', '-NonInteractive', '-File', os.path.join(ctx.tests, 'ps', 'MakeGuide.ps1'), g, prof, out],
                               capture_output=True, text=True, timeout=120, env=ctx.env)
            assert r.returncode == 0, (r.stdout + r.stderr)[-1500:]
            path = r.stdout.strip().splitlines()[-1]
            html = open(path, encoding='utf-8').read()
            m = re.search(r'/\*DATA\*/(.*?)/\*END\*/', html, re.S)
            assert m, 'no DATA block in the generated guide'
            data = json.loads(m.group(1))
            assert data['lang'] == lang and data['boardVendor'] == board and data['cpuVendor'] == cpu, \
                f'detected lang/board/cpu {data["lang"]}/{data["boardVendor"]}/{data["cpuVendor"]}, expected {lang}/{board}/{cpu}'
            assert data['gpus'] and data['gpus'][0]['vendor'] == gpu, f'GPU vendor {data["gpus"]}, expected {gpu}'
            assert isinstance(data['gpus'], list) and isinstance(data['net'], list) and isinstance(data['problems'], list), 'lists must stay JSON arrays'
            assert '</script' not in m.group(1).lower(), 'the data block can close the script tag'
            d = _page(ctx, path, 'en-US')
            assert d['ok'], d['error']
            assert d['lang'] == lang
            assert '<script>' not in d['html']['steps'], 'device names are not escaped'
            if prof == 'basic':
                assert 'Microsoft Basic Display Adapter' in d['html']['steps'] and 'class="state bad"' in d['html']['steps'], 'the basic adapter is not shown as a problem'
            d2 = _page(ctx, path, 'en-US', 'lang:ru' if lang == 'en' else 'lang:en')
            assert d2['ok'] and d2['lang'] != lang, 'language switch failed'
        R.run(F, f'New-DriverGuide.ps1 with fake hardware ({prof}): vendors detected, page renders in both languages, names escaped', gen)


# =================================================================================================================
# I. built archive
# =================================================================================================================
def area_I(R, ctx):
    ver = ctx.pb.conf.version
    ap = os.path.join(ctx.repo, f'Domain-OS-{ver}.apbx')
    if not os.path.exists(ap):
        R.add(I, f'Domain-OS-{ver}.apbx contents', SKIP, f'{os.path.basename(ap)} not built yet (build.sh builds it after the tests)')
        return
    newer = [f for f in ctx.ps_files + [os.path.join(ctx.pb.root, r_) for r_ in ctx.pb.docs] + [ctx.pb.conf_path] if os.path.getmtime(f) > os.path.getmtime(ap)]
    if newer:
        R.add(I, f'{os.path.basename(ap)} contents', SKIP, f'the archive is older than {len(newer)} source file(s) (e.g. {rel(ctx, newer[0])}): it is checked again after build.sh packs it')
        return
    if not shutil.which('7zr'):
        R.add(I, '7zr available', SKIP, '7zr not installed')
        return
    r = subprocess.run(['7zr', 'l', '-slt', '-pmalte', ap], capture_output=True, text=True, timeout=300)
    R.ok(I, f'{os.path.basename(ap)} opens with the password AME expects', r.returncode == 0, (r.stdout + r.stderr)[-800:])
    if r.returncode != 0:
        return
    names = {l[7:].replace('\\', '/') for l in r.stdout.splitlines() if l.startswith('Path = ')}
    names.discard(ap)
    probs = []
    for need in ('playbook.conf', 'Configuration/main.yml'):
        if need not in names:
            probs.append(f'{need} is not at the archive root')
    for relp in ctx.pb.docs:
        if relp.replace('\\', '/') not in names:
            probs.append(f'{relp} is not in the archive')
    for a in ctx.pb.actions():
        inv = ame.ps_invocation(a)
        if inv and inv[0].startswith('.\\') and 'Executables/' + inv[0][2:].replace('\\', '/') not in names:
            probs.append(f'{a.where()}: {inv[0]} is not in the archive')
    for f in ctx.ps_files:
        rp = os.path.relpath(f, ctx.pb.root).replace('\\', '/')
        if rp not in names:
            probs.append(f'{rp} is not in the archive')
    if 'Executables/DomainScheduler.exe' not in names:
        probs.append('Executables/DomainScheduler.exe is not in the archive (Install -Part Scheduler fails)')
    R.check(I, 'every file the YAML and scripts reference is in the archive', probs)
