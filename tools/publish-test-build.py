#!/usr/bin/env python3
"""
Publishes a Toolbox TEST build for Domain OS testers (1.15.0 Test 1.1+).

  publish-test-build.py <exe> <version> <notes_en> <notes_ru> --site <gh-pages checkout> [--dry]

What it does:
  * tester key: ~/.config/domainos/tester-key.txt ("DOST-…", 32 random bytes, base32). Created on the first run.
    Hand it out ONLY in the closed testers channel. New key: delete the file and publish again.
  * <exe> is sealed with AES-256-GCM under the key -> tb-<version>.bin (for Toolbox's updater), and packed into
    DomainScheduler-<version>.7z with the key as password (for the first manual install with 7-Zip).
    Both go to a GitHub pre-release "toolbox-test-<version>" (6kane1/DomainOS).
  * the test feed (version, url, SHA-256 and size of the sealed file, notes) is sealed too -> update/test.bin,
    and signed with the update key -> update/test.bin.sig. Nothing about a test build is readable without the key.
Then commit and push the site checkout.
"""
import base64, hashlib, json, os, secrets, subprocess, sys, tempfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

CONF = os.path.expanduser('~/.config/domainos')
KEYFILE = os.path.join(CONF, 'tester-key.txt')
SIGN = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sign-feed.sh')
REPO = '6kane1/DomainOS'
MAGIC = b'DOSE1'
# Test releases are labelled so they are never mistaken for the stable playbook (the release marked Latest, titled
# "✅ Domain OS <ver> — playbook, stable"). When a test playbook archive is added to a release, add it to the title too
# ("… + playbook <ver> test — testers only").
NOTES = ('🧪 **TEST build for testers only: encrypted, opens only with the tester key.** This is **not** the stable Domain OS '
         'playbook. Stable playbook for everyone: https://github.com/6kane1/DomainOS/releases/latest\n\n'
         '🧪 **ТЕСТОВАЯ сборка только для тестировщиков: зашифрована, открывается только ключом тестировщика.** Это **не** '
         'стабильный плейбук Domain OS. Стабильный плейбук для всех: https://github.com/6kane1/DomainOS/releases/latest')


def fmt(key: bytes) -> str:
    raw = base64.b32encode(key).decode().rstrip('=')
    return 'DOST-' + '-'.join(raw[i:i + 4] for i in range(0, len(raw), 4))


def parse(text: str) -> bytes:
    t = text.strip().upper()
    if t.startswith('DOST'): t = t[4:]
    t = t.replace('-', '').replace(' ', '')
    t += '=' * (-len(t) % 8)
    k = base64.b32decode(t)
    assert len(k) == 32
    return k


def tester_key() -> bytes:
    os.makedirs(CONF, mode=0o700, exist_ok=True)
    if not os.path.exists(KEYFILE):
        fd = os.open(KEYFILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.write(fd, (fmt(secrets.token_bytes(32)) + '\n').encode()); os.close(fd)
        print('NEW tester key created:', KEYFILE)
    return parse(open(KEYFILE).read())


def seal(plain: bytes, key: bytes) -> bytes:
    nonce = secrets.token_bytes(12)
    ct_tag = AESGCM(key).encrypt(nonce, plain, None)          # ciphertext || tag(16)
    return MAGIC + nonce + ct_tag[-16:] + ct_tag[:-16]


def main():
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    exe, version, en, ru = a[:4]
    site = sys.argv[sys.argv.index('--site') + 1]
    dry = '--dry' in sys.argv
    key = tester_key(); ktext = fmt(key)
    tag = f'toolbox-test-{version}'
    tmp = tempfile.mkdtemp(prefix='dos-test-')
    binf = os.path.join(tmp, f'tb-{version}.bin')
    open(binf, 'wb').write(seal(open(exe, 'rb').read(), key))
    sz = os.path.join(tmp, f'DomainScheduler-{version}.7z')
    staged = os.path.join(tmp, 'DomainScheduler.exe')
    with open(exe, 'rb') as s, open(staged, 'wb') as d: d.write(s.read())
    subprocess.run(['7zr', 'a', '-t7z', '-mhe=on', '-mx=1', '-p' + ktext, sz, staged], check=True, stdout=subprocess.DEVNULL)
    feed = {'toolbox': {'version': version, 'sealed': True,
                        'url': f'https://github.com/{REPO}/releases/download/{tag}/{os.path.basename(binf)}',
                        'sha256': hashlib.sha256(open(binf, 'rb').read()).hexdigest(), 'size': os.path.getsize(binf),
                        'notes_en': en, 'notes_ru': ru}}
    upd = os.path.join(site, 'update'); os.makedirs(upd, exist_ok=True)
    tb = os.path.join(upd, 'test.bin')
    open(tb, 'wb').write(seal(json.dumps(feed, ensure_ascii=False).encode(), key))
    subprocess.run([SIGN, tb], check=True)
    for old in ('test.json', 'test.json.sig'):
        p = os.path.join(upd, old)
        if os.path.exists(p): os.remove(p)
    print('sealed', binf, os.path.getsize(binf), '| 7z', os.path.getsize(sz), '| feed', tb)
    print('exe sha256', hashlib.sha256(open(exe, 'rb').read()).hexdigest())
    if dry: print('dry run: nothing uploaded; files in', tmp); return
    subprocess.run(['gh', 'release', 'create', tag, binf, sz, '-R', REPO, '--prerelease', '--target', 'main',
                    '--title', f'🧪 TEST · Toolbox {version} — testers only',
                    '--notes', NOTES],
                   check=True)
    print('released', tag, '— now commit and push', site)


if __name__ == '__main__':
    main()
