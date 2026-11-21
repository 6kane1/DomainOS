"""The AME Wizard playbook model used by the tests: playbook.conf, the YAML task files with line numbers, the action
schema and the owner's safety rules.

The schema follows the AME engine's own source (TrustedUninstaller.Shared: PlaybookParser tag mapping, the
[YamlMember] aliases of every action class and their enums) and docs.amelabs.net. YamlDotNet parses enums ignoring
case, so enum values are compared case-insensitively. Every validator returns a list of "file:line: problem"
strings, so run-all.py can test it on the real playbook (expects none) and on broken samples (expects some).
"""
import os, re, xml.etree.ElementTree as ET
import yaml

# ---------------------------------------------------------------------------------------------------------------
# YAML with AME tags ("- !registryValue: {...}" = the tag "!registryValue:" on a mapping) and line numbers
# ---------------------------------------------------------------------------------------------------------------


class Action(dict):
    """One action: its mapping plus tag, file and line."""
    tag = ''
    file = ''
    line = 0

    def where(self):
        return f'{self.file}:{self.line}'


def _loader(path):
    class L(yaml.SafeLoader):
        pass

    def tagged(loader, suffix, node):
        tag = '!' + suffix
        if isinstance(node, yaml.MappingNode):
            a = Action(loader.construct_mapping(node, deep=True))
        elif isinstance(node, yaml.ScalarNode) and node.value == '':
            a = Action()
        else:
            raise yaml.constructor.ConstructorError(None, None, f'tag {tag} on a {node.id}, expected a mapping', node.start_mark)
        a.tag = tag.rstrip(':')
        a.file = path
        a.line = node.start_mark.line + 1
        return a
    L.add_multi_constructor('!', tagged)

    # duplicate keys in one mapping are an error (YamlDotNet refuses them; PyYAML would keep the last silently)
    def mapping(loader, node, deep=False):
        keys = set()
        for k, _ in node.value:
            kv = loader.construct_object(k, deep=deep)
            if kv in keys:
                raise yaml.constructor.ConstructorError(None, None, f'duplicate key {kv!r}', k.start_mark)
            keys.add(kv)
        return yaml.SafeLoader.construct_mapping(loader, node, deep)
    L.construct_mapping = mapping
    return L


def load_yaml(path, rel=None):
    with open(path, encoding='utf-8-sig') as f:
        text = f.read()
    return yaml.load(text, Loader=_loader(rel or path))


def load_yaml_text(text, rel='<text>'):
    return yaml.load(text, Loader=_loader(rel))


class Playbook:
    """The playbook folder: conf + main.yml + every task reachable from it."""

    def __init__(self, root):
        self.root = root
        self.conf_path = os.path.join(root, 'playbook.conf')
        self.cfg = os.path.join(root, 'Configuration')
        self.exe = os.path.join(root, 'Executables')
        self.conf = Conf(open(self.conf_path, encoding='utf-8-sig').read())
        self.docs = {}            # rel path -> parsed document
        self.errors = []          # parse errors "file: msg"
        for dirpath, _, files in os.walk(self.cfg):
            for f in sorted(files):
                if f.endswith(('.yml', '.yaml')):
                    p = os.path.join(dirpath, f)
                    rel = os.path.relpath(p, root)
                    try:
                        self.docs[rel] = load_yaml(p, rel)
                    except Exception as e:
                        self.errors.append(f'{rel}: {e}')

    def actions(self):
        out = []
        for rel, d in sorted(self.docs.items()):
            if isinstance(d, dict):
                for a in d.get('actions') or []:
                    out.append(a)
        return out

    def task_path(self, action):
        p = str(action.get('path', '')).replace('\\', '/')
        return os.path.normpath(os.path.join(self.cfg, p))


