#!/bin/sh
# Builds Domain-OS-<version>.apbx: a 7z archive with the password AME Wizard expects, files at the archive root.
# Usage: ./build.sh [--skip-tests] [path to DomainScheduler.exe | --toolbox-from-source]
set -e
cd "$(dirname "$0")"
# --skip-tests (first argument): pack without tests/run-all.py. Only for an emergency re-pack of sources that already
# passed; never for a release or a test build that people install.
SKIP_TESTS=0
if [ "$1" = "--skip-tests" ]; then SKIP_TESTS=1; shift; fi
VERSION=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' playbook/playbook.conf)
# The Toolbox shipped with the playbook: a ready exe (default toolbox/DomainScheduler.exe, or a path), or
# --toolbox-from-source to build it from toolbox/ with toolbox/build.sh (the native Toolbox, 1.17.0+: Rust with the
# x86_64-pc-windows-gnullvm target and llvm-mingw, see toolbox/README.md). The source in toolbox/ follows development
# and can be newer than the released Toolbox, so releases are built from the pinned, attested exe.
if [ "$1" = "--toolbox-from-source" ]; then
    [ -x toolbox/build.sh ] || { echo "toolbox/build.sh not found: cannot build Toolbox from source"; exit 1; }
    TBOUT=$(mktemp -d)
    OUT="$TBOUT/DomainScheduler.exe" OBJ="$TBOUT/obj" toolbox/build.sh >/dev/null
    EXE="$TBOUT/DomainScheduler.exe"
else
    EXE=${1:-toolbox/DomainScheduler.exe}
fi
if [ -f "$EXE" ]; then cp "$EXE" playbook/Executables/DomainScheduler.exe; else echo "DomainScheduler.exe not found: the playbook is built without it"; fi
# Checks before packing: every task file must parse as YAML (AME Wizard stops on the first error), a checkbox
# page holds at most 4 options and a page description is 50-85 characters; <Title> and the newest entry of
# Guide/whats-new.html name the version in playbook.conf.
python3 - <<'PY' || { echo "playbook check failed: nothing was built"; exit 1; }
import glob, re, sys, yaml
class L(yaml.SafeLoader): pass
L.add_multi_constructor('!', lambda l, s, n: l.construct_mapping(n) if isinstance(n, yaml.MappingNode) else l.construct_scalar(n))
bad = 0
for f in sorted(glob.glob('playbook/Configuration/**/*.yml', recursive=True)):
    try: yaml.load(open(f, encoding='utf-8'), Loader=L)
    except Exception as e: print('YAML error in', f, '\n', e); bad += 1
conf = open('playbook/playbook.conf', encoding='utf-8').read()
ver = re.search(r'<Version>([^<]+)</Version>', conf).group(1)
# The wizard shows <Title> on every page: it must name the version being built (a test build shows its own number).
if not re.search(r'<Title>Domain OS ' + re.escape(ver) + r'</Title>', conf): print('<Title> must be "Domain OS ' + ver + '"'); bad += 1
# "What's new" (opened after every install): its newest entry must be this version.
wn = open('playbook/Executables/Guide/whats-new.html', encoding='utf-8').read()
m = re.search(r'NOTES = \[\s*\{ v: "([^"]+)"', wn)
if not m or m.group(1) != ver: print('whats-new.html: the first entry is', m and m.group(1), 'but the version is', ver); bad += 1
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
# The expected-state manifest for Check-DomainOS.ps1 (playbook/Executables/expected.json), generated from the task
# files; it also fails the build when Tasks/options.yml and the options of playbook.conf differ.
python3 tools/gen-expected.py || { echo "expected.json could not be generated: nothing was built"; exit 1; }
# The whole test suite (tests/run-all.py: playbook, scripts in a sandbox, Undo, pages, Toolbox, bot, site): any
# failure stops the build. After packing, the archive itself is checked (area I); a broken archive is deleted.
if [ "$SKIP_TESTS" = 1 ]; then
    echo "WARNING: --skip-tests: tests/run-all.py was NOT run"
else
    python3 tests/run-all.py || { echo "tests failed: nothing was built (details above; ./build.sh --skip-tests only for an emergency re-pack)"; exit 1; }
fi
OUT="Domain-OS-$VERSION.apbx"
rm -f "$OUT"
(cd playbook && 7zr a -t7z -pmalte -mhe=on -mx5 -bso0 -bsp0 "../$OUT" .)
if [ "$SKIP_TESTS" = 0 ]; then
    python3 tests/run-all.py --only I || { rm -f "$OUT"; echo "the packed archive failed its check: $OUT deleted"; exit 1; }
fi
ls -l "$OUT"
