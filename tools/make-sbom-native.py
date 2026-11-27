#!/usr/bin/env python3
"""Writes an SPDX 2.3 SBOM (JSON) of the native Toolbox exe (1.17.0+): the exe itself (with its SHA-256), every Rust
crate linked into it for Windows (cargo tree --target x86_64-pc-windows-gnullvm, normal dependencies, versions and
SHA-256 from Cargo.lock), Dear ImGui (version from imgui.h), the embedded fonts, and the build tools (rustc,
llvm-mingw) as BUILD_TOOL_OF.
    python3 tools/make-sbom-native.py --toolbox toolbox --exe out/X.exe --out out/X.spdx.json
Used by .github/workflows/toolbox-build.yml; the SBOM is attested together with the exe (actions/attest-sbom).
Standard library only; it runs cargo and the compiler only to read their versions."""
import argparse, datetime, hashlib, json, os, re, subprocess, sys

TARGET = 'x86_64-pc-windows-gnullvm'


def lock_packages(path):
    """name@version -> sha256 (None for path crates) from Cargo.lock."""
    out, cur = {}, {}
    for line in open(path, encoding='utf-8').read().splitlines() + ['[[package]]']:
        if line.strip() == '[[package]]':
            if 'name' in cur: out[f"{cur['name']}@{cur['version']}"] = cur.get('checksum')
            cur = {}
            continue
        m = re.match(r'(\w+) = "([^"]*)"', line)
        if m: cur[m.group(1)] = m.group(2)
    return out


def linked_crates(core):
    r = subprocess.run(['cargo', 'tree', '--locked', '-e', 'normal', '--target', TARGET, '--prefix', 'none', '-f', '{p}'],
                       cwd=core, capture_output=True, text=True)
    if r.returncode: sys.exit('cargo tree failed: ' + r.stderr[-1000:])
    seen = set()
    for line in r.stdout.splitlines():
        m = re.match(r'(\S+) v(\S+)( \((.*)\))?', line.strip().replace(' (*)', ''))
        if m and not (m.group(4) or '').startswith('/'):
            seen.add((m.group(1), m.group(2)))
    return sorted(seen)


def tool_version(cmd):
    try: return subprocess.run(cmd, capture_output=True, text=True).stdout.strip().splitlines()[0]
    except (OSError, IndexError): return 'unknown'