class Conf:
    def __init__(self, text):
        self.text = text
        self.xml = ET.fromstring(text.encode('utf-8'))
        g = lambda n: (self.xml.findtext(n) or '').strip()
        self.version, self.title, self.name = g('Version'), g('Title'), g('Name')
        self.unique_id = g('UniqueId')
        self.kernel_driver = g('UseKernelDriver')
        self.builds = [s.text.strip() for s in self.xml.findall('./SupportedBuilds/string')]
        self.pages = []
        for page in self.xml.find('FeaturePages') or []:
            opts = []
            for o in page.iter():
                if o.tag in ('CheckboxOption', 'RadioOption'):
                    opts.append({'name': (o.findtext('Name') or '').strip(), 'text': (o.findtext('Text') or '').strip(),
                                 'checked': o.get('IsChecked', 'true').lower() != 'false'})
            self.pages.append({'kind': page.tag, 'description': page.get('Description', ''), 'options': opts,
                               'default': page.get('DefaultOption')})

    def options(self):
        return [o for p in self.pages for o in p['options']]

    def option_names(self):
        return [o['name'] for o in self.options()]


# ---------------------------------------------------------------------------------------------------------------
# playbook.conf rules
# ---------------------------------------------------------------------------------------------------------------
SUPPORTED_REQUIRED = {'26200', '26300'}      # 25H2, 26H2
SUPPORTED_REFUSED = {'26100', '28000', '22631'}  # 24H2, 26H1, 23H2


def check_conf(c):
    p = []
    if not re.fullmatch(r'\d+\.\d+\.\d+', c.version):
        p.append(f'playbook.conf: <Version> "{c.version}" is not N.N.N')
    if c.title != f'Domain OS {c.version}':
        p.append(f'playbook.conf: <Title> is "{c.title}", expected "Domain OS {c.version}"')
    if c.name != 'Domain OS':
        p.append(f'playbook.conf: <Name> is "{c.name}"')
    if not re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', c.unique_id):
        p.append(f'playbook.conf: <UniqueId> "{c.unique_id}" is not a GUID')
    if c.kernel_driver.lower() != 'false':
        p.append(f'playbook.conf: <UseKernelDriver> must be false (memory integrity), is "{c.kernel_driver}"')
    for b in c.builds:
        if not re.fullmatch(r'\d{5}', b):
            p.append(f'playbook.conf: SupportedBuilds entry "{b}" is not a 5-digit build')
    if set(c.builds) & SUPPORTED_REFUSED:
        p.append(f'playbook.conf: SupportedBuilds lists refused builds {sorted(set(c.builds) & SUPPORTED_REFUSED)}')
    if not SUPPORTED_REQUIRED <= set(c.builds):
        p.append(f'playbook.conf: SupportedBuilds must contain {sorted(SUPPORTED_REQUIRED)}, has {c.builds}')
    if len(set(c.builds)) != len(c.builds):
        p.append('playbook.conf: SupportedBuilds has duplicates')
    if not c.pages:
        p.append('playbook.conf: no feature pages')
    for i, pg in enumerate(c.pages, 1):
        d = pg['description']
        if not 50 <= len(d) <= 85:
            p.append(f'playbook.conf: page {i} description has {len(d)} characters (50-85 allowed): "{d}"')
        if len(pg['options']) > 4:
            p.append(f'playbook.conf: page {i} ("{d[:40]}") has {len(pg["options"])} options (max 4)')
        if not pg['options']:
            p.append(f'playbook.conf: page {i} has no options')
        for o in pg['options']:
            if not re.fullmatch(r'[a-z0-9][a-z0-9\-]*', o['name']):
                p.append(f'playbook.conf: option name "{o["name"]}" is not lower-case-with-dashes')
            if not o['text']:
                p.append(f'playbook.conf: option {o["name"]} has no <Text>')
    names = c.option_names()
    for n in sorted(set(x for x in names if names.count(x) > 1)):
        p.append(f'playbook.conf: option name "{n}" is used {names.count(n)} times')
    uac = [o for o in c.options() if o['name'] == 'uac-no-prompt']
    if uac and uac[0]['checked']:
        p.append('playbook.conf: option uac-no-prompt must be IsChecked="false" (off by default)')
    return p


