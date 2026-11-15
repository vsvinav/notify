import AppKit
import Carbon
import NotifyCore

enum NotificationFocusChecks {
    @MainActor static func run(previousApplication: NSRunningApplication?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notify-keyboard-" + UUID().uuidString)
        let suite = "notify-keyboard-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "hasSeenWelcome")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = Store(directory: directory, defaults: defaults)
        let delegate = AppDelegate(store: store, backgroundLaunch: true)
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) }
            catch { NSLog("Could not clean keyboard fixture: %@", error.localizedDescription) }
        }
        func pump() {
            for _ in 0..<10 {
                while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
        }
        NSApp.setActivationPolicy(.regular)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        for packet: [String: Any] in [
            ["type": "hello", "sessionID": "keyboard-fixture", "agent": "demo", "cwd": "/Projects/fixture"],
            ["type": "request", "sessionID": "keyboard-fixture", "request": [
                "id": "keyboard-request", "kind": "permission", "title": "Synthetic keyboard check",
                "detail": "", "autoEligible": false, "questions": [],
                "permissionOptions": [["id": "session", "label": "Always this session", "detail": "Synthetic only"]]
            ]]
        ] {
            store.server.onPacket(try JSONDecoder().decode(AgentPacket.self, from: JSONSerialization.data(withJSONObject: packet)))
        }
        delegate.openCenter()
        NSApp.activate(ignoringOtherApps: true)
        pump()
        let center = NSApp.windows.first { $0.title == "Notify" }!
        let confirmation = NSAlert()
        confirmation.messageText = "Synthetic subagent-management sheet"
        confirmation.addButton(withTitle: "Cancel")
        confirmation.beginSheetModal(for: center)
        pump()
        precondition(NSApp.isActive && center.attachedSheet != nil, "The fixture must have an active Notify sheet")
        func assertReleased() {
            for key in [UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter), UInt32(kVK_UpArrow), UInt32(kVK_DownArrow)] {
                var reference: EventHotKeyRef?
                precondition(RegisterEventHotKey(key, 0, EventHotKeyID(signature: 0x54657374, id: key),
                                                GetApplicationEventTarget(), 0, &reference) == noErr,
                             "Editing a foreground sheet must release notification keys")
                if let reference { precondition(UnregisterEventHotKey(reference) == noErr) }
            }
        }
        assertReleased()
        NSApp.deactivate()
        guard let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            preconditionFailure("Run the keyboard check from another foreground application")
        }
        precondition(previousApplication.activate(options: []),
                     "The previous application must regain focus for the background-sheet check")
        pump()
        precondition(!NSApp.isActive && center.attachedSheet != nil,
                     "The background-sheet regression must preserve the open sheet while another app owns focus")
        func send(_ key: UInt32) {
            for kind in [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)] {
                var event: EventRef?
                precondition(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event) == noErr)
                defer { if let event { ReleaseEvent(event) } }
                var identity = EventHotKeyID(signature: 0x4e745274, id: key)
                precondition(SetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                              MemoryLayout<EventHotKeyID>.size, &identity) == noErr)
                precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr,
                             "A background Control Center sheet must not disable notification Return/arrows")
            }
        }
        send(UInt32(kVK_DownArrow))
        send(UInt32(kVK_Return))
        precondition(store.audit.first?.action == "Requested: Always this session - Synthetic only",
                     "Background-sheet arrows and Return must activate the selected synthetic choice")
        send(UInt32(kVK_UpArrow))
        store.requestErrors.removeValue(forKey: "keyboard-request")
        send(UInt32(kVK_ANSI_KeypadEnter))
        precondition(store.requestErrors["keyboard-request"] != nil,
                     "Keypad Enter must also reach the synthetic reply path")
        NSApp.activate(ignoringOtherApps: true)
        confirmation.window.makeKeyAndOrderFront(nil)
        pump()
        precondition(NSApp.isActive, "The sheet must regain foreground ownership")
        assertReleased()
        center.endSheet(confirmation.window)
        confirmation.window.orderOut(nil)
        center.close()
        print("Notification focus checks passed: background sheets, arrows, Return/keypad, foreground safety.")
    }
}
