import AppKit
import SwiftUI
import NotifyCore
import Vision

enum SteeringRenderingChecks {
    @MainActor static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let suite = "notify-steering-rendering-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = URL(fileURLWithPath: ".build/" + suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try! FileManager.default.removeItem(at: root)
        }
        let store = Store(directory: root, defaults: defaults, mobileResources: nil)
        defer { store.stop() }
        func receive(_ value: [String: Any]) throws {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: value)))
        }
        try receive(["type": "hello", "sessionID": "fixture", "agent": "copilot", "cwd": "/Synthetic"])
        store.steeringWorkspace.setDraft("Preserve the current changes.", sessionID: "fixture")
        let output = URL(fileURLWithPath: ".build/steering-rendering-captures", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for supported in [false, true] {
            try receive(["type": "capabilities", "sessionID": "fixture", "steering": true, "steeringImmediate": supported])
            let session = store.registry.sessions["fixture"]!
            precondition(session.canSendImmediately == supported, "Native capability packets must reach the composer")
            for floating in [false, true] {
                for dark in [false, true] {
                    let width: CGFloat = floating ? 360 : 420
                    let content = floating
                        ? AnyView(SteeringEditor(store: store, session: session, floating: true, compact: true))
                        : AnyView(AgentChatView(store: store, session: session, agentID: nil))
                    let host = NSHostingView(rootView: content.padding(16)
                        .frame(width: width, height: 640, alignment: .topLeading)
                        .background(Palette.background).environment(\.colorScheme, dark ? .dark : .light))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
                    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    for _ in 0..<4 {
                        host.layoutSubtreeIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "\(floating ? "floating" : "chat")-\(supported ? "immediate" : "legacy")-\(dark ? "dark" : "light")"
                    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: bitmap.cgImage!, options: [:]).perform([request])
                    let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                    for label in ["Queue", "Interrupt", "Stop", supported ? "Send" : "Reload"] {
                        precondition(text.contains(label), "\(name) must visibly retain \(label)")
                    }
                }
            }
        }
        precondition(NSApp.windows.allSatisfy { !$0.isVisible }, "Steering fixtures must never show a window")
        print("Isolated offscreen Send/Queue controls visible in both themes, including legacy extensions; no live sessions used")
    }
}