# ---------------------------------------------------------------------------------------------------------------
# action schema
# ---------------------------------------------------------------------------------------------------------------
COMMON = {'weight', 'status', 'errorAction', 'option', 'options', 'builds', 'cpuArch', 'onUpgrade', 'onUpgradeVersions',
          'previousOption', 'iso', 'oobe', 'ignoreErrors', 'allowRetries'}
FIELDS = {
    '!registryValue': {'path', 'value', 'data', 'type', 'scope', 'operation'},
    '!registryKey': {'path', 'scope', 'operation'},
    '!service': {'name', 'operation', 'startup', 'deleteStop', 'deleteUsingRegistry', 'device', 'scope'},
    '!scheduledTask': {'path', 'operation', 'data'},
    '!appx': {'name', 'type', 'operation', 'verboseOutput', 'unregister'},
    '!run': {'exe', 'path', 'args', 'baseDir', 'exeDir', 'createWindow', 'hideWindow', 'showOutput', 'showError',
             'timeout', 'wait', 'runas', 'handleExitCodes'},
    '!powerShell': {'command', 'runas', 'timeout', 'wait', 'exeDir', 'handleExitCodes'},
    '!cmd': {'command', 'runas', 'timeout', 'wait', 'exeDir', 'handleExitCodes'},
    '!taskKill': {'name', 'pathContains', 'id'},
    '!writeStatus': {'status'},
    '!status': {'status'},
    '!task': {'path'},
    '!file': {'path', 'prioritizeExe'},
    '!systemPackage': {'name', 'arch', 'language', 'regexExcludeFiles', 'excludeDependents'},
    '!software': {'name', 'package', 'source', 'args'},
    '!download': {'url', 'path', 'name'},
}
REQUIRED = {'!registryValue': ['path', 'value'], '!registryKey': ['path'], '!service': ['name'], '!scheduledTask': ['path'],
            '!appx': ['name'], '!run': ['exe'], '!powerShell': ['command'], '!cmd': ['command'], '!writeStatus': ['status'],
            '!status': ['status'], '!task': ['path'], '!file': ['path']}
ENUMS = {
    ('!registryValue', 'type'): {'reg_sz', 'reg_multi_sz', 'reg_expand_sz', 'reg_dword', 'reg_qword', 'reg_binary', 'reg_none', 'reg_unknown'},
    ('!registryValue', 'operation'): {'add', 'delete', 'set'},
    ('!registryKey', 'operation'): {'add', 'delete'},
    ('!service', 'operation'): {'stop', 'continue', 'start', 'pause', 'delete', 'change'},
    ('!scheduledTask', 'operation'): {'delete', 'enable', 'disable', 'deletefolder'},
    ('!appx', 'type'): {'family', 'package', 'app'},
    ('!appx', 'operation'): {'remove', 'clearcache'},
}
SCOPES = {'allusers', 'currentuser', 'activeusers', 'defaultuser', 'defaultusers'}
RUNAS = {'trustedinstaller', 'system', 'currentusertrustedinstaller', 'currentuserelevated', 'currentuser'}
ERROR_ACTIONS = {'ignore', 'log', 'notify', 'halt'}
EXIT_ACTIONS = {'log', 'retry', 'error', 'retryerror', 'halt'}
BOOL_FIELDS = {'exeDir', 'baseDir', 'wait', 'createWindow', 'hideWindow', 'showOutput', 'showError', 'deleteStop',
               'deleteUsingRegistry', 'device', 'ignoreErrors', 'verboseOutput', 'unregister', 'onUpgrade', 'allowRetries'}
EXIT_KEY = re.compile(r'!?(>=|<=|>|<)?-?\d+')
BUILD_EXPR = re.compile(r'!?(>=|<=|>|<)?(\d{5})(\.\d+)?')


def _low(v):
    return str(v).strip().lower()


