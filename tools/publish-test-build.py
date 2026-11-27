#!/usr/bin/env python3
"""
Publishes a Toolbox TEST build for Domain OS testers (1.15.0 Test 1.1+).

  publish-test-build.py <exe> <version> <notes_en> <notes_ru> --site <gh-pages checkout> [--feed NAME] [--dry]

What it does:
  * tester key: ~/.config/domainos/tester-key.txt ("DOST-…", 32 random bytes, base32). Created on the first run.
    Hand it out ONLY in the closed testers channel. New key: delete the file and publish again.
  * <exe> is sealed with AES-256-GCM under the key -> tb-<version>.bin (for Toolbox's updater), and packed into
    DomainScheduler-<version>.7z with the key as password (for the first manual install with 7-Zip).
    Both go to a pre-release "toolbox-test-<version>" of the PRIVATE repository 6kane1/DomainOS-test (since
    1.16.0 Test 1.8): only the owner and invited testers can see it; test builds never go to the public 6kane1/DomainOS.
  * download token: ~/.config/domainos/test-download-token.txt, a fine-grained GitHub token with Contents: read-only on
    DomainOS-test only. It goes INSIDE the sealed feed; Toolbox 1.16.0 Test 1.8+ downloads the asset through the GitHub
    API with it. Never print it. A leak: revoke it on GitHub, make a new one, publish again.
  * the test feed (version, url, SHA-256 and size of the sealed file, notes) is sealed too -> update/test-native.bin
    (the native Toolbox 1.17.0+, Updater::TEST_FEED), and signed with the update key -> .sig and .signed. Nothing about
    a test build is readable without the key. --feed test.bin writes the C# Toolbox's test feed instead; never put a
    native exe there (owner's decision 2026-11-27: C# clients move to the native Toolbox only through the playbook).
Then commit and push the site checkout.
"""
import base64, hashlib, json, os, secrets, subprocess, sys, tempfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

CONF = os.path.expanduser('~/.config/domainos')
KEYFILE = os.path.join(CONF, 'tester-key.txt')
SIGN = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sign-feed.sh')
REPO = '6kane1/DomainOS-test'          # private: owner + invited testers only
TOKENFILE = os.path.join(CONF, 'test-download-token.txt')
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
    a = [x for i, x in enumerate(sys.argv[1:], 1) if not x.startswith('--') and sys.argv[i - 1] not in ('--site', '--feed')]
    exe, version, en, ru = a[:4]
    site = sys.argv[sys.argv.index('--site') + 1]
    dry = '--dry' in sys.argv
    feed_name = sys.argv[sys.argv.index('--feed') + 1] if '--feed' in sys.argv else 'test-native.bin'
    if feed_name not in ('test-native.bin', 'test.bin'): sys.exit('--feed must be test-native.bin or test.bin')
    key = tester_key(); ktext = fmt(key)
    tag = f'toolbox-test-{version}'
    tmp = tempfile.mkdtemp(prefix='dos-test-')
    binf = os.path.join(tmp, f'tb-{version}.bin')
    open(binf, 'wb').write(seal(open(exe, 'rb').read(), key))
    sz = os.path.join(tmp, f'DomainScheduler-{version}.7z')
    staged = os.path.join(tmp, 'DomainScheduler.exe')
    with open(exe, 'rb') as s, open(staged, 'wb') as d: d.write(s.read())
    subprocess.run(['7zr', 'a', '-t7z', '-mhe=on', '-mx=1', '-p' + ktext, sz, staged], check=True, stdout=subprocess.DEVNULL)
    token = open(TOKENFILE).read().strip()
    if not token.startswith('github_pat_'): sys.exit('test-download-token.txt must hold a fine-grained token (github_pat_...)')
    if not dry:
        subprocess.run(['gh', 'release', 'create', tag, binf, sz, '-R', REPO, '--prerelease', '--target', 'main',
                        '--title', f'🧪 TEST · Toolbox {version} — testers only', '--notes', NOTES], check=True)
        aid = subprocess.run(['gh', 'api', f'repos/{REPO}/releases/tags/{tag}', '--jq',
                              f'.assets[] | select(.name=="{os.path.basename(binf)}") | .id'],
                             check=True, capture_output=True, text=True).stdout.strip()
        if not aid.isdigit(): sys.exit('asset id not found')
    else: aid = '0'
    feed = {'toolbox': {'version': version, 'sealed': True,
                        'url': f'https://api.github.com/repos/{REPO}/releases/assets/{aid}',
                        'token': token,
                        'sha256': hashlib.sha256(open(binf, 'rb').read()).hexdigest(), 'size': os.path.getsize(binf),
                        'notes_en': en, 'notes_ru': ru}}
    upd = os.path.join(site, 'update'); os.makedirs(upd, exist_ok=True)
    tb = os.path.join(upd, feed_name)
    open(tb, 'wb').write(seal(json.dumps(feed, ensure_ascii=False).encode(), key))
    subprocess.run([SIGN, tb], check=True)
    for old in ('test.json', 'test.json.sig'):
        p = os.path.join(upd, old)
        if os.path.exists(p): os.remove(p)
    print('sealed', binf, os.path.getsize(binf), '| 7z', os.path.getsize(sz), '| feed', tb)
    print('exe sha256', hashlib.sha256(open(exe, 'rb').read()).hexdigest())
    if dry: print('dry run: nothing uploaded; files in', tmp); return
    print('released', tag, '— now commit and push', site)


if __name__ == '__main__':
    main()
