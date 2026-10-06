"""Sign a bundle with the pinned personal identity; never fall back to ad hoc."""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import subprocess
import sys

folder = Path(__file__).resolve().parent
pin_file = folder / 'identity.json'
if not pin_file.exists():
    raise SystemExit('Personal signing identity not configured. Run the explicit Keychain setup first.')
pin = json.loads(pin_file.read_text())
certificate = (folder / 'certificate.der').read_bytes()
if hashlib.sha1(certificate).hexdigest().upper() != pin['sha1'] or hashlib.sha256(certificate).hexdigest().upper() != pin['sha256']:
    raise SystemExit('Public certificate does not match pinned identity')
app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
identifier = info['CFBundleIdentifier']
if identifier not in {'local.quickgoogletranslate.mac', 'local.quickgoogletranslate.uninstaller'} and not identifier.startswith('local.quickgoogletranslate.signing-test.'):
    raise SystemExit('Refusing to sign an unrelated bundle: ' + identifier)
if not re.fullmatch(r'[A-F0-9]{40}', pin['sha1']):
    raise SystemExit('Invalid certificate fingerprint')
requirement = f'identifier "{identifier}" and certificate leaf = H"{pin["sha1"]}"'
subprocess.run(['/usr/bin/codesign', '--force', '--sign', pin['sha1'], '--timestamp=none', '--requirements', '=designated => ' + requirement, str(app)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--test-requirement', '=' + requirement, str(app)], check=True)
details = subprocess.check_output(['/usr/bin/codesign', '--display', '-r', '-', str(app)], stderr=subprocess.STDOUT, text=True)
if 'cdhash' in details.lower() or pin['sha1'] not in details.upper() or 'identifier "' + identifier + '"' not in details:
    raise SystemExit('Signature does not provide the expected stable identity')
print('Signed with pinned personal identity: ' + identifier)
