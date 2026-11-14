#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --quiet --product Notify
(cd bridge && npm run build)
APP="$ROOT/build/Notify.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/bridge"
cp .build/release/Notify "$APP/Contents/MacOS/Notify"
cp resources/Info.plist "$APP/Contents/Info.plist"
swift scripts/generate-icon.swift "$ROOT/build/Notify.iconset"
iconutil -c icns -o "$APP/Contents/Resources/Notify.icns" "$ROOT/build/Notify.iconset"
install -m 644 .build/checkouts/Yams/LICENSE "$APP/Contents/Resources/Yams-LICENSE"
cp bin/notify "$APP/Contents/Resources/bin/notify"
chmod +x "$APP/Contents/Resources/bin/notify"
cp bridge/package.json "$APP/Contents/Resources/bridge/package.json"
ditto bridge/dist "$APP/Contents/Resources/bridge/dist"
/usr/bin/rsync -a --delete --delete-excluded \
    --exclude=/.bin --exclude=/typescript --exclude=/@types --exclude=/@img \
    --exclude='/@github/copilot-sdk-*' \
    bridge/node_modules/ "$APP/Contents/Resources/bridge/node_modules/"
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