def option_refs(a):
    refs = []
    if 'option' in a and a['option'] is not None:
        refs.append(str(a['option']))
    if isinstance(a.get('options'), list):
        refs += [str(x) for x in a['options']]
    return refs


def check_action(a, option_names, supported_builds):
    """Schema and value checks of one action."""
    p = []
    w = a.where()
    t = a.tag
    if t not in FIELDS:
        return [f'{w}: unknown action type {t} (not mapped by the AME parser)']
    allowed = FIELDS[t] | COMMON
    for k in a:
        if k not in allowed:
            p.append(f'{w}: {t} has the unknown field "{k}" (AME would refuse the file)')
    for k in REQUIRED.get(t, []):
        if k not in a or a[k] is None or (k != 'value' and str(a[k]).strip() == ''):
            p.append(f'{w}: {t} without its required field "{k}"')
    for (tt, k), vals in ENUMS.items():
        if tt == t and k in a and _low(a[k]) not in vals:
            p.append(f'{w}: {t} {k}: "{a[k]}" is not one of {sorted(vals)}')
    if 'scope' in a and _low(a['scope']) not in SCOPES:
        p.append(f'{w}: scope "{a["scope"]}" is not valid')
    if 'errorAction' in a and _low(a['errorAction']) not in ERROR_ACTIONS:
        p.append(f'{w}: errorAction "{a["errorAction"]}" is not one of Ignore/Log/Notify/Halt')
    if 'runas' in a and _low(a['runas']) not in RUNAS:
        p.append(f'{w}: runas "{a["runas"]}" is not valid')
    for k in BOOL_FIELDS & set(a):
        if not isinstance(a[k], bool):
            p.append(f'{w}: {k} must be true/false, is {a[k]!r}')
    if 'weight' in a and not (isinstance(a['weight'], int) and not isinstance(a['weight'], bool) and 0 <= a['weight'] <= 1000):
        p.append(f'{w}: weight must be an integer 0-1000, is {a["weight"]!r}')
    if 'timeout' in a and not (isinstance(a['timeout'], int) and a['timeout'] > 0):
        p.append(f'{w}: timeout must be a positive integer (ms), is {a["timeout"]!r}')
    if 'handleExitCodes' in a:
        h = a['handleExitCodes']
        if not isinstance(h, dict) or not h:
            p.append(f'{w}: handleExitCodes must be a non-empty mapping')
        else:
            for k, v in h.items():
                if not EXIT_KEY.fullmatch(str(k).strip()):
                    p.append(f'{w}: handleExitCodes key "{k}" is not an exit-code expression (e.g. 2, "!0", ">=1")')
                if _low(v) not in EXIT_ACTIONS:
                    p.append(f'{w}: handleExitCodes value "{v}" is not one of log/error/halt/retry/retryError')
    # options
    for ref in option_refs(a):
        name = ref[1:] if ref.startswith('!') else ref
        if not re.fullmatch(r'[a-z0-9][a-z0-9\-]*', name):
            p.append(f'{w}: option "{ref}" is not a plain option name (or !name)')
        elif name not in option_names:
            p.append(f'{w}: option "{ref}" refers to "{name}", which is not an option in playbook.conf')
    if 'options' in a and not isinstance(a['options'], list):
        p.append(f'{w}: options must be a list')
    # builds
    if 'builds' in a:
        b = a['builds']
        if not isinstance(b, list) or not b:
            p.append(f'{w}: builds must be a non-empty list of strings')
        else:
            for x in b:
                m = BUILD_EXPR.fullmatch(str(x).strip())
                if not isinstance(x, str):
                    p.append(f'{w}: builds entry {x!r} must be a quoted string')
                elif not m:
                    p.append(f'{w}: builds entry "{x}" is not a build expression')
                elif not any(c in str(x) for c in '<>!') and m.group(2) not in supported_builds:
                    p.append(f'{w}: builds entry "{x}" is not a supported build {sorted(supported_builds)} (dead action)')
    # type specific
    if t == '!registryValue':
        path = str(a.get('path', ''))
        op = _low(a.get('operation', 'add'))
        if op != 'delete':
            if 'type' not in a:
                p.append(f'{w}: !registryValue without type')
            if 'data' not in a:
                p.append(f'{w}: !registryValue without data')
        typ = _low(a.get('type', ''))
        data = a.get('data')
        if typ in ('reg_dword', 'reg_qword') and op != 'delete':
            s = str(data).strip()
            try:
                n = int(s, 16) if s.lower().startswith('0x') else int(s)
                lim = 0xFFFFFFFF if typ == 'reg_dword' else 0xFFFFFFFFFFFFFFFF
                if not -2**31 <= n <= lim:
                    p.append(f'{w}: {typ.upper()} data {s} out of range')
            except ValueError:
                p.append(f'{w}: {typ.upper()} data "{data}" is not a number')
        if typ == 'reg_sz' and data is not None and not isinstance(data, str):
            p.append(f'{w}: REG_SZ data {data!r} should be a quoted string')
    if t in ('!registryValue', '!registryKey'):
        path = str(a.get('path', ''))
        if not re.match(r'(HKLM|HKCU)\\', path):
            p.append(f'{w}: registry path "{path}" must start with HKLM\\ or HKCU\\')
        if '/' in path or path.endswith('\\') or '\\\\' in path or path != path.strip():
            p.append(f'{w}: registry path "{path}" has a slash, a trailing or double backslash or spaces')
    if t == '!service':
        op = _low(a.get('operation', 'delete'))
        if 'operation' not in a:
            p.append(f'{w}: !service without operation (AME default is DELETE)')
        if op == 'change':
            s = a.get('startup')
            if not (isinstance(s, int) and not isinstance(s, bool) and 0 <= s <= 4):
                p.append(f'{w}: !service change needs startup 0-4, has {s!r}')
        elif 'startup' in a:
            p.append(f'{w}: startup is only used with operation change')
        if not re.fullmatch(r'[\w.\-]+', str(a.get('name', ''))):
            p.append(f'{w}: service name "{a.get("name")}" is not plain')
    if t == '!scheduledTask':
        if 'operation' not in a:
            p.append(f'{w}: !scheduledTask without operation (AME default is DELETE)')
        if not str(a.get('path', '')).startswith('\\'):
            p.append(f'{w}: task path "{a.get("path")}" must start with a backslash')
        if str(a.get('path', '')).endswith('\\') and _low(a.get('operation', '')) != 'deletefolder':
            p.append(f'{w}: task path "{a.get("path")}" ends with a backslash')
    if t == '!run':
        if _low(a.get('wait', True)) == 'false' and 'handleExitCodes' in a:
            p.append(f'{w}: handleExitCodes has no effect with wait: false')
    if t in ('!writeStatus', '!status') and len(str(a.get('status', ''))) > 80:
        p.append(f'{w}: status text longer than 80 characters')
    return p


