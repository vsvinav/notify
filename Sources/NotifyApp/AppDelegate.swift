import AppKit
import SwiftUI
import Combine
import Carbon

final class NotificationKeyPriority {
    private static let keys = [UInt32(kVK_Return), UInt32(kVK_ANSI_KeypadEnter), UInt32(kVK_UpArrow), UInt32(kVK_DownArrow)]
    private var handler: EventHandlerRef?
    private var hotkeys: [EventHotKeyRef] = []
    private var heldKeys = Set<UInt32>()
    private var enabled = false
    private let action: (UInt32) -> Void
    private let report: (String) -> Void

    init(action: @escaping (UInt32) -> Void, report: @escaping (String) -> Void) {
        self.action = action
        self.report = report
    }

    func setEnabled(_ value: Bool) throws {
        enabled = value
        if !value {
            if heldKeys.isEmpty { unregister() }
            return
        }
        guard hotkeys.isEmpty else { return }
        if handler == nil {
            var events = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            try check(InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return Unmanaged<NotificationKeyPriority>.fromOpaque(context).takeUnretainedValue().receive(event)
            }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler))
        }
        for key in Self.keys {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(key, 0, EventHotKeyID(signature: 0x4e745274, id: key),
                                             GetApplicationEventTarget(), 0, &reference)
            if result != noErr {
                enabled = false
                unregister()
                try check(result)
            }
            if let reference { hotkeys.append(reference) }
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key)) { heldKeys.insert(key) }
        }
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var identity = EventHotKeyID()
        guard !hotkeys.isEmpty,
              GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
              identity.signature == 0x4e745274,
              Self.keys.contains(identity.id) else {
            return OSStatus(eventNotHandledErr)
        }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            heldKeys.remove(identity.id)
            if !enabled && heldKeys.isEmpty { unregister() }
        } else {
            let freshPress = heldKeys.insert(identity.id).inserted
            let otherReturn = identity.id == UInt32(kVK_Return) ? UInt32(kVK_ANSI_KeypadEnter) : UInt32(kVK_Return)
            let isReturn = identity.id == UInt32(kVK_Return) || identity.id == UInt32(kVK_ANSI_KeypadEnter)
            if enabled && freshPress && (!isReturn || !heldKeys.contains(otherReturn)) { action(identity.id) }
        }
        return noErr
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private func unregister() {
        for reference in hotkeys {
            let status = UnregisterEventHotKey(reference)
            if status != noErr { report("Could not release Return priority (macOS error \(status)). Quit Notify to release it.") }
        }
        hotkeys.removeAll()
        heldKeys.removeAll()
    }
    func stop() {
        enabled = false
        heldKeys.removeAll()
        unregister()
        if let handler {
            let status = RemoveEventHandler(handler)
            if status != noErr { report("Could not remove Return handler (macOS error \(status)).") }
        }
        handler = nil
    }
    deinit { stop() }
}

