#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Notify.app"
if [[ ! -d "$ROOT/build/Notify.app" ]]; then
    printf '%s\n' "Build first: NOTIFY_MOBILE_SOURCE=/path/to/notify-mobile bash scripts/build.sh" >&2
    exit 1
fi
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
if [[ -e "$APP" ]]; then
    printf '%s\n' "$APP already exists. Move the old app aside before reinstalling." >&2
    exit 1
fi
if [[ -e "$HOME/.local/bin/notify" || -L "$HOME/.local/bin/notify" ]]; then
    printf '%s\n' "$HOME/.local/bin/notify already exists; not replacing it." >&2
    exit 1
fi
ditto "$ROOT/build/Notify.app" "$APP"
ln -s "$APP/Contents/Resources/bin/notify" "$HOME/.local/bin/notify"
printf 'Installed %s\nLauncher: %s\n' "$APP" "$HOME/.local/bin/notify"
printf '%s\n' 'If ~/.local/bin is not on PATH, add: export PATH="$HOME/.local/bin:$PATH"'
