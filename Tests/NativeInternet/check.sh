#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export NODE_TLS_REJECT_UNAUTHORIZED=1
mkdir -p .build/internet-home .build/internet-tmp .build/internet-cache
export HOME="$PWD/.build/internet-home"
export CFFIXED_USER_HOME="$HOME" TMPDIR="$PWD/.build/internet-tmp"
export COPILOT_HOME="$HOME/.copilot" CLAUDE_CONFIG_DIR="$HOME/.claude"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/internet-cache/clang" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/internet-cache/swift"
swift build --disable-automatic-resolution --cache-path .build/internet-cache --config-path .build/internet-config \
    --security-path .build/internet-security --quiet --product Notify
sources=()
for source in Sources/NotifyApp/*.swift; do
    [[ "$source" == Sources/NotifyApp/main.swift ]] || sources+=("$source")
done
swiftc -parse-as-library \
    -I .build/debug/Modules -I .build/checkouts/Yams/Sources/CYaml/include \
    "${sources[@]}" Tests/NativeInternet/main.swift \
    .build/debug/NotifyCore.build/*.swift.o .build/debug/Yams.build/*.swift.o .build/debug/CYaml.build/src/*.o \
    -o .build/NotifyInternetChecks
.build/NotifyInternetChecks
