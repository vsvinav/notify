#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBILE_SOURCE="${NOTIFY_MOBILE_SOURCE:?Set NOTIFY_MOBILE_SOURCE to your notify-mobile checkout}"
MOBILE_SOURCE="$(cd "$MOBILE_SOURCE" && pwd)"
cd "$ROOT/crypto"
command -v wasm-bindgen >/dev/null || { printf '%s\n' 'Install wasm-bindgen-cli 0.2.130 to rebuild browser channel assets.' >&2; exit 1; }
cargo build --locked --release --target wasm32-unknown-unknown --lib
TARGET="${CARGO_TARGET_DIR:-$ROOT/crypto/target}"
wasm-bindgen --target web --out-name channel \
  --out-dir "$MOBILE_SOURCE/public/remote-crypto" \
  "$TARGET/wasm32-unknown-unknown/release/notify_channel.wasm"
