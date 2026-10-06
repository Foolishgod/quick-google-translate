"""Validate cross-version identity without granting or modifying TCC permissions."""
from pathlib import Path
import json
import plistlib
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
signer = root / 'Signing/sign-app.py'
pin = json.loads((root / 'Signing/identity.json').read_text())
identifier = 'local.quickgoogletranslate.signing-test.identity'
cache = root / '.build/module-cache'

def call(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True)

def rejection(*args):
    return subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0

with tempfile.TemporaryDirectory(dir=root / '.build', prefix='identity-checks-') as temporary:
    folder = Path(temporary)
    apps = []
    for version in [1, 2]:
        app = folder / f'v{version}/Probe.app'
        binary = app / 'Contents/MacOS/Probe'
        binary.parent.mkdir(parents=True)
        source = folder / f'v{version}.swift'
        source.write_text(f'import Foundation\nprint("Signing regression version {version}")\n')
        call('swiftc', '-module-cache-path', str(cache), str(source), '-o', str(binary))
        info = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(version), 'CFBundleShortVersionString': f'1.0.{version}'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        call('python3', str(signer), str(app))
        apps.append(app)
    def requirement(app):
        return call('/usr/bin/codesign', '--display', '-r', '-', str(app)).split('designated => ', 1)[1].strip()
    def hash_of(app):
        return re.search(r'^CDHash=(.+)$', call('/usr/bin/codesign', '--display', '--verbose=4', str(app)), re.M)[1]
    assert hash_of(apps[0]) != hash_of(apps[1]), 'Different executable code must have different CDHashes'
    assert requirement(apps[0]) == requirement(apps[1]), 'Designated requirements must stay stable'
    assert pin['sha1'].lower() in requirement(apps[0]).lower() and 'cdhash' not in requirement(apps[0]).lower()
    for a, b in [(0, 1), (1, 0)]:
        call('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '=' + requirement(apps[a]), str(apps[b]))
    print('PASS: two distinct executable versions mutually satisfy the pinned certificate identity', flush=True)
    # An ad-hoc build with the same bundle identifier must not impersonate the app.
    impostor = folder / 'Impostor.app'
    shutil.copytree(apps[0], impostor)
    call('/usr/bin/codesign', '--force', '--sign', '-', '--requirements', '=designated => identifier "' + identifier + '"', str(impostor))
    assert rejection('/usr/bin/codesign', '--verify', '-R', '=' + requirement(apps[0]), str(impostor))
    print('PASS: same bundle identifier with a different signer is rejected', flush=True)
    damaged = folder / 'Damaged.app'
    shutil.copytree(apps[0], damaged)
    info_path = damaged / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes()); info['CFBundleVersion'] = '999'
    info_path.write_bytes(plistlib.dumps(info))
    assert rejection('/usr/bin/codesign', '--verify', '--strict', str(damaged))
    print('PASS: unsigned bundle metadata changes invalidate the signature', flush=True)
    # Missing or changed configuration must never silently revert to ad-hoc signing.
    setup = folder / 'missing-signing'; setup.mkdir()
    shutil.copyfile(signer, setup / 'sign-app.py')
    assert rejection('python3', str(setup / 'sign-app.py'), str(apps[0]))
    shutil.copyfile(root / 'Signing/certificate.der', setup / 'certificate.der')
    wrong_pin = dict(pin); wrong_pin['sha1'] = '0' * 40
    (setup / 'identity.json').write_text(json.dumps(wrong_pin))
    assert rejection('python3', str(setup / 'sign-app.py'), str(apps[0]))
    print('PASS: missing/mismatched signing configuration fails without fallback', flush=True)
print('All signing identity checks passed. Actual Accessibility permission persistence requires a grant and subsequent update on this Mac.')