def main():
    a = argparse.ArgumentParser()
    a.add_argument('--toolbox', required=True); a.add_argument('--exe', required=True); a.add_argument('--out', required=True)
    a = a.parse_args()
    core = os.path.join(a.toolbox, 'core')
    lock = lock_packages(os.path.join(core, 'Cargo.lock'))
    sha = hashlib.sha256(open(a.exe, 'rb').read()).hexdigest()
    version = re.search(r'^\[package\][^\[]*?^version = "([^"]+)"', open(os.path.join(core, 'Cargo.toml')).read(), re.M | re.S).group(1)
    root = 'SPDXRef-Package-Toolbox'
    lic = 'LicenseRef-Domain-OS-License'
    packages = [{'name': 'Domain OS Toolbox', 'SPDXID': root, 'versionInfo': version, 'downloadLocation': 'https://github.com/6kane1/DomainOS',
                 'filesAnalyzed': False, 'licenseConcluded': lic, 'licenseDeclared': lic, 'copyrightText': 'Copyright (c) 2026 Domain OS',
                 'checksums': [{'algorithm': 'SHA256', 'checksumValue': sha}],
                 'comment': f'{os.path.basename(a.exe)}: Rust core (dos_core, threadmap) + C++ Dear ImGui/DirectX 11 app, built for {TARGET}'}]
    rels = [{'spdxElementId': 'SPDXRef-DOCUMENT', 'relationshipType': 'DESCRIBES', 'relatedSpdxElement': root}]

    def add(pid, pkg, rel='DEPENDS_ON', from_root=True):
        packages.append(dict(pkg, SPDXID=pid))
        rels.append({'spdxElementId': pid, 'relationshipType': rel, 'relatedSpdxElement': root} if not from_root else
                    {'spdxElementId': root, 'relationshipType': rel, 'relatedSpdxElement': pid})

    for i, (name, ver) in enumerate(linked_crates(core), 1):
        pkg = {'name': name, 'versionInfo': ver, 'downloadLocation': f'https://crates.io/api/v1/crates/{name}/{ver}/download',
               'filesAnalyzed': False, 'licenseConcluded': 'NOASSERTION', 'licenseDeclared': 'NOASSERTION', 'copyrightText': 'NOASSERTION',
               'externalRefs': [{'referenceCategory': 'PACKAGE-MANAGER', 'referenceType': 'purl', 'referenceLocator': f'pkg:cargo/{name}@{ver}'}]}
        c = lock.get(f'{name}@{ver}')
        if c: pkg['checksums'] = [{'algorithm': 'SHA256', 'checksumValue': c}]
        add(f'SPDXRef-Package-Cargo-{i}', pkg)
    h = open(os.path.join(a.toolbox, 'app', 'third_party', 'imgui', 'imgui.h'), encoding='utf-8').read()
    iv = re.search(r'#define IMGUI_VERSION\s+"([^"]+)"', h).group(1)
    add('SPDXRef-Package-ImGui', {'name': 'Dear ImGui', 'versionInfo': iv, 'downloadLocation': 'https://github.com/ocornut/imgui',
                                  'filesAnalyzed': False, 'licenseConcluded': 'MIT', 'licenseDeclared': 'MIT', 'copyrightText': 'NOASSERTION',
                                  'comment': 'vendored in toolbox/app/third_party/imgui (core + DX11/Win32 backends)'})
    fonts = sorted(f for f in os.listdir(os.path.join(a.toolbox, 'app', 'res', 'Fonts')) if f.endswith('.ttf'))
    add('SPDXRef-Package-Fonts', {'name': 'Inter, JetBrains Mono (embedded fonts)', 'versionInfo': ', '.join(fonts),
                                  'downloadLocation': 'NOASSERTION', 'filesAnalyzed': False, 'licenseConcluded': 'OFL-1.1',
                                  'licenseDeclared': 'OFL-1.1', 'copyrightText': 'NOASSERTION'})
    mingw = os.environ.get('MINGW', '')
    clang = os.path.join(mingw, 'x86_64-w64-mingw32-clang') if mingw else 'x86_64-w64-mingw32-clang'
    for pid, name, ver in (('SPDXRef-Tool-Rust', 'rustc', tool_version(['rustc', '-V'])),
                           ('SPDXRef-Tool-LLVM-MinGW', 'llvm-mingw', (os.path.basename(os.path.dirname(mingw)) if mingw else '') + ' ' + tool_version([clang, '--version']))):
        add(pid, {'name': name, 'versionInfo': ver.strip(), 'downloadLocation': 'NOASSERTION', 'filesAnalyzed': False,
                  'licenseConcluded': 'NOASSERTION', 'licenseDeclared': 'NOASSERTION', 'copyrightText': 'NOASSERTION'},
            rel='BUILD_TOOL_OF', from_root=False)
    doc = {'spdxVersion': 'SPDX-2.3', 'dataLicense': 'CC0-1.0', 'SPDXID': 'SPDXRef-DOCUMENT', 'name': f'Domain OS Toolbox {os.path.basename(a.exe)}',
           'documentNamespace': f'https://github.com/6kane1/DomainOS/sbom/{sha}',
           'creationInfo': {'created': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'creators': ['Tool: tools/make-sbom-native.py']},
           'hasExtractedLicensingInfos': [{'licenseId': lic, 'name': 'Domain OS License', 'extractedText': 'See LICENSE in the repository: all rights reserved.'}],
           'packages': packages, 'relationships': rels}
    json.dump(doc, open(a.out, 'w', encoding='utf-8'), indent=1)
    print(f'SBOM: {a.out} ({len(packages) - 4} crates, Dear ImGui {iv})')


if __name__ == '__main__':
    main()
