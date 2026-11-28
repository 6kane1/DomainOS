#!/usr/bin/env python3
"""
Adds a TEST playbook to the sealed test feed (update/test-native.bin), next to the test Toolbox already there.

  add-test-playbook.py <apbx> <version> <release tag in DomainOS-test> <notes_en> <notes_ru> --site <gh-pages checkout>

The apbx is sealed with the tester key (pb-<version>.bin) and uploaded to the given pre-release of the PRIVATE
6kane1/DomainOS-test; the feed gets a "playbook" entry (sealed, API url + the read-only download token), is sealed
again and signed. Toolbox test builds (channel "test") then offer this playbook when it is newer than the one applied.
Run after publish-test-build.py; then commit and push the site checkout. The token and the key are never printed.
"""
import hashlib, importlib.util, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('ptb', os.path.join(HERE, 'publish-test-build.py'))
ptb = importlib.util.module_from_spec(spec); spec.loader.exec_module(ptb)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def unseal(raw: bytes, key: bytes) -> bytes:
    assert raw[:5] == ptb.MAGIC
    return AESGCM(key).decrypt(raw[5:17], raw[33:] + raw[17:33], None)


def main():
    a = [x for i, x in enumerate(sys.argv[1:], 1) if not x.startswith('--') and sys.argv[i - 1] != '--site']
    apbx, version, tag, en, ru = a[:5]
    site = sys.argv[sys.argv.index('--site') + 1]
    key = ptb.tester_key()
    feed_path = os.path.join(site, 'update', 'test-native.bin')
    feed = json.loads(unseal(open(feed_path, 'rb').read(), key))
    token = open(ptb.TOKENFILE).read().strip()
    tmp = tempfile.mkdtemp(prefix='dos-pb-')
    binf = os.path.join(tmp, f'pb-{version}.bin')
    open(binf, 'wb').write(ptb.seal(open(apbx, 'rb').read(), key))
    subprocess.run(['gh', 'release', 'upload', tag, binf, '-R', ptb.REPO, '--clobber'], check=True)
    aid = subprocess.run(['gh', 'api', f'repos/{ptb.REPO}/releases/tags/{tag}', '--jq',
                          f'.assets[] | select(.name=="{os.path.basename(binf)}") | .id'],
                         check=True, capture_output=True, text=True).stdout.strip()
    if not aid.isdigit(): sys.exit('asset id not found')
    feed['playbook'] = {'version': version, 'sealed': True, 'url': f'https://api.github.com/repos/{ptb.REPO}/releases/assets/{aid}',
                        'token': token, 'sha256': hashlib.sha256(open(binf, 'rb').read()).hexdigest(),
                        'size': os.path.getsize(binf), 'notes_en': en, 'notes_ru': ru}
    open(feed_path, 'wb').write(ptb.seal(json.dumps(feed, ensure_ascii=False).encode(), key))
    subprocess.run([ptb.SIGN, feed_path], check=True)
    print('feed now: toolbox', (feed.get('toolbox') or {}).get('version'), '| playbook', version, '| apbx sha256',
          hashlib.sha256(open(apbx, 'rb').read()).hexdigest())


if __name__ == '__main__':
    main()
