"""Generate authenticated deltas, including the migration from ad-hoc to personal signing."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
FOLDER = ROOT / 'dist/updates'
TOOLS = ROOT / 'Vendor/Sparkle/bin'
ACCOUNT = 'local.quickgoogletranslate.mac.updates'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)
info = plistlib.loads((ROOT/'Info.plist').read_bytes())
build = info['CFBundleVersion']
app = ROOT/'dist/划词谷歌翻译.app'
feed = FOLDER/'appcast.xml'
tree = ET.parse(feed)
item = next(item for item in tree.findall('./channel/item') if item.findtext(f'{{{NS}}}version') == build)
archive = FOLDER / f"QuickGoogleTranslate-{info['CFBundleShortVersionString']}.zip"
for old_archive in sorted(FOLDER.glob('QuickGoogleTranslate-*.zip')):
    if old_archive == archive:
        continue
    with tempfile.TemporaryDirectory(prefix='qgt-release-delta-') as temporary:
        stage = Path(temporary)
        subprocess.run(['/usr/bin/ditto','-x','-k',str(old_archive),str(stage/'old')],check=True)
        old = stage/'old/划词谷歌翻译.app'
        old_info = plistlib.loads((old/'Contents/Info.plist').read_bytes())
        old_build = old_info['CFBundleVersion']
        if not str(old_build).isdigit() or int(old_build) >= int(build):
            continue
        # Only offer deltas to the same product with the same update trust key.
        if old_info.get('CFBundleIdentifier') != info['CFBundleIdentifier'] or old_info.get('SUPublicEDKey') != info['SUPublicEDKey']:
            continue
        delta = FOLDER/f'QuickGoogleTranslate-{build}-{old_build}.delta'
        subprocess.run([str(TOOLS/'BinaryDelta'),'create','--version=4',str(old),str(app),str(delta)],check=True)
        if delta.stat().st_size >= archive.stat().st_size:
            delta.unlink()
            continue
        patched = stage/'patched.app'
        subprocess.run([str(TOOLS/'BinaryDelta'),'apply',str(old),str(patched),str(delta)],check=True)
        subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(patched)],check=True)
        signature = subprocess.check_output([str(TOOLS/'sign_update'),'--account',ACCOUNT,'-p',str(delta)],text=True).strip()
        subprocess.run([str(TOOLS/'sign_update'),'--account',ACCOUNT,'--verify',str(delta),signature],check=True)
        deltas = item.find(f'{{{NS}}}deltas')
        if deltas is None:
            deltas = ET.SubElement(item,f'{{{NS}}}deltas')
        for previous in list(deltas):
            if previous.get(f'{{{NS}}}deltaFrom') == old_build:
                deltas.remove(previous)
        ET.SubElement(deltas,'enclosure',{'url':'https://github.com/Foolishgod/quick-google-translate/releases/download/updates/'+delta.name,
            'length':str(delta.stat().st_size),'type':'application/octet-stream',f'{{{NS}}}deltaFrom':old_build,f'{{{NS}}}edSignature':signature})
        print(f'Verified signed delta {old_build} → {build}: {delta.stat().st_size} bytes')
tree.write(feed,encoding='utf-8',xml_declaration=True)
subprocess.run([str(TOOLS/'sign_update'),'--account',ACCOUNT,'-p',str(feed)],check=True)
subprocess.run([str(TOOLS/'sign_update'),'--account',ACCOUNT,'--verify',str(feed)],check=True)
