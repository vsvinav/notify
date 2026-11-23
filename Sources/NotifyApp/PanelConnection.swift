import AppKit
import Combine
import Foundation
import NotifyCore
import Darwin

final class PanelConnection: ObservableObject {
    typealias Executor = (Data, TimeInterval, @escaping (Result<Data, Error>) -> Void) -> (() -> Void)
    @Published private(set) var enabled: Bool
    @Published private(set) var visible = false
    @Published private(set) var feed: PanelFeed?
    @Published private(set) var busy = false
    @Published private(set) var confirmation: PanelConfirmation?
    @Published private(set) var receipt: PanelReceipt?
    @Published private(set) var error: String?
    @Published private(set) var reason: String?
    @Published private(set) var selectedTabID: String?
    @Published var selectedItemKey: String? {
        didSet { if oldValue != selectedItemKey { consumePreview() } }
    }
    @Published private var drafts: [DraftKey: String] = [:]
    @Published private var freshAt: TimeInterval?
    private struct DraftKey: Hashable { let tab: String; let action: String }
    private let defaults: UserDefaults
    private let directory: URL
    private let executor: Executor
    private let clock: () -> TimeInterval
    private var generation: UInt64 = 0
    private var cancel: (() -> Void)?
    private var activeExecution: UUID?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var nextRead: TimeInterval = 0
    private var stopped = false
    private var sleeping = false
    private var sending = false
    private var receiptInvalid = false
    var onEnabledChange: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard, resources: URL? = Bundle.main.resourceURL, directory: URL,
         executor: Executor? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults; self.directory = directory; self.clock = clock
        enabled = defaults.bool(forKey: "panelEnabled")
        self.executor = executor ?? { data, timeout, done in
            PanelProcess.run(resources: resources, input: data, timeout: timeout, completion: done)
        }
        loadReceipt()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(true) })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setSleeping(false) })
    }
    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    var selectedTab: PanelTab? { feed?.tabs.first { $0.id == selectedTabID } ?? feed?.tabs.first }
    var selectedItem: PanelLocatedItem? {
        selectedTab?.items.first { $0.key == selectedItemKey } ?? selectedTab?.items.first
    }
    var isFresh: Bool {
        guard enabled, visible, !sleeping, !stopped, let freshAt else { return false }
        return clock() >= freshAt && clock() - freshAt < 30
    }
    var actionsAllowed: Bool { isFresh && !busy && !receiptInvalid && receipt?.delivery != .unknown && receipt?.delivery != .sending }
    var canAcknowledgeUnknown: Bool { !busy && !receiptInvalid && receipt?.delivery == .unknown }
    var canSend: Bool {
        guard actionsAllowed, let confirmation else { return false }
        return confirmation.generation == generation && confirmation.tabID == selectedTab?.id &&
            (confirmation.text == nil || draft(tabID: confirmation.tabID, actionID: confirmation.actionID) == confirmation.text)
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; defaults.set(value, forKey: "panelEnabled")
        invalidate()
        onEnabledChange?(value)
        updatePolling()
    }
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value; invalidate(); updatePolling()
    }
    func setSleeping(_ value: Bool) {
        sleeping = value; invalidate(); updatePolling()
    }
    func selectTab(_ id: String) {
        guard selectedTabID != id, feed?.tabs.contains(where: { $0.id == id }) == true else { return }
        consumePreview(); selectedTabID = id; selectedItemKey = nil
    }
    func draft(tabID: String, actionID: String) -> String { drafts[DraftKey(tab: tabID, action: actionID)] ?? "" }
    func setDraft(_ value: String, tabID: String, actionID: String) {
        guard draft(tabID: tabID, actionID: actionID) != value else { return }
        drafts[DraftKey(tab: tabID, action: actionID)] = value
        consumePreview()
    }
    private func consumePreview() { generation &+= 1; confirmation = nil }
    private func invalidate() {
        consumePreview(); freshAt = nil
        if !sending { cancel?() }
    }
    private func updatePolling() {
        timer?.invalidate(); timer = nil
        guard enabled, visible, !sleeping, !stopped else { return }
        nextRead = clock()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        refresh()
    }
    func tick() {
        guard enabled, visible, !sleeping, !stopped else { return }
        if confirmation != nil && !isFresh { consumePreview() }
        if !busy && confirmation == nil && clock() >= nextRead { refresh() }
    }
    func refresh() {
        guard enabled, visible, !sleeping, !stopped, !busy, confirmation == nil else { return }
        consumePreview(); freshAt = nil
        let current = generation
        execute(["type": "read"], timeout: 6) { [weak self] result in
            guard let self, current == self.generation, self.enabled, self.visible, !self.sleeping, !self.stopped else { return }
            switch result {
            case .success(let response):
                if response.successful, response.data.available == true, let feed = response.data.panel,
                   feed.version == 1, feed.tabs.count <= 6 {
                    self.feed = feed; self.freshAt = self.clock(); self.reason = nil
                    if !feed.tabs.contains(where: { $0.id == self.selectedTabID }) {
                        self.selectedTabID = feed.tabs.first?.id; self.selectedItemKey = nil
                    }
                    if !self.receiptInvalid { self.error = nil }
                } else { self.reason = response.data.reason ?? "Dashboard provider is unavailable." }
            case .failure: self.reason = "Could not read the Dashboard provider. Try refreshing."
            }
            self.nextRead = self.clock() + (self.isFresh ? 15 : 60)
        }
    }
    func preview(actionID: String, text: String? = nil) {
        consumePreview()
        guard actionsAllowed, let tab = selectedTab else { error = "Refresh the Dashboard before previewing an action."; return }
        let actions = tab.items.flatMap { $0.item.actions }.filter { $0.id == actionID }
        let isForm = tab.form?.actionId == actionID
        guard actions.count + (isForm ? 1 : 0) == 1 else { error = "This action is no longer uniquely available. Refresh the Dashboard."; return }
        if isForm {
            guard let text, let form = tab.form, form.accepts(text),
                  draft(tabID: tab.id, actionID: actionID) == text else {
                error = "Enter \(tab.form?.minLength ?? 1)–\(tab.form?.maxLength ?? 300) UTF-16 characters before previewing."; return
            }
        } else if text != nil { error = "This action does not accept text."; return }
        error = nil
        let current = generation
        var input: [String: Any] = ["actionId": actionID, "preview": true]
        if let text { input["text"] = text }
        execute(["type": "action", "input": input], timeout: 15) { [weak self] result in
            guard let self, current == self.generation, self.isFresh else { return }
            guard case .success(let response) = result, response.successful, response.data.ok == true,
                  response.data.demo != true, let message = response.data.confirm, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.utf16.count <= 1000, let token = response.data.confirmationToken,
                  token.utf8.count == 43,
                  token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
                self.error = "Preview did not authorize sending. Nothing was sent."; return
            }
            self.confirmation = PanelConfirmation(actionID: actionID, tabID: tab.id, text: text,
                label: String((response.data.label ?? (isForm ? tab.form?.submitLabel : actions.first?.label) ?? "Action").prefix(1000)),
                message: message, token: token, generation: current)
        }
    }
    func cancelPreview() { consumePreview() }
    func sendPreview() {
        guard canSend, let snapshot = confirmation else { consumePreview(); return }
        consumePreview()
        let pending = PanelReceipt(id: UUID(), createdAt: Date(), delivery: .sending)
        do { try saveReceipt(pending); receipt = pending }
        catch { receiptInvalid = true; self.error = "Could not save the action receipt. Nothing was sent."; return }
        sending = true
        var input: [String: Any] = ["actionId": snapshot.actionID, "preview": false, "confirmationToken": snapshot.token]
        if let text = snapshot.text { input["text"] = text }
        execute(["type": "action", "input": input], timeout: 15) { [weak self] result in
            guard let self else { return }
            self.sending = false
            var final = pending
            if case .success(let response) = result, response.successful, response.data.ok == true,
               response.data.sent == true, response.data.demo != true { final.delivery = .accepted }
            else { final.delivery = .unknown }
            self.receipt = final
            do { try self.saveReceipt(final) }
            catch {
                final.delivery = .unknown; self.receipt = final; self.receiptInvalid = true
                self.error = "Could not update the action receipt. Delivery is unknown. Check the destination and repair the receipt file before continuing."
            }
            self.freshAt = nil; self.nextRead = self.clock()
        }
    }
    func acknowledgeUnknown() {
        guard canAcknowledgeUnknown else { return }
        do {
            try FileManager.default.removeItem(at: receiptURL)
            receipt = nil; invalidate(); refresh()
        } catch { self.error = "Could not clear the receipt. No action was sent." }
    }
    func stop() {
        stopped = true; invalidate(); timer?.invalidate(); timer = nil
        if sending, var pending = receipt {
            pending.delivery = .unknown; receipt = pending
            do { try saveReceipt(pending) }
            catch { receiptInvalid = true; self.error = "Could not update the receipt. Delivery remains unknown; check the destination." }
        }
    }
    private func execute(_ request: [String: Any], timeout: TimeInterval, completion: @escaping (Result<PanelResponse, Error>) -> Void) {
        guard !busy else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            guard data.count <= 4096 else { throw PanelProcess.Failure.invalid }
            busy = true
            let execution = UUID()
            activeExecution = execution
            let cancellation = executor(data, timeout) { [weak self] result in
                guard let self, self.activeExecution == execution else { return }
                self.activeExecution = nil; self.busy = false; self.cancel = nil
                completion(result.flatMap { bytes in Result {
                    guard bytes.count <= 300 * 1024 else { throw PanelProcess.Failure.invalid }
                    return try JSONDecoder().decode(PanelResponse.self, from: bytes)
                } })
            }
            if activeExecution == execution { cancel = cancellation }
        } catch { completion(.failure(error)) }
    }
    private var receiptURL: URL { directory.appendingPathComponent("panel-action.json") }
    private func loadReceipt() {
        do {
            let fd = open(receiptURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if fd < 0 && errno == ENOENT { return }
            guard fd >= 0 else { throw PanelProcess.Failure.invalid }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_mode & 0o077 == 0, info.st_size <= 1024 else { throw PanelProcess.Failure.invalid }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 1025) ?? Data()
            guard data.count <= 1024 else { throw PanelProcess.Failure.invalid }
            var saved = try JSONDecoder().decode(PanelReceipt.self, from: data)
            if saved.delivery == .sending { saved.delivery = .unknown }
            receipt = saved
        } catch { receiptInvalid = true; self.error = "The saved action receipt is unreadable. Actions are blocked; check the destination and repair the receipt file." }
    }
    private func saveReceipt(_ value: PanelReceipt) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw PanelProcess.Failure.invalid }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent(".panel-receipt-" + UUID().uuidString)
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PanelProcess.Failure.invalid }
        defer { close(fd); try? manager.removeItem(at: path) }
        let data = try JSONEncoder().encode(value)
        let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(fd) == 0, rename(path.path, receiptURL.path) == 0 else { throw PanelProcess.Failure.invalid }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw PanelProcess.Failure.invalid }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw PanelProcess.Failure.invalid }
    }
}