# ---------------------------------------------------------------------------------------------------------------
# !run actions that start a PowerShell script
# ---------------------------------------------------------------------------------------------------------------
PS_EXE = r'%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'


def ps_invocation(a):
    """(script file name, [(param, value or None)]) for a !run of powershell.exe -File, else None."""
    if a.tag != '!run' or 'powershell' not in str(a.get('exe', '')).lower():
        return None
    args = str(a.get('args', ''))
    m = re.search(r'-File\s+("([^"]+)"|(\S+))(.*)$', args)
    if not m:
        return None
    script = (m.group(2) or m.group(3))
    rest = m.group(4)
    params = []
    for tok in re.finditer(r'-(\w+)(?:\s+("[^"]*"|[^-\s]\S*))?', rest):
        params.append((tok.group(1), tok.group(2).strip('"') if tok.group(2) else None))
    return script, params, args


# ---------------------------------------------------------------------------------------------------------------
# contradictions: the same target written two ways when both conditions can hold
# ---------------------------------------------------------------------------------------------------------------
def _cond(a):
    opt = a.get('option')
    builds = a.get('builds')
    return (str(opt) if opt is not None else None, tuple(builds) if isinstance(builds, list) else None, a.get('options'))


def _may_overlap(c1, c2):
    o1, b1, m1 = c1
    o2, b2, m2 = c2
    if o1 and o2 and (o1 == '!' + o2 or o2 == '!' + o1):
        return False
    if b1 and b2 and all(re.fullmatch(r'\d+', x) for x in b1 + b2) and not set(b1) & set(b2):
        return False
    return True


