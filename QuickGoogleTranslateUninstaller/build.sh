#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="dist/划词谷歌翻译卸载工具.app"
mkdir -p "$APP/Contents/MacOS" .build/module-cache
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path .build/module-cache Sources/UninstallPlan.swift Sources/main.swift -o "$APP/Contents/MacOS/QuickGoogleTranslateUninstaller" -framework AppKit -framework Security
cp Info.plist "$APP/Contents/Info.plist"
python3 ../QuickGoogleTranslate/Signing/sign-app.py "$APP"
RELEASE="dist/划词谷歌翻译卸载工具-1.0"
mkdir -p "$RELEASE"
/usr/bin/ditto "$APP" "$RELEASE/划词谷歌翻译卸载工具.app"
cp README.md "$RELEASE/使用说明.md"
/usr/bin/ditto -c -k --keepParent "$RELEASE" "dist/划词谷歌翻译卸载工具-1.0.zip"
printf '构建完成：%s\n' "$PWD/$APP"
