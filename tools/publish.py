#!/usr/bin/env python3
"""Sign one reviewed draft release and put it on the update feed.

Runs in the publish workflow, in the job that a required reviewer has approved. The signing key
exists only in that job. Nothing here installs a package: Python's standard library, openssl and
git are all the code that ever sees the key.

Everything signed is checked first: the draft must hold exactly the expected files, the package
must match its manifest byte for byte, and the version must be newer than what the feed serves.
The release is published before the feed moves, so the feed never names a missing package.
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

VERSION_RE = re.compile(r'^(\d+)\.(\d+)\.(\d+)(?:-(beta|rc)\.(\d+))?$')
FORMAT = 'wgs-release/1'
PRODUCT = 'woods-game-studio'
# DER wrappers for raw Ed25519 keys (RFC 8410)
PKCS8 = bytes.fromhex('302e020100300506032b657004220420')
SPKI = bytes.fromhex('302a300506032b6570032100')


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw).stdout.strip()


def fail(msg):
    raise SystemExit(f'not published: {msg}')


def order(v):
    major, minor, patch, pre, n = VERSION_RE.match(v).groups()
    return int(major), int(minor), int(patch), {'beta': 0, 'rc': 1, None: 2}[pre], int(n or 0)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def sign(data, seed_b64):
    seed = base64.b64decode(seed_b64.strip())
    if len(seed) != 32:
        fail('the signing key is not a 32-byte Ed25519 seed')
    with tempfile.TemporaryDirectory() as t:
        key, msg = os.path.join(t, 'k'), os.path.join(t, 'm')
        with open(os.open(key, os.O_WRONLY | os.O_CREAT, 0o600), 'wb') as f:
            f.write(PKCS8 + seed)
        with open(msg, 'wb') as f:
            f.write(data)
        out = subprocess.run(['openssl', 'pkeyutl', '-sign', '-keyform', 'DER', '-inkey', key, '-rawin', '-in', msg],
                             check=True, capture_output=True).stdout
    return base64.b64encode(out).decode()


def verify(data, sig_b64, pub_b64):
    with tempfile.TemporaryDirectory() as t:
        pub, msg, sig = (os.path.join(t, n) for n in 'pms')
        for path, content in ((pub, SPKI + base64.b64decode(pub_b64)), (msg, data), (sig, base64.b64decode(sig_b64))):
            with open(path, 'wb') as f:
                f.write(content)
        r = subprocess.run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-inkey', pub, '-rawin',
                            '-in', msg, '-sigfile', sig], capture_output=True)
    return r.returncode == 0


def live(url, want, minutes=8):
    """Wait until the public feed really serves this version."""
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        try:
            req = urllib.request.Request(f'{url}?t={int(time.time())}', headers={'User-Agent': 'wgs-publish'})
            with urllib.request.urlopen(req, timeout=20) as r:
                if json.load(r).get('version') == want:
                    return True
        except (OSError, ValueError):
            pass
        time.sleep(10)
    return False


def main():
    version = os.environ['VERSION'].strip().lstrip('v')
    repo = os.environ['GITHUB_REPOSITORY']
    key = os.environ.get('WGS_SIGNING_KEY', '')
    feed_url = os.environ['FEED_URL'].rstrip('/')
    if not VERSION_RE.match(version):
        fail(f'{version!r} is not a version')
    if not key.strip():
        fail('no signing key: this job must run in the approved "release" environment')
    tag = f'v{version}'
    channel = 'beta' if '-' in version else 'stable'
    package = f'WoodsGameStudio-{version}-win64.zip'
    installer = f'WoodsGameStudioSetup-{version}.exe'
    manifest_name = f'{channel}.json'

    info = json.loads(run('gh', 'release', 'view', tag, '-R', repo, '--json', 'isDraft,assets'))
    names = sorted(a['name'] for a in info['assets'])
    if names != sorted([package, installer, manifest_name]):
        fail(f'the draft holds {names}')

    work = tempfile.mkdtemp()
    run('gh', 'release', 'download', tag, '-R', repo, '-D', work)
    with open(os.path.join(work, manifest_name), 'rb') as f:
        raw = f.read()
    m = json.loads(raw)
    pkg = m['package']
    expected = {'format': FORMAT, 'product': PRODUCT, 'channel': channel, 'version': version}
    for k, v in expected.items():
        if m.get(k) != v:
            fail(f'manifest {k} is {m.get(k)!r}, not {v!r}')
    zpath = os.path.join(work, package)
    if pkg['name'] != package or pkg['url'] != f'https://github.com/{repo}/releases/download/{tag}/{package}':
        fail(f'the manifest points somewhere else: {pkg["url"]}')
    if pkg['sha256'] != sha256(zpath) or pkg['size'] != os.path.getsize(zpath):
        fail('the package is not the one the manifest describes')
    with zipfile.ZipFile(zpath) as z:
        inner = json.loads(z.read('payload.json'))
    if inner.get('version') != version or inner.get('product') != PRODUCT:
        fail('the package says it is a different version')

    run('gh', 'auth', 'setup-git')
    run('git', 'fetch', '--depth=1', 'origin', 'gh-pages')
    pages = os.path.join(work, 'pages')
    run('git', 'worktree', 'add', '--detach', pages, 'FETCH_HEAD')
    current = os.path.join(pages, manifest_name)
    if os.path.exists(current):
        with open(current, encoding='utf-8') as f:
            now = json.load(f)['version']
        if order(version) <= order(now):
            fail(f'the feed already serves {now}')

    signature = sign(raw, key)
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'release_keys.json'), encoding='utf-8') as f:
        keys = json.load(f)['keys']
    if not any(verify(raw, signature, k) for k in keys):
        fail('the key in this environment is not one that installed copies trust')

    flags = ['--prerelease'] if channel == 'beta' else ['--latest']
    if info['isDraft']:
        run('gh', 'release', 'edit', tag, '-R', repo, '--draft=false', '--tag', tag, *flags)
    with open(current, 'wb') as f:
        f.write(raw)
    with open(current + '.sig', 'w', encoding='ascii') as f:
        f.write(signature)
    run('git', '-C', pages, 'config', 'user.name', 'woods-release')
    run('git', '-C', pages, 'config', 'user.email', 'woods-release@users.noreply.github.com')
    run('git', '-C', pages, 'add', '-A')
    run('git', '-C', pages, 'commit', '-m', f'Woods Game Studio {version} ({channel})')
    run('git', '-C', pages, 'push', 'origin', 'HEAD:gh-pages')
    subprocess.run(['gh', 'api', '-X', 'POST', f'repos/{repo}/pages/builds'], capture_output=True)   # nudge; a push also builds
    if not live(f'{feed_url}/{manifest_name}', version):
        fail(f'{tag} is published but the feed has not updated yet: re-run this job')
    run('gh', 'release', 'delete-asset', tag, manifest_name, '-R', repo, '--yes')
    print(f'{version} is live on the {channel} channel: {feed_url}/{manifest_name}')


if __name__ == '__main__':
    sys.exit(main())
