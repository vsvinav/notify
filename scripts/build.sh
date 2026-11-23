#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export NODE_TLS_REJECT_UNAUTHORIZED=1
MOBILE_SOURCE="${NOTIFY_MOBILE_SOURCE:?Set NOTIFY_MOBILE_SOURCE to your notify-mobile checkout}"
for file in src/main.mjs src/remote-main.mjs src/panel-main.mjs public/index.html public/remote-crypto/channel.js public/remote-crypto/channel_bg.wasm public/remote-crypto/LICENSES.txt package.json package-lock.json; do
    if [ ! -f "$MOBILE_SOURCE/$file" ]; then
        printf 'Missing mobile companion file: %s/%s\n' "$MOBILE_SOURCE" "$file" >&2
        exit 1
    fi
done
MOBILE_SOURCE="$(cd "$MOBILE_SOURCE" && pwd)"
bash scripts/build-remote-crypto.sh
swift build -c release --quiet --product Notify \
    -Xswiftc -file-prefix-map -Xswiftc "$HOME=/build" \
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/build" \
    -Xcc "-ffile-prefix-map=$HOME=/build"
(cd bridge && npm run build)
APP="$ROOT/build/Notify.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/bridge"
mkdir -p "$APP/Contents/Resources/remote-crypto"
CRYPTO_TARGET="${CARGO_TARGET_DIR:-$ROOT/crypto/target}"
install -m 755 "$CRYPTO_TARGET/release/notify-channel" "$APP/Contents/Resources/remote-crypto/notify-channel"
install -m 755 "$CRYPTO_TARGET/release/libNotifyHardwareSigner.dylib" "$APP/Contents/Resources/remote-crypto/libNotifyHardwareSigner.dylib"
install -m 644 crypto/THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/remote-crypto/LICENSES.txt"
cp .build/release/Notify "$APP/Contents/MacOS/Notify"
strip -S "$APP/Contents/MacOS/Notify"
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
MOBILE="$APP/Contents/Resources/mobile"
INSTALL_MOBILE_DEPS=0
if ! cmp -s "$MOBILE_SOURCE/package.json" "$MOBILE/package.json" ||
   ! cmp -s "$MOBILE_SOURCE/package-lock.json" "$MOBILE/package-lock.json" ||
   [ ! -d "$MOBILE/node_modules" ]; then
    INSTALL_MOBILE_DEPS=1
fi
mkdir -p "$MOBILE/src" "$MOBILE/public"
/usr/bin/rsync -a --delete "$MOBILE_SOURCE/src/" "$MOBILE/src/"
/usr/bin/rsync -a --delete "$MOBILE_SOURCE/public/" "$MOBILE/public/"
install -m 644 "$MOBILE_SOURCE/package.json" "$MOBILE_SOURCE/package-lock.json" "$MOBILE/"
if [ "$INSTALL_MOBILE_DEPS" = 1 ] || ! (cd "$MOBILE" && npm ls --omit=dev --silent >/dev/null 2>&1); then
    (cd "$MOBILE" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
fi
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
