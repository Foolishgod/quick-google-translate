#!/bin/zsh
set -eu
cd "${0:A:h}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)
APP="dist/划词谷歌翻译.app"
mkdir -p dist/updates
codesign --verify --deep --strict "$APP"
# App-only archives preserve signatures and can be installed directly by Sparkle.
/usr/bin/ditto -c -k --keepParent "$APP" "dist/updates/QuickGoogleTranslate-${VERSION}.zip"
cp "dist/updates/QuickGoogleTranslate-${VERSION}.zip" "dist/划词谷歌翻译-${VERSION}.zip"
# Preserve published entries before Sparkle regenerates archive URLs.
PREVIOUS_FEED=$(mktemp -t qgt-previous-appcast)
trap 'rm -f "$PREVIOUS_FEED"' EXIT
if [[ -f dist/updates/appcast.xml ]]; then
    cp dist/updates/appcast.xml "$PREVIOUS_FEED"
fi
# Recreate this release's entry if a pre-publication build was regenerated.
python3 - <<'PY'
from pathlib import Path
import plistlib, xml.etree.ElementTree as ET
path=Path('dist/updates/appcast.xml')
if path.exists():
    ns='http://www.andymatuschak.org/xml-namespaces/sparkle'
    ET.register_namespace('sparkle',ns)
    text=path.read_text()
    if 'xmlns:sparkle=' not in text:
        text=text.replace('<rss ', '<rss xmlns:sparkle="'+ns+'" ', 1)
    tree=ET.ElementTree(ET.fromstring(text)); channel=tree.find('channel')
    build=plistlib.loads(Path('Info.plist').read_bytes())['CFBundleVersion']
    for item in list(channel):
        if item.tag=='item' and item.findtext('{'+ns+'}version')==build: channel.remove(item)
    if not any(element.tag.startswith('{'+ns+'}') for element in tree.iter()):
        tree.getroot().set('xmlns:sparkle',ns)
    tree.write(path,encoding='utf-8',xml_declaration=True)
PY
Vendor/Sparkle/bin/generate_appcast --account local.quickgoogletranslate.mac.updates --versions "$BUILD" --download-url-prefix "https://github.com/Foolishgod/quick-google-translate/releases/download/v${VERSION}/" --link https://github.com/Foolishgod/quick-google-translate --embed-release-notes --maximum-deltas 0 --maximum-versions 5 dist/updates
python3 append-deltas.py "$PREVIOUS_FEED"
Vendor/Sparkle/bin/sign_update --account local.quickgoogletranslate.mac.updates --verify dist/updates/appcast.xml
printf '发布包与已签名更新源已准备：%s/dist/updates\n' "$PWD"
