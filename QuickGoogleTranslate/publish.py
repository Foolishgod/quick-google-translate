"""Publish one version's reviewed assets; preserve historical release downloads."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPO = 'Foolishgod/quick-google-translate'
ACCOUNT = 'local.quickgoogletranslate.mac.updates'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'


def release_assets(root, version, build):
    """Use only assets referenced by this version's signed update entry."""
    feed = root / 'dist/updates/appcast.xml'
    items = ET.parse(feed).findall('./channel/item')
    matches = [item for item in items if item.findtext(f'{{{NS}}}version') == build]
    if len(matches) != 1 or matches[0].findtext(f'{{{NS}}}shortVersionString') != version:
        raise RuntimeError('Update feed does not match Info.plist; run release.sh first')
    if any(int(item.findtext(f'{{{NS}}}version')) > int(build) for item in items):
        raise RuntimeError('Cannot publish an older build as the latest release')
    prefix = f'https://github.com/{REPO}/releases/download/v{version}/'
    item = matches[0]
    enclosures = [item.find('enclosure'), *item.findall(f'{{{NS}}}deltas/enclosure')]
    assets = []
    for index, enclosure in enumerate(enclosures):
        if enclosure is None:
            raise RuntimeError('Update entry has no full archive')
        name = f'QuickGoogleTranslate-{version}.zip' if index == 0 else (
            f'QuickGoogleTranslate-{build}-{enclosure.get(f"{{{NS}}}deltaFrom")}.delta'
        )
        if enclosure.get('url') != prefix + name or Path(name).name != name:
            raise RuntimeError('Update asset must point to this version release: ' + name)
        path = feed.parent / name
        if not path.is_file() or path.stat().st_size != int(enclosure.get('length', '-1')):
            raise RuntimeError('Missing or incorrect update asset: ' + name)
        signature = enclosure.get(f'{{{NS}}}edSignature')
        if not signature:
            raise RuntimeError('Unsigned update asset: ' + name)
        assets.append((path, signature))
    return assets


def publish(root, gh, sync_readme=False):
    info = plistlib.loads((root / 'Info.plist').read_bytes())
    version = str(info['CFBundleShortVersionString'])
    build = str(info['CFBundleVersion'])
    if not re.fullmatch(r'\d+(?:\.\d+)+', version) or not build.isdigit():
        raise RuntimeError('Expected a numeric release version and build number')
    tag = 'v' + version
    feed = root / 'dist/updates/appcast.xml'
    assets = release_assets(root, version, build)
    notes = root / 'Publication/RELEASE.md'
    if not notes.read_text().strip():
        raise RuntimeError('Release notes are empty')
    signer = str(root / 'Vendor/Sparkle/bin/sign_update')
    subprocess.run([signer, '--account', ACCOUNT, '--verify', str(feed)], check=True)
    for path, signature in assets:
        subprocess.run([signer, '--account', ACCOUNT, '--verify', str(path), signature], check=True)

    def call(*args):
        return subprocess.check_output([gh, *args], text=True).strip()

    def run(*args):
        subprocess.run([gh, *args], check=True)

    if call('api', 'user', '--jq', '.login') != 'Foolishgod':
        raise RuntimeError('Expected the repository owner GitHub account')
    metadata = json.loads(call('repo', 'view', REPO, '--json', 'visibility,defaultBranchRef'))
    if metadata['visibility'] != 'PUBLIC' or metadata['defaultBranchRef']['name'] != 'main':
        raise RuntimeError('Unexpected repository visibility or default branch')

    def put_file(path, content, message):
        previous = subprocess.run([gh, 'api', f'repos/{REPO}/contents/{path}'], capture_output=True, text=True)
        body = {'message': message, 'content': base64.b64encode(content).decode(), 'branch': 'main'}
        if previous.returncode == 0:
            old = json.loads(previous.stdout)
            if base64.b64decode(old['content']) == content:
                return
            body['sha'] = old['sha']
        elif '404' not in previous.stderr:
            raise RuntimeError('Cannot inspect repository file: ' + path)
        with tempfile.TemporaryDirectory(prefix='qgt-publish-') as temporary:
            request = Path(temporary) / 'request.json'
            request.write_text(json.dumps(body))
            call('api', '--method', 'PUT', f'repos/{REPO}/contents/{path}', '--input', str(request))

    existing = subprocess.run([gh, 'api', f'repos/{REPO}/releases/tags/{tag}'], capture_output=True, text=True)
    if existing.returncode != 0:
        if '404' not in existing.stderr:
            raise RuntimeError('Cannot inspect release: ' + tag)
        # Keep an incomplete upload off the public download page; a retry resumes the draft.
        run('release', 'create', tag, '--repo', REPO, '--title', '划词谷歌翻译 ' + version,
            '--notes-file', str(notes), '--draft', '--target', 'main')
        release = {'draft': True, 'assets': []}
    else:
        release = json.loads(existing.stdout)
    published = {asset['name']: asset for asset in release['assets']}
    missing = []
    # Check every existing asset before uploading anything. Never replace released bytes.
    for path, _ in assets:
        digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
        if path.name not in published:
            missing.append(path)
            continue
        asset = published[path.name]
        if asset.get('digest'):
            matches = asset['digest'] == digest
        else:
            with tempfile.TemporaryDirectory(prefix='qgt-asset-check-') as temporary:
                downloaded = Path(temporary) / path.name
                run('release', 'download', tag, '--repo', REPO, '--pattern', path.name, '--output', str(downloaded))
                matches = hashlib.sha256(downloaded.read_bytes()).hexdigest() == digest.removeprefix('sha256:')
        if not matches:
            raise RuntimeError('Released asset changed; increment version instead: ' + path.name)
    if missing and not release['draft']:
        raise RuntimeError('Published release is incomplete; use a new version instead')
    for path in missing:
        run('release', 'upload', tag, str(path), '--repo', REPO)
    if release['draft']:
        run('release', 'edit', tag, '--repo', REPO, '--notes-file', str(notes), '--draft=false', '--latest')
    # Announce the update only after all of its downloads are public.
    put_file('appcast.xml', feed.read_bytes(), 'Publish signed application update feed for ' + tag)
    if sync_readme:
        put_file('README.md', (root / 'Publication/README.md').read_bytes(), 'Synchronize application documentation')
    print(f'Published https://github.com/{REPO}/releases/tag/{tag}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('gh', nargs='?', default='gh', help='Path to GitHub CLI')
    parser.add_argument('--sync-readme', action='store_true')
    args = parser.parse_args()
    publish(Path(__file__).resolve().parent, args.gh, args.sync_readme)
