import AppKit
import Combine
import NotifyCore

struct MobileDevice: Decodable, Identifiable {
    let id: String
    let name: String
    let online: Bool
    let pushEnabled: Bool
}

struct MobileStatus: Decodable {
    let url: String
    let setupURL: String
    let fingerprint: String
    let pairingCode: String?
    let devices: [MobileDevice]
    let pendingPairingIDs: [String]
    let pushMessage: String?
}

struct MobilePairing: Identifiable, Equatable {
    let id: String
    let name: String
    let code: String
    var verificationData: String? = nil
}

enum MobileTransport { case lan, internet }

enum InternetConnectionState: String, Decodable {
    case paused, connecting, pairing, connected, error
}

struct InternetStatus: Decodable {
    let state: InternetConnectionState
    let url: String
    let devices: [MobileDevice]
    let pendingPairingIDs: [String]
    let setupURL: String?
    let pairingCode: String?
    let message: String?
}

struct MobileReply: Decodable {
    let id: String
    let sessionID: String
    let requestID: String
    let ticket: String
    let decision: String
    let answers: [String: [String]]?
    let permissionOptionID: String?
    let feedback: String?
}

struct MobileField: Encodable {
    let id: Int
    let label: String
    let value: String
    let presentation: String
    let target: String?

    init(_ field: ContextField) {
        id = field.id
        label = field.displayLabel
        value = field.value
        presentation = String(describing: field.presentation)
        target = field.targetLabel
    }
}

struct MobileItem: Encodable {
    let sessionID: String
    let sessionName: String
    let project: String
    let agent: String
    let color: String
    let ticket: String
    let notificationID: String
    let request: AgentRequest
    let fields: [MobileField]
    let sending: Bool
    let error: String?
}

private struct MobileEvent: Decodable {
    let type: String
    let id: String?
    let name: String?
    let code: String?
    let message: String?
    let sessionIDs: [String]?
    let verificationData: String?
}

