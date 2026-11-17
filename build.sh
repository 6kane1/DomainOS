#!/bin/sh
# Builds Domain-OS-<version>.apbx: a 7z archive with the password AME Wizard expects, files at the archive root.
# Usage: ./build.sh [path to DomainScheduler.exe]
set -e
cd "$(dirname "$0")"
VERSION=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' playbook/playbook.conf)
# The Toolbox shipped with the playbook is pinned here (Toolbox 1.7.0: the 1.4.0 interface with the new functions).
EXE=${1:-toolbox/DomainScheduler.exe}
if [ -f "$EXE" ]; then cp "$EXE" playbook/Executables/DomainScheduler.exe; else echo "DomainScheduler.exe not found: the playbook is built without it"; fi
# Checks before packing: every task file must parse as YAML (AME Wizard stops on the first error), a checkbox
# page holds at most 4 options and a page description is 50-85 characters.
python3 - <<'PY' || { echo "playbook check failed: nothing was built"; exit 1; }
import glob, re, sys, yaml
class L(yaml.SafeLoader): pass
L.add_multi_constructor('!', lambda l, s, n: l.construct_mapping(n) if isinstance(n, yaml.MappingNode) else l.construct_scalar(n))
bad = 0
for f in sorted(glob.glob('playbook/Configuration/**/*.yml', recursive=True)):
    try: yaml.load(open(f, encoding='utf-8'), Loader=L)
    except Exception as e: print('YAML error in', f, '\n', e); bad += 1
conf = open('playbook/playbook.conf', encoding='utf-8').read()
for page in conf.split('<CheckboxPage')[1:]:
    page = page.split('</CheckboxPage>')[0]
    n = page.count('<CheckboxOption'); d = re.search(r'Description="([^"]*)"', page).group(1)
    if n > 4: print('more than 4 options:', d); bad += 1
    if not 50 <= len(d) <= 85: print('description length', len(d), ':', d); bad += 1
sys.exit(1 if bad else 0)
PY
# Every PowerShell script is parsed by PowerShell's own parser (tools/psparse, needs the .NET SDK).
if command -v dotnet >/dev/null 2>&1; then
    dotnet run --project tools/psparse -- playbook/Executables/*.ps1 >/tmp/psparse.$$ 2>&1 || { cat /tmp/psparse.$$; rm -f /tmp/psparse.$$; echo "PowerShell syntax check failed: nothing was built"; exit 1; }
    rm -f /tmp/psparse.$$
else
    echo "dotnet not found: PowerShell scripts were NOT syntax-checked"
fi
OUT="Domain-OS-$VERSION.apbx"
rm -f "$OUT"
(cd playbook && 7zr a -t7z -pmalte -mhe=on -mx5 -bso0 -bsp0 "../$OUT" .)
ls -l "$OUT"
