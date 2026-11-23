#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --quiet --product Notify
swiftc -parse-as-library \
    -I .build/debug/Modules -I .build/checkouts/Yams/Sources/CYaml/include \
    Sources/NotifyApp/SessionTerminal.swift \
    Sources/NotifyApp/Store.swift Sources/NotifyApp/Views.swift Sources/NotifyApp/SteeringView.swift Sources/NotifyApp/WorkspaceView.swift Sources/NotifyApp/ResponseMarkdown.swift Sources/NotifyApp/AgentChatView.swift Sources/NotifyApp/AgentHierarchyView.swift Sources/NotifyApp/WorkOverview.swift Sources/NotifyApp/AgentPresenceView.swift Sources/NotifyApp/AgentSetupView.swift Sources/NotifyApp/MobileConnection.swift Sources/NotifyApp/MobileSettingsView.swift Sources/NotifyApp/AppDelegate.swift Tests/UI/ResponseRenderingChecks.swift Tests/UI/SessionReorderingChecks.swift Tests/UI/AgentPerformanceChecks.swift Tests/UI/main.swift \
    Tests/UI/SteeringRenderingChecks.swift Tests/UI/AttentionChecks.swift Tests/UI/PanelChecks.swift \
    Sources/NotifyApp/PanelModels.swift Sources/NotifyApp/PanelConnection.swift Sources/NotifyApp/PanelDashboardView.swift \
    .build/debug/NotifyCore.build/*.swift.o .build/debug/Yams.build/*.swift.o .build/debug/CYaml.build/src/*.o \
    Tests/UI/NotificationFocusChecks.swift Tests/UI/ClaudeNativeChecks.swift Tests/UI/IdleCleanupChecks.swift Sources/NotifyApp/IdleSubagentCleanupView.swift Sources/NotifyApp/InternetSettingsView.swift -o .build/NotifyUIChecks
.build/NotifyUIChecks "$@"
