"""Download the pinned official Sparkle distribution without committing binaries."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent
version = '2.10.0'
url = f'https://github.com/sparkle-project/Sparkle/releases/download/{version}/Sparkle-{version}.tar.xz'
expected = 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c'
vendor = root / 'Vendor'
destination = vendor / 'Sparkle'
if destination.exists():
    raise SystemExit('Vendor/Sparkle already exists. Existing dependencies were left in place.')
vendor.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(dir=vendor, prefix='sparkle-download-') as temporary:
    stage = Path(temporary)
    archive = stage / 'Sparkle.tar.xz'
    subprocess.run(['/usr/bin/curl', '--fail', '--show-error', '--location', '--proto', '=https', '--tlsv1.2', '--max-time', '180', url, '--output', str(archive)], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise SystemExit('Sparkle SHA256 mismatch; dependency was not installed.')
    unpacked = stage / 'unpacked'; unpacked.mkdir()
    subprocess.run(['/usr/bin/tar', '-xf', str(archive), '-C', str(unpacked)], check=True)
    assert (unpacked / 'Sparkle.framework').is_dir() and (unpacked / 'bin/generate_appcast').is_file() and (unpacked / 'LICENSE').is_file()
    shutil.move(str(unpacked), str(destination))
print('Installed verified official Sparkle ' + version)
