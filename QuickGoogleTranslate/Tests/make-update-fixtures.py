from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
output = root / '.build/update-fixtures'
output.mkdir(parents=True, exist_ok=True)
for name, build in [('base', '100'), ('target', '101')]:
    app = output / name / '划词谷歌翻译.app'
    if app.exists():
        shutil.rmtree(app)
    subprocess.run(['/usr/bin/ditto', str(root/'dist/划词谷歌翻译.app'), str(app)], check=True)
    info = app / 'Contents/Info.plist'
    data = plistlib.loads(info.read_bytes())
    data.update(CFBundleIdentifier='local.quickgoogletranslate.update-fixture', CFBundleVersion=build,
                CFBundleShortVersionString='1.5.fixture.'+build, SUEnableAutomaticChecks=False,
                NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
    info.write_bytes(plistlib.dumps(data))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(output/f'Fixture-{build}.zip')], check=True)
print('Prepared isolated signed app fixtures. No installed application was changed.')
