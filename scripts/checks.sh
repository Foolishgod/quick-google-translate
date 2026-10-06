#!/bin/zsh
set -eu
cd "${0:A:h:h}"
MODULE="QuickGoogleTranslate"
mkdir -p "$MODULE/.build/module-cache" QuickGoogleTranslateUninstaller/.build/module-cache
COMMON=("$MODULE/Sources/TranslationLayout.swift" "$MODULE/Sources/TranslationService.swift" "$MODULE/Sources/ChromeBridge.swift" "$MODULE/Sources/BackgroundBrowser.swift")
FRAMEWORKS=(-framework AppKit -framework WebKit -framework ApplicationServices -framework Security -framework Network)
swiftc -swift-version 5 -O -module-cache-path "$MODULE/.build/module-cache" "${COMMON[@]}" "$MODULE/Sources/AccessibilityPermission.swift" "$MODULE/Tests/main.swift" "${FRAMEWORKS[@]}" -o "$MODULE/.build/source-core-checks"
"$MODULE/.build/source-core-checks"
if [[ "${1:-}" == "--native" || "${1:-}" == "--chrome" ]]; then
    swiftc -swift-version 5 -O -module-cache-path "$MODULE/.build/module-cache" "${COMMON[@]}" "$MODULE/Tests/Formatting/main.swift" "${FRAMEWORKS[@]}" -o "$MODULE/.build/source-formatting-checks"
    "$MODULE/.build/source-formatting-checks"
fi
swiftc -swift-version 5 -O -module-cache-path QuickGoogleTranslateUninstaller/.build/module-cache QuickGoogleTranslateUninstaller/Sources/UninstallPlan.swift QuickGoogleTranslateUninstaller/Tests/main.swift -framework AppKit -framework Security -o QuickGoogleTranslateUninstaller/.build/source-uninstall-checks
QuickGoogleTranslateUninstaller/.build/source-uninstall-checks
if command -v node >/dev/null 2>&1; then
    node "$MODULE/Tests/browser-page-checks.cjs"
    node "$MODULE/Tests/chrome-extension-checks.cjs"
else
    print 'Node.js is unavailable; page fixtures skipped. Install Node.js to run them.'
fi
if [[ "${1:-}" == "--native" ]]; then
    command -v node >/dev/null 2>&1 || { print 'Native browser fixtures require Node.js and npm ci.'; exit 1; }
    node -e 'require("ws")'
    swiftc -swift-version 5 -O -module-cache-path "$MODULE/.build/module-cache" "$MODULE/Sources/KeyboardShortcut.swift" "$MODULE/Tests/Shortcuts/main.swift" -framework AppKit -framework Carbon -o "$MODULE/.build/source-shortcut-checks"
    "$MODULE/.build/source-shortcut-checks"
    python3 "$MODULE/Tests/Signing/verify-identities.py"
    cp "$MODULE/BrowserTranslate.js" "$MODULE/.build/BrowserTranslate.js"
    NODE_EXECUTABLE=$(command -v node)
    python3 - "$NODE_EXECUTABLE" <<'PY'
from pathlib import Path
import shlex
import sys
root = Path.cwd()
shim = root / 'QuickGoogleTranslate/.build/browser-fixture'
script = root / 'QuickGoogleTranslate/Tests/Browser/fixture.cjs'
shim.write_text('#!/bin/sh\nexec ' + shlex.quote(sys.argv[1]) + ' ' + shlex.quote(str(script)) + ' "$@"\n')
shim.chmod(0o755)
PY
    swiftc -swift-version 5 -O -module-cache-path "$MODULE/.build/module-cache" "${COMMON[@]}" "$MODULE/Tests/Browser/main.swift" "${FRAMEWORKS[@]}" -o "$MODULE/.build/source-browser-checks"
    "$MODULE/.build/source-browser-checks"
fi
if [[ "${1:-}" == "--chrome" ]]; then
    command -v node >/dev/null 2>&1 || { print 'Chrome DOM checks require Node.js and npm ci.'; exit 1; }
    node "$MODULE/Tests/Browser/dom-checks.cjs"
fi
print 'Source checks finished.'