def target_effect(a):
    """(target key, effect) for actions whose effect on one target can contradict another, else None."""
    t = a.tag
    if t == '!registryValue':
        op = _low(a.get('operation', 'add'))
        eff = ('delete',) if op == 'delete' else (_low(a.get('type')), str(a.get('data')))
        return (('R', str(a.get('path')).lower(), str(a.get('value')).lower()), eff)
    if t == '!registryKey':
        return (('K', str(a.get('path')).lower()), _low(a.get('operation', 'delete')))
    if t == '!service':
        op = _low(a.get('operation', 'delete'))
        if op in ('change', 'delete'):
            return (('S', str(a.get('name')).lower()), (op, a.get('startup')))
        if op in ('stop', 'start'):
            return (('Srun', str(a.get('name')).lower()), op)
    if t == '!scheduledTask':
        return (('T', str(a.get('path')).lower()), _low(a.get('operation', 'delete')))
    return None


def check_contradictions(actions):
    p = []
    seen = {}
    for a in actions:
        te = target_effect(a)
        if not te:
            continue
        key, eff = te
        for b, effb in seen.get(key, []):
            if effb != eff and _may_overlap(_cond(a), _cond(b)):
                p.append(f'{a.where()}: contradicts {b.where()} for {key[1:]}: {effb} vs {eff} under overlapping conditions '
                         f'(option {b.get("option")!r}/{a.get("option")!r}, builds {b.get("builds")}/{a.get("builds")})')
            elif effb == eff and _cond(a) == _cond(b):
                p.append(f'{a.where()}: duplicate of {b.where()} ({key[1:]})')
        seen.setdefault(key, []).append((a, eff))
    return p