final class ReplyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: Store
    private let backgroundLaunch: Bool
    private var center: NSWindow!
    private var panel: ReplyPanel!
    private var status: NSStatusItem!
    private var observations = Set<AnyCancellable>()
    private lazy var returnPriority = NotificationKeyPriority(action: { [weak self] key in
        guard let self, self.canUseReplyKeys, let item = self.store.activeFloatingRequest else { return }
        if key == UInt32(kVK_UpArrow) || key == UInt32(kVK_DownArrow) {
            self.store.replyWorkspace.moveChoice(key == UInt32(kVK_UpArrow) ? -1 : 1, for: item.request)
        } else if let questionID = self.store.activateReplyChoice() {
            self.focusAnswerInput(requestID: item.request.id, questionID: questionID)
        }
    }, report: { [weak self] message in self?.store.error = message })

    init(store: Store = Store(), backgroundLaunch: Bool = CommandLine.arguments.contains("--background")) {
        self.store = store
        self.backgroundLaunch = backgroundLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Notify", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        center = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        center.title = "Notify"
        center.titleVisibility = .hidden
        center.titlebarAppearsTransparent = true
        center.backgroundColor = NSColor(Palette.surface)
        center.contentMinSize = NSSize(width: 960, height: 620)
        center.isReleasedWhenClosed = false
        center.delegate = self
        let centerHost = NSHostingView(rootView: DashboardView(store: store))
        centerHost.sizingOptions = []
        center.contentView = centerHost
        center.center()

        panel = ReplyPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 550), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        let floatingHost = NSHostingView(rootView: FloatingView(store: store, openCenter: { [weak self] in self?.openCenter() }))
        floatingHost.sizingOptions = []
        panel.contentView = floatingHost

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "bolt.badge.clock", accessibilityDescription: "Notify")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Control Center", action: #selector(openCenter), keyEquivalent: "")
        menu.addItem(withTitle: "Show Waiting Requests", action: #selector(showWaiting), keyEquivalent: "")
        menu.addItem(withTitle: "Steer an Agent", action: #selector(showSteering), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Notify", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status.menu = menu
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                self?.updateReturnPriority()
            }.store(in: &observations)
        }
        store.$replyWorkspace.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateReturnPriority()
        }.store(in: &observations)
        store.onAttentionChange = { [weak self] in self?.updateAttention() }
        store.start()
        updateAttention()
        if !backgroundLaunch { openCenter() }
    }
    @objc func openCenter() {
        NSApp.activate()
        center.makeKeyAndOrderFront(nil)
        store.centerVisible = center.isVisible && center.occlusionState.contains(.visible)
    }
    @objc private func openSettings() { openCenter(); store.settingsVisible = true }
    @objc private func showWaiting() {
        if store.floatingRequests.isEmpty { openCenter(); store.waitingOnly = true }
        else { positionPanel(); panel.orderFrontRegardless() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showSteering() {
        if store.sessions.isEmpty { openCenter(); return }
        store.showSteering(nil)
    }

    private func positionPanel() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let height = min(store.floatingExpanded ? 760.0 : 560.0, frame.height - 40)
        let width = min(store.floatingExpanded ? 600.0 : 420.0, frame.width - 40)
        panel.setFrame(NSRect(x: frame.maxX - width - 20, y: frame.maxY - height - 18, width: width, height: height), display: true)
    }
    private func updateAttention() {
        defer { updateReturnPriority() }
        let requests = store.floatingRequests
        if panel.isVisible {
            let screen = panel.screen ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let height = min(store.floatingExpanded ? 760.0 : 560.0, frame.height - 40)
                let width = min(store.floatingExpanded ? 600.0 : 420.0, frame.width - 40)
                if panel.frame.size != NSSize(width: width, height: height) {
                    let x = max(frame.minX + 20, min(panel.frame.maxX - width, frame.maxX - width - 20))
                    let y = max(frame.minY + 20, min(panel.frame.maxY - height, frame.maxY - height - 20))
                    panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
                }
            }
        }
        store.replyWorkspace.update(requestIDs: requests.map { $0.request.id })
        let count = store.waitingCount
        status.button?.title = count == 0 ? "" : " \(count)"
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        let ids = Set(requests.map { $0.request.id })
        let new = ids.intersection(store.attentionIDs)
        store.attentionIDs.subtract(ids)
        if store.steeringSessionID != nil {
            if !panel.isVisible { positionPanel() }
            panel.orderFrontRegardless()
            return
        }
        guard store.floatingEnabled, !requests.isEmpty else {
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible { positionPanel(); panel.orderFrontRegardless() }
        if !new.isEmpty {
            if !panel.isVisible { positionPanel() }
            panel.orderFrontRegardless()
            if store.playSound { NSSound(named: "Pop")?.play() }
        }
    }
    private var canUseReplyKeys: Bool {
        guard panel?.isVisible == true, store.floatingEnabled, store.steeringSessionID == nil,
              !store.settingsVisible, store.floatingColorPickerSessionID == nil, let item = store.activeFloatingRequest,
              item.session.connected, !store.sending.contains(item.request.id) else { return false }
        if NSApp.isActive || panel.isKeyWindow,
           let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable { return false }
        return true
    }
    private func updateReturnPriority() {
        let editing = (NSApp.isActive || panel?.isKeyWindow == true) &&
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
        if store.editingReplyText != editing { store.editingReplyText = editing }
        do { try returnPriority.setEnabled(canUseReplyKeys) }
        catch {
            let message = "Notification keyboard controls are unavailable: \(error.localizedDescription). Use the request buttons."
            if store.error != message { store.error = message }
        }
    }
    private func focusAnswerInput(requestID: String, questionID: String) {
        panel.makeKeyAndOrderFront(nil)
        store.answerFocus = AnswerFocus(requestID: requestID, questionID: questionID)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === center else { return }
        store.centerVisible = window.isVisible && window.occlusionState.contains(.visible)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === center { store.centerVisible = false }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openCenter()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        observations.removeAll()
        returnPriority.stop()
        store.stop()
    }
}
