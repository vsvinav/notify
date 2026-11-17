#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/crypto"
command -v cargo >/dev/null || { printf '%s\n' 'Rust 1.91+ is required to build the remote channel.' >&2; exit 1; }
mkdir -p "$ROOT/.build/remote-tmp" "$ROOT/.build/remote-swift-cache"
export TMPDIR="$ROOT/.build/remote-tmp"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  -module-cache-path "$ROOT/.build/remote-swift-cache" \
  -O -emit-library -module-name NotifyHardwareSigner \
  hardware/HardwareSigner.swift ../Sources/NotifyCore/RemoteIdentity.swift \
  -Xlinker -install_name -Xlinker @rpath/libNotifyHardwareSigner.dylib \
  -o hardware/libNotifyHardwareSigner.dylib
codesign --force --sign - --identifier dev.notify.hardware-signer hardware/libNotifyHardwareSigner.dylib
cargo build --locked --release --bin notify-channel
TARGET="${CARGO_TARGET_DIR:-$ROOT/crypto/target}"
cp hardware/libNotifyHardwareSigner.dylib "$TARGET/release/libNotifyHardwareSigner.dylib"
codesign --force --sign - --identifier dev.notify.remote-channel "$TARGET/release/notify-channel"
printf 'Remote channel built at %s/release/notify-channel\n' "$TARGET"