# ---------------------------------------------------------------------------------------------------------------
# the owner's rules: what Domain OS must never touch, and what must stay as it is
# ---------------------------------------------------------------------------------------------------------------
FORBIDDEN_REG_PATH = [
    (r'windows defender|microsoft defender|\\defender\\|windows advanced threat protection|\\spynet', 'Defender'),
    (r'smartscreen|phishingfilter|\\appreputation', 'SmartScreen'),
    (r'deviceguard|hypervisorenforcedcodeintegrity|\\ci\\policy|\\lsa\\?$', 'VBS / HVCI / Device Guard'),
    (r'\\tpm(\\|$)|\\tbs(\\|$)', 'TPM'),
    (r'secureboot', 'Secure Boot'),
    (r'\\windows security health|\\security center|\\securityhealthservice|\\wscsvc', 'Windows Security'),
]
FORBIDDEN_VALUES = [
    (r'^(enablesmartscreen|smartscreenenabled|enablewebcontentevaluation|preventsmartscreenpromptoverride)$', 'SmartScreen'),
    (r'^(disableantispyware|disableantivirus|disablerealtimemonitoring|disablebehaviormonitoring|disableioavprotection|'
     r'tamperprotection|mpenablepus|puaprotection|spynetreporting|submitsamplesconsent)$', 'Defender'),
    (r'^(enablevirtualizationbasedsecurity|hypervisorenforcedcodeintegrity|requireplatformsecurityfeatures|lsacfgflags|'
     r'runasppl|vulnerabledriverblocklistenable|hvciondisabled)$', 'VBS / HVCI / LSA protection'),
    (r'^(enablelua)$', 'UAC (EnableLUA: never switched off)'),
    (r'^(enableprefetcher|enablesuperfetch)$', 'SysMain / prefetch'),
]
FORBIDDEN_SERVICES = {
    'windefend': 'Defender', 'wdnissvc': 'Defender', 'wdnisdrv': 'Defender', 'wdfilter': 'Defender', 'wdboot': 'Defender',
    'sense': 'Defender', 'mdcoresvc': 'Defender', 'securityhealthservice': 'Windows Security', 'wscsvc': 'Windows Security',
    'sgrmbroker': 'System Guard', 'tpm': 'TPM', 'tbs': 'TPM', 'mpssvc': 'Firewall', 'bfe': 'Firewall',
    'wuauserv': 'Windows Update', 'usosvc': 'Windows Update', 'bits': 'Windows Update', 'cryptsvc': 'crypto',
    'appidsvc': 'AppLocker', 'xblauthmanager': 'Xbox sign-in', 'xblgamesave': 'Xbox', 'xboxnetapisvc': 'Xbox',
    'gamingservices': 'Xbox', 'gamingservicesnet': 'Xbox', 'easyanticheat': 'anti-cheat', 'beservice': 'anti-cheat',
    'vgc': 'anti-cheat', 'vgk': 'anti-cheat', 'faceit': 'anti-cheat', 'faceitservice': 'anti-cheat',
}
FORBIDDEN_TASK_PATH = [(r'\\windows defender\\', 'Defender'), (r'\\tpm\\', 'TPM'), (r'\\sysmain\\', 'SysMain'),
                       (r'\\windowsupdate\\', 'Windows Update'), (r'\\updateorchestrator\\', 'Windows Update'),
                       (r'\\xblgamesave', 'Xbox')]
FORBIDDEN_APPX = [(r'sechealthui|windows\.security|windowsdefender', 'Windows Security'),
                  (r'xboxidentityprovider|gamingservices|xboxgamingoverlay|xbox\.tcui', 'Xbox sign-in / Gaming Services / Game Bar'),
                  (r'desktopappinstaller', 'App Installer / winget'), (r'webview|webexperiencepack', 'WebView2'),
                  (r'^microsoft\.(vclibs|ui\.xaml|net\.native|windowsappruntime)', 'framework packages')]
FORBIDDEN_COMMANDS = [
    (r'set-mppreference|add-mppreference|remove-mppreference', 'Defender settings'),
    (r'bcdedit[^\n]*(testsigning|nointegritychecks|disableelamdrivers|\bnx\b|hypervisorlaunchtype\s+off)', 'boot security'),
    (r'disable-tpmautoprovisioning|clear-tpm|initialize-tpm', 'TPM'),
    (r'confirm-securebootuefi.*set|set-securebootuefi', 'Secure Boot'),
    (r'sc(\.exe)?\s+(config|stop|delete)\s+(sysmain|windefend|wscsvc|securityhealthservice)', 'protected service'),
]


