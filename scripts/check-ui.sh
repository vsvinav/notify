#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --quiet --product Notify
swiftc -parse-as-library \
    -I .build/debug/Modules -I .build/checkouts/Yams/Sources/CYaml/include \
    Sources/NotifyApp/Store.swift Sources/NotifyApp/Views.swift Sources/NotifyApp/SteeringView.swift Sources/NotifyApp/WorkspaceView.swift Sources/NotifyApp/WorkOverview.swift Sources/NotifyApp/AgentPresenceView.swift Sources/NotifyApp/AppDelegate.swift Tests/UI/main.swift \
    .build/debug/NotifyCore.build/*.swift.o .build/debug/Yams.build/*.swift.o .build/debug/CYaml.build/src/*.o \
    -o .build/NotifyUIChecks
.build/NotifyUIChecks "$@"