enum PanelProcess {
    enum Failure: Error { case invalid, unavailable, interrupted }
    // Each invocation owns its exact child; completion runs only after reaping it.
    static func run(resources: URL?, input: Data, timeout: TimeInterval,
                    completion: @escaping (Result<Data, Error>) -> Void) -> () -> Void {
        let state = Run()
        DispatchQueue.global(qos: .utility).async {
            let result: Result<Data, Error> = Result {
                guard input.count <= 4096,
                      let script = resources?.appendingPathComponent("mobile/src/panel-main.mjs"),
                      FileManager.default.fileExists(atPath: script.path),
                      let node = AgentSetup.findExecutable("node", path: AgentSetup.searchPath) else { throw Failure.unavailable }
                let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                task.executableURL = node; task.arguments = [script.path]
                let env = ProcessInfo.processInfo.environment
                var safe = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                            "PATH": AgentSetup.searchPath, "LANG": env["LANG"] ?? "en_US.UTF-8",
                            "TMPDIR": env["TMPDIR"] ?? FileManager.default.temporaryDirectory.path,
                            "NODE_TLS_REJECT_UNAUTHORIZED": "1"]
                if let fixture = env["NOTIFY_PANEL_FILE"] { safe["NOTIFY_PANEL_FILE"] = fixture }
                task.environment = safe
                task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
                _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try state.launch(task)
                try? stdin.fileHandleForReading.close()
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                let group = DispatchGroup()
                let out = Capture(limit: 300 * 1024), err = Capture(limit: 8 * 1024)
                for (capture, handle) in [(out, stdout.fileHandleForReading), (err, stderr.fileHandleForReading)] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        capture.read(handle, state: state, deadline: ProcessInfo.processInfo.systemUptime + timeout + 1); group.leave()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { state.terminate() }
                do { try stdin.fileHandleForWriting.write(contentsOf: input) }
                catch { state.terminate() }
                try? stdin.fileHandleForWriting.close()
                task.waitUntilExit()
                state.finished()
                group.wait()
                guard !state.interrupted, !out.failed, !err.failed, task.terminationReason == .exit,
                      task.terminationStatus == 0 else {
                    throw NSError(domain: "NotifyPanelProcess", code: Int(task.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: "The Dashboard helper failed or exceeded its limits."])
                }
                return out.data
            }
            DispatchQueue.main.async { completion(result) }
        }
        return { state.terminate() }
    }
    private final class Run {
        private let lock = NSLock()
        private var task: Process?
        private var wasInterrupted = false
        var interrupted: Bool { lock.lock(); defer { lock.unlock() }; return wasInterrupted }
        private var done = false
        func launch(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !wasInterrupted else { throw Failure.interrupted }
            try process.run(); task = process
        }
        func finished() { lock.lock(); done = true; task = nil; lock.unlock() }
        func terminate() {
            lock.lock()
            guard !done else { lock.unlock(); return }
            wasInterrupted = true
            let owned = task
            if let owned, owned.isRunning { owned.terminate() }
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
                lock.lock(); defer { lock.unlock() }
                if let owned, task === owned, !done, owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
            }
        }
    }
    private final class Capture {
        let limit: Int
        var data = Data()
        var failed = false
        init(limit: Int) { self.limit = limit }
        func read(_ handle: FileHandle, state: Run, deadline: TimeInterval) {
            defer { try? handle.close() }
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 4096)
            while ProcessInfo.processInfo.systemUptime < deadline {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { continue }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count == 0 { return }
                if count < 0 { if errno == EINTR { continue }; break }
                if data.count + count > limit { failed = true; state.terminate() }
                else { data.append(contentsOf: buffer.prefix(count)) }
            }
            failed = true; state.terminate()
        }
    }
}