def check_forbidden(actions, conf):
    p = []
    uac_opt = 'uac-no-prompt'
    prio = []
    game_mode = {}
    for a in actions:
        w = a.where()
        t = a.tag
        if t in ('!registryValue', '!registryKey'):
            path = str(a.get('path', '')).lower()
            for rx, what in FORBIDDEN_REG_PATH:
                if re.search(rx, path):
                    p.append(f'{w}: touches {what} ({a.get("path")})')
        if t == '!registryValue':
            val = str(a.get('value', '')).lower()
            for rx, what in FORBIDDEN_VALUES:
                if re.search(rx, val):
                    p.append(f'{w}: touches {what} ({a.get("path")}\\{a.get("value")})')
            data = str(a.get('data', '')).strip().lower()
            num = None
            try:
                num = int(data, 16) if data.startswith('0x') else int(data)
            except ValueError:
                pass
            if val == 'win32priorityseparation':
                prio.append(a)
                if num != 0x18 or _low(a.get('type')) != 'reg_dword' or _low(a.get('operation', 'add')) == 'delete':
                    p.append(f'{w}: Win32PrioritySeparation must be REG_DWORD 24 (0x18), is {a.get("type")} {a.get("data")}')
            if val in ('autogamemodeenabled', 'allowautogamemode'):
                game_mode[val] = a
                if num != 1 or _low(a.get('operation', 'add')) == 'delete':
                    p.append(f'{w}: Game Mode must stay on: {a.get("value")} = {a.get("data")}')
            if val == 'consentpromptbehavioradmin' or val == 'promptonsecuredesktop':
                silent = (val == 'consentpromptbehavioradmin' and num == 0) or (val == 'promptonsecuredesktop' and num == 0)
                if silent and str(a.get('option')) != uac_opt:
                    p.append(f'{w}: {a.get("value")} = {num} (no UAC prompt) only behind option "{uac_opt}", has option {a.get("option")!r}')
                # 0 = no prompt (only behind the option); 3 = ask for credentials, the playbook's value without the tick
                # since 2.2.6 (owner's decision 2026-11-21); 5 = Windows default, used up to 2.2.4.
                if val == 'consentpromptbehavioradmin' and num not in (0, 3, 5):
                    p.append(f'{w}: ConsentPromptBehaviorAdmin = {num}: only 0 (option), 3 (credentials) or 5 (Windows default) are expected')
            if val == 'enablelua':
                p.append(f'{w}: EnableLUA must never be written')
        if t == '!service':
            name = str(a.get('name', '')).lower()
            op = _low(a.get('operation', 'delete'))
            if name in FORBIDDEN_SERVICES:
                p.append(f'{w}: service {a.get("name")} ({FORBIDDEN_SERVICES[name]}) must not be touched')
            if name == 'sysmain' and not (op == 'change' and a.get('startup') == 2):
                p.append(f'{w}: SysMain must stay on: only "change startup 2" is allowed, has {op} {a.get("startup")}')
            if op == 'delete':
                p.append(f'{w}: deleting service {a.get("name")} (not revertible by Undo)')
        if t == '!scheduledTask':
            path = str(a.get('path', '')).lower()
            for rx, what in FORBIDDEN_TASK_PATH:
                if re.search(rx, path):
                    p.append(f'{w}: scheduled task of {what} ({a.get("path")})')
            if _low(a.get('operation', 'delete')) in ('delete', 'deletefolder'):
                p.append(f'{w}: deleting task {a.get("path")} (not revertible by Undo; use disable)')
        if t == '!appx':
            name = str(a.get('name', '')).lower()
            for rx, what in FORBIDDEN_APPX:
                if re.search(rx, name):
                    p.append(f'{w}: removes {what} ({a.get("name")})')
        if t in ('!run', '!cmd', '!powerShell'):
            text = ' '.join(str(a.get(k, '')) for k in ('exe', 'args', 'command')).lower()
            for rx, what in FORBIDDEN_COMMANDS:
                if re.search(rx, text):
                    p.append(f'{w}: command touches {what}: {text[:120]}')
            if 'set-hypervisor.ps1' in text and '-restore' not in text:
                p.append(f'{w}: Set-Hypervisor.ps1 may only run with -Restore (it switches the hypervisor off otherwise)')
        if t == '!systemPackage':
            p.append(f'{w}: !systemPackage removes Windows components (not revertible)')
    if not prio:
        p.append('no action sets Win32PrioritySeparation = 24 (the owner requires 0x18)')
    for v in ('autogamemodeenabled', 'allowautogamemode'):
        if v not in game_mode:
            p.append(f'Game Mode: no action writes {v} = 1 (it must be switched on explicitly)')
    if conf is not None:
        uac = [o for o in conf.options() if o['name'] == uac_opt]
        if not uac:
            p.append(f'playbook.conf has no option "{uac_opt}" although the rules reference it')
    return p