final class MobileConnection: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var starting = false
    @Published private(set) var status: MobileStatus?
    @Published private(set) var internetStatus: InternetStatus?
    @Published private(set) var internetOrigin: String
    @Published private(set) var pairings: [MobilePairing] = []
    var pairing: MobilePairing? { pairings.first }
    var canConfirmPairing: Bool {
        guard let pairing else { return false }
        if transport == .lan { return true }
        guard let value = pairing.verificationData, value.utf8.count == 88,
              let key = Data(base64Encoded: value), key.count == 65, key.first == 4 else { return false }
        return key.base64EncodedString() == value
    }
    @Published private(set) var error: String?
    @Published private(set) var internetBackupURL: URL?
    @Published private var retiringProcesses: [Process] = []
    var canStartFreshInternetSetup: Bool {
        transport == .internet && !enabled && process == nil && retiringProcesses.isEmpty
    }
    var snapshot: (() -> [MobileItem])?
    var onReply: ((MobileReply) -> Void)?
    var onControl: ((MobileControl) -> Void)?
    var workspaceSnapshot: (([String]) throws -> [Data])?
    var onUnavailable: (() -> Void)?
    let transport: MobileTransport
    var workspace = MobileWorkspace()
    var canReceiveCommands: Bool {
        enabled && !sleeping && process?.isRunning == true &&
            (transport == .lan ? status != nil : internetStatus?.state == .connected)
    }
    private let directory: URL
    private let resources: URL?
    private let defaults: UserDefaults
    private var process: Process?
    private var input: FileHandle?
    private let writer = DispatchQueue(label: "notify.mobile.writer")
    private var timer: Timer?
    private var lastEvent = Date()
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    private var tickets: [String: (request: AgentRequest, token: String)] = [:]
    private var watchedSessions: [String] = []
    private var workspacePending = false
    private var lastWorkspace: [Data] = []

    init(directory: URL, defaults: UserDefaults, resources: URL? = Bundle.main.resourceURL, transport: MobileTransport = .lan) {
        self.directory = directory
        self.defaults = defaults
        self.resources = resources
        self.transport = transport
        internetOrigin = defaults.string(forKey: "internetOrigin") ?? ""
        enabled = transport == .lan && defaults.bool(forKey: "mobileEnabled")
    }

    static func isValidInternetOrigin(_ value: String) -> Bool {
        guard value.utf8.count <= 2048, value.hasPrefix("https://"),
              value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }),
              !value.contains("%"), !value.contains("\\"),
              let components = URLComponents(string: value),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.path.isEmpty,
              components.query == nil, components.fragment == nil,
              components.url?.absoluteString == value else { return false }
        if let port = components.port, !(1...65535).contains(port) { return false }
        return !value.hasSuffix(":")
    }

    func setInternetOrigin(_ value: String) {
        guard transport == .internet, !enabled else { return }
        internetOrigin = value
        defaults.set(value, forKey: "internetOrigin")
        error = Self.isValidInternetOrigin(value) ? nil : "Enter an exact HTTPS origin, without a path, credentials, query or fragment."
    }

    func setEnabled(_ value: Bool) {
        if value, transport == .internet, !Self.isValidInternetOrigin(internetOrigin) {
            error = "Enter an exact HTTPS origin, without a path, credentials, query or fragment."
            return
        }
        enabled = value
        if transport == .lan { defaults.set(value, forKey: "mobileEnabled") }
        if value { start() } else { stop() }
    }

    func start() {
        guard enabled, process == nil else { return }
        error = nil
        guard transport == .lan || Self.isValidInternetOrigin(internetOrigin) else {
            fail("The internet service origin is invalid.")
            return
        }
        guard let node = AgentSetup.findExecutable("node", path: AgentSetup.searchPath),
              let script = resources?.appendingPathComponent(transport == .internet ? "mobile/src/remote-main.mjs" : "mobile/src/main.mjs"),
              FileManager.default.fileExists(atPath: script.path) else {
            error = transport == .internet
                ? "Internet access needs Node.js 22.18 or newer and the bundled remote-main.mjs helper. No internet connection was started."
                : "Phone support needs Node.js 22.18 or newer and the bundled mobile companion. Rebuild Notify with the mobile repository."
            return
        }
        let child = Process()
        let incoming = Pipe(), outgoing = Pipe(), diagnostics = Pipe()
        child.executableURL = node
        child.arguments = [script.path]
        child.currentDirectoryURL = script.deletingLastPathComponent().deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["NODE_TLS_REJECT_UNAUTHORIZED"] = "1"
        environment["PATH"] = AgentSetup.searchPath
        child.environment = environment
        child.standardInput = outgoing
        child.standardOutput = incoming
        child.standardError = diagnostics
        guard fcntl(outgoing.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            error = "Could not prepare the private phone connection pipe."
            return
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self else { return }
                self.retiringProcesses.removeAll { $0 === child }
                guard self.process === child else { return }
                self.stop()
                self.error = "The phone companion stopped (exit \(child.terminationStatus)). Turn phone connections off and on to retry."
            }
        }
        do {
            try child.run()
            process = child
            input = outgoing.fileHandleForWriting
            starting = true
            lastEvent = Date()
            read(incoming.fileHandleForReading, from: child, diagnostics: false)
            read(diagnostics.fileHandleForReading, from: child, diagnostics: true)
            var start: [String: Any] = ["type": "start", "directory": directory.path]
            if transport == .internet { start["origin"] = internetOrigin }
            send(start)
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self, !self.sleeping else { return }
                if Date().timeIntervalSince(self.lastEvent) > 25 {
                    self.fail("The phone companion stopped responding. Turn phone connections off and on to retry.")
                } else { self.publish(heartbeat: true) }
            }
            let center = NSWorkspace.shared.notificationCenter
            observers = [
                center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.sleeping = true
                    self?.invalidateAuthority()
                    if self?.transport == .internet {
                        self?.internetStatus = nil
                        self?.pairings.removeAll()
                    }
                    self?.send(["type": "offline"])
                },
                center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.sleeping = false
                    self?.lastEvent = Date()
                    self?.publish(heartbeat: self?.transport == .internet)
                }
            ]
        } catch {
            self.error = "Could not start phone connections: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        let child = process
        process = nil
        input = nil
        if let child, child.isRunning {
            retiringProcesses.append(child)
            child.terminate()
        }
        invalidateAuthority()
        status = nil
        internetStatus = nil
        pairings.removeAll()
        starting = false
        sleeping = false
    }

    private func invalidateAuthority() {
        tickets.removeAll()
        watchedSessions = []
        lastWorkspace = []
        workspace.invalidate()
        onUnavailable?()
    }

    func startFreshInternetSetup() {
        guard canStartFreshInternetSetup else {
            error = "Turn off internet access and wait for its helper to stop before starting fresh. Nothing was changed."
            return
        }
        do {
            let parent = directory.deletingLastPathComponent()
            let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw POSIXError(.EACCES) }
            defer { close(parentFD) }
            var parentInfo = stat()
            guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_uid == getuid(),
                  parentInfo.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
            let name = directory.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", directory != parent else { throw POSIXError(.EINVAL) }
            let sourceFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(sourceFD) }
            var sourceInfo = stat()
            guard fstat(sourceFD, &sourceInfo) == 0, sourceInfo.st_uid == getuid(),
                  sourceInfo.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
            let backupName = name + "-backup-" + UUID().uuidString.lowercased()
            // Same-parent, exclusive rename keeps the old trust intact and never overwrites a backup.
            guard renameatx_np(parentFD, name, parentFD, backupName, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            internetBackupURL = parent.appendingPathComponent(backupName)
            error = nil
        } catch {
            self.error = "Could not back up the internet setup: \(error.localizedDescription) No fresh setup was started."
        }
    }

    func invite() { error = nil; send(["type": "invite"]) }
    func confirmPairing(_ allow: Bool, expected: MobilePairing? = nil) {
        guard let pairing else { return }
        if transport == .internet, allow, expected != pairing {
            error = "The pairing prompt changed. Compare the complete public key again before confirming."
            return
        }
        guard expected == nil || expected == pairing else { return }
        guard !allow || canConfirmPairing else {
            error = "Internet pairing requires the complete P256 public key from the helper."
            return
        }
        var command: [String: Any] = ["type": "pair", "id": pairing.id, "allow": allow]
        if transport == .internet, allow { command["verificationData"] = pairing.verificationData }
        error = nil
        send(command)
        pairings.removeAll { $0.id == pairing.id }
    }
    func revoke(_ id: String) { send(["type": "revoke", "id": id]) }
    func testPush() { error = nil; send(["type": "test-push"]) }

    func ticket(sessionID: String, request: AgentRequest) -> String {
        let key = sessionID + "\0" + request.id
        if let existing = tickets[key], existing.request == request { return existing.token }
        let token = UUID().uuidString
        tickets[key] = (request, token)
        return token
    }

    func accepts(_ reply: MobileReply, request: AgentRequest) -> Bool {
        guard canReceiveCommands, !reply.id.isEmpty, reply.id.count <= 128,
              let current = tickets[reply.sessionID + "\0" + reply.requestID] else { return false }
        return current.request == request && current.token == reply.ticket
    }

    func complete(_ id: String, error: String? = nil) {
        var result: [String: Any] = ["type": "result", "id": id, "ok": error == nil]
        if let error { result["error"] = error }
        send(result)
    }

    func publish(heartbeat: Bool = false) {
        guard canReceiveCommands else {
            if heartbeat, transport == .internet { send(["type": "heartbeat"]) }
            return
        }
        guard let snapshot else { fail("Phone request information is unavailable."); return }
        let items = snapshot()
        let retained = Set(items.map(\.ticket))
        tickets = tickets.filter { retained.contains($0.value.token) }
        struct Snapshot: Encodable {
            let type = "snapshot"
            let requests: [MobileItem]
            let total: Int
        }
        do { write(try JSONEncoder().encode(Snapshot(requests: items, total: items.count))) }
        catch { fail("Could not encode phone requests: \(error.localizedDescription)") }
        if heartbeat { publishWorkspace(heartbeat: true) }
        else { workspaceChanged() }
    }

    func workspaceChanged() {
        guard !workspacePending, canReceiveCommands else { return }
        workspacePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.workspacePending = false
            self.publishWorkspace()
        }
    }
    private func publishWorkspace(heartbeat: Bool = false) {
        guard canReceiveCommands, let workspaceSnapshot else { return }
        do {
            let messages = try workspaceSnapshot(watchedSessions)
            for message in messages where heartbeat || !lastWorkspace.contains(message) { write(message) }
            lastWorkspace = messages
        } catch { fail("Could not encode phone workspace: \(error.localizedDescription)") }
    }
    func completeControl(_ control: MobileControl, commandID: String? = nil, status: String, detail: String, error: String? = nil, policy: MobileAutomationPolicy? = nil) {
        let confirmed = error == nil && commandID.map { !$0.isEmpty && $0.utf16.count <= 128 } == true &&
            control.successStatuses.contains(status) && (!control.isPolicy || policy != nil)
        let validStatus = confirmed || ["failed", "unknown", "cancelled"].contains(status)
        var result: [String: Any] = ["type": "control_result", "id": control.id, "ok": confirmed,
                                     "status": validStatus ? status : "unknown", "detail": detail]
        if let commandID { result["commandID"] = commandID }
        if control.isSessionAction {
            result["sessionID"] = control.sessionID
            result["action"] = control.action
            result["sessionTicket"] = control.sessionTicket
        }
        if !confirmed { result["error"] = error ?? "Runtime did not confirm this exact action." }
        if control.isPolicy, let policy {
            result["dangerousAutoYes"] = ["ticket": policy.ticket, "offTicket": policy.offTicket, "revision": policy.revision, "enabled": policy.enabled, "normalEnabled": policy.normalEnabled]
        }
        send(result)
    }

    private func send(_ message: [String: Any]) {
        guard process?.isRunning == true else { return }
        do { write(try JSONSerialization.data(withJSONObject: message)) }
        catch { fail("Could not encode the phone command: \(error.localizedDescription)") }
    }

    private func write(_ data: Data) {
        guard data.count <= 1_048_576 else {
            fail("There is too much request information for phone support. Use the Mac to review these requests.")
            return
        }
        guard let input, let child = process else { return }
        writer.async { [weak self] in
            guard child.isRunning else { return }
            do { try input.write(contentsOf: data + Data([10])) }
            catch {
                DispatchQueue.main.async {
                    guard let self, self.process === child else { return }
                    self.fail("The private phone connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func read(_ handle: FileHandle, from child: Process, diagnostics: Bool) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var framer = LineFramer()
            do {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    let data = Data(buffer.prefix(count))
                    if diagnostics {
                        let message = String(decoding: data.prefix(2000), as: UTF8.self)
                        DispatchQueue.main.async {
                            guard let self, self.process === child else { return }
                            self.error = "Phone companion: " + message
                        }
                    } else {
                        for line in try framer.append(data) {
                            DispatchQueue.main.async {
                                guard let self, self.process === child else { return }
                                self.receive(line)
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.process === child else { return }
                    self.fail("Could not read the phone companion: \(error.localizedDescription)")
                }
            }
            do { try handle.close() }
            catch { NSLog("Notify could not close a phone stream: %@", error.localizedDescription) }
        }
    }

    private func receive(_ data: Data) {
        do {
            let event = try JSONDecoder().decode(MobileEvent.self, from: data)
            lastEvent = Date()
            switch event.type {
            case "status":
                if transport == .internet {
                    struct Envelope: Decodable { let status: InternetStatus }
                    let status = try JSONDecoder().decode(Envelope.self, from: data).status
                    guard status.url == internetOrigin, status.devices.count <= 64,
                          Set(status.devices.map(\.id)).count == status.devices.count,
                          status.devices.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 128 && !$0.name.isEmpty && $0.name.count <= 100 }),
                          status.pendingPairingIDs.count <= 8,
                          Set(status.pendingPairingIDs).count == status.pendingPairingIDs.count,
                          status.pendingPairingIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
                          status.state != .connected || status.devices.contains(where: \.online),
                          status.setupURL.map(validInternetSetupURL) ?? true else { throw ProtocolError.invalid }
                    let wasConnected = internetStatus?.state == .connected
                    if status.state != .connected { invalidateAuthority() }
                    internetStatus = status
                    pairings.removeAll { !status.pendingPairingIDs.contains($0.id) }
                    starting = status.state == .connecting
                    error = status.state == .error ? (status.message ?? "The internet helper reported an error.") : nil
                    if status.state == .connected, !wasConnected { publish() }
                    return
                }
                struct Envelope: Decodable { let status: MobileStatus }
                let status = try JSONDecoder().decode(Envelope.self, from: data).status
                guard
                      status.pendingPairingIDs.count <= 8,
                      URL(string: status.url)?.scheme == "https",
                      URL(string: status.setupURL)?.scheme == "http" else { throw ProtocolError.invalid }
                let first = self.status == nil
                self.status = status
                pairings.removeAll { !status.pendingPairingIDs.contains($0.id) }
                starting = false
                if first { publish() }
            case "pairing":
                guard let id = event.id, let name = event.name,
                      id.count <= 128, name.count <= 100 else { throw ProtocolError.invalid }
                let code = transport == .lan ? event.code : ""
                guard let code, code.count <= 32 else { throw ProtocolError.invalid }
                if transport == .internet {
                    guard !id.isEmpty, !name.isEmpty,
                          internetStatus?.pendingPairingIDs.contains(id) == true,
                          event.verificationData.map({ !$0.isEmpty && $0.utf8.count <= 512 && $0.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 && $0.value < 127 }) }) ?? true
                    else { throw ProtocolError.invalid }
                }
                pairings.removeAll { $0.id == id }
                guard pairings.count < 8 else { throw ProtocolError.oversized }
                pairings.append(MobilePairing(id: id, name: name, code: code, verificationData: event.verificationData))
            case "reply":
                guard canReceiveCommands else { throw ProtocolError.invalid }
                onReply?(try JSONDecoder().decode(MobileReply.self, from: data))
            case "workspace_watch":
                guard canReceiveCommands else { throw ProtocolError.invalid }
                guard let ids = event.sessionIDs, ids.count <= 8, Set(ids).count == ids.count,
                      ids.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else { throw ProtocolError.invalid }
                watchedSessions = ids
                lastWorkspace = []
                workspaceChanged()
            case "control":
                let control = try JSONDecoder().decode(MobileControl.self, from: data)
                guard control.isValid, canReceiveCommands else { throw ProtocolError.invalid }
                onControl?(control)
            case "error":
                if transport == .internet {
                    fail(event.message ?? "The internet helper reported an error.")
                    return
                }
                error = event.message ?? "The phone companion reported an error."
                starting = false
            default: throw ProtocolError.invalid
            }
        } catch { fail("The phone companion sent an invalid message: \(error.localizedDescription)") }
    }

    private func validInternetSetupURL(_ value: String) -> Bool {
        guard value.utf8.count <= 4096,
              let url = URLComponents(string: value), let origin = URLComponents(string: internetOrigin),
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.url?.absoluteString == value else { return false }
        return true
    }

    private func fail(_ message: String) { stop(); error = message }
}
