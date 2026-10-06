#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="dist/划词谷歌翻译.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" .build/module-cache
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path .build/module-cache Sources/main.swift Sources/KeyboardShortcut.swift Sources/TranslationLayout.swift Sources/TranslationService.swift Sources/AccessibilityPermission.swift Sources/ChromeBridge.swift Sources/BackgroundBrowser.swift Sources/AppMaintenance.swift -F Vendor/Sparkle -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$APP/Contents/MacOS/QuickGoogleTranslate" -framework AppKit -framework WebKit -framework Carbon -framework ApplicationServices -framework Security -framework Network
cp Info.plist "$APP/Contents/Info.plist"
cp BrowserTranslate.js "$APP/Contents/Resources/BrowserTranslate.js"
/usr/bin/ditto Vendor/Sparkle/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
cp Vendor/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
zsh ../QuickGoogleTranslateUninstaller/build.sh
/usr/bin/ditto ../QuickGoogleTranslateUninstaller/dist/划词谷歌翻译卸载工具.app "$APP/Contents/Resources/Uninstaller.app"
if [[ -d "$APP/Contents/Resources/ChromeExtension" ]]; then
    rm -r -- "$APP/Contents/Resources/ChromeExtension"
fi
python3 Signing/sign-app.py "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "dist/划词谷歌翻译.zip"
printf '构建完成：%s\n' "$PWD/$APP"
