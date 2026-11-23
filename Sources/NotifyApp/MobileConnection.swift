import AppKit
import Combine
import NotifyCore

struct RememberedAuthorization: Decodable, Equatable {
    let generation: String
    let authorizationExpiresAt: Int64
    let state: State
    enum State: String, Decodable { case active, revoked, expired }

    var isValid: Bool { RememberedProposal.validID(generation) && authorizationExpiresAt > 0 && authorizationExpiresAt <= 9_007_199_254_740_991 }
    var isActive: Bool { state == .active && Double(authorizationExpiresAt) > Date().timeIntervalSince1970 * 1000 }
}

struct RememberedProposal: Codable, Equatable, Identifiable {
    struct Account: Codable, Equatable {
        let issuer: String
        let subject: String
    }
    let id: String
    let generation: String
    let deviceID: String
    let publicKey: String
    let name: String
    let account: Account
    let macID: String
    let macPublicKey: String
    let expiresAt: Int64
    let authorizationExpiresAt: Int64

    var isExpired: Bool { Double(expiresAt) <= Date().timeIntervalSince1970 * 1000 }
    func isValid(origin: String) -> Bool {
        Self.validID(id) && Self.validID(generation) &&
            UUID(uuidString: deviceID) != nil && UUID(uuidString: macID) != nil &&
            Self.validKey(publicKey) && Self.validKey(macPublicKey) &&
            !name.isEmpty && name.count <= 100 && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            account.issuer == origin && !account.subject.isEmpty && account.subject.count <= 256 &&
            !account.subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            expiresAt > 0 && authorizationExpiresAt > expiresAt &&
            authorizationExpiresAt <= 9_007_199_254_740_991 &&
            authorizationExpiresAt - expiresAt <= 30 * 86_400_000
    }
    static func validKey(_ value: String) -> Bool {
        guard value.utf8.count == 88, let bytes = Data(base64Encoded: value), bytes.count == 65, bytes.first == 4 else { return false }
        return bytes.base64EncodedString() == value
    }
    static func validID(_ value: String) -> Bool {
        guard value.utf8.count == 43,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) }),
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32 else { return false }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value
    }
}

struct RememberedDecision {
    let sentAt = Date()
    let requestID: String
    let proposal: RememberedProposal
    let allow: Bool
    var outcome: Outcome
    var message: String?
    enum Outcome: String, Decodable { case sending, unknown, approved, denied, error }
}

struct RememberedDecisionResult: Decodable {
    let requestID: String
    let proposalID: String
    let generation: String
    let authorizationExpiresAt: Int64
    let outcome: RememberedDecision.Outcome
    let message: String?
}

struct MobileDevice: Decodable, Identifiable {
    let id: String
    let name: String
    let online: Bool
    let pushEnabled: Bool
    let publicKey: String?
    let remembered: RememberedAuthorization?
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
    let rememberPending: RememberedProposal?
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

struct MobileAttentionItem: Codable, Equatable {
    let sessionID: String
    let requestID: String
    let sessionName: String
    let requestTitle: String
}

struct MobileAttention: Encodable, Equatable {
    let version = 1
    let epoch: String
    let revision: Int
    let current: MobileAttentionItem?
    let additionalCount: Int

    private enum CodingKeys: String, CodingKey { case version, epoch, revision, current, additionalCount }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(epoch, forKey: .epoch)
        try values.encode(revision, forKey: .revision)
        try values.encode(current, forKey: .current)
        try values.encode(additionalCount, forKey: .additionalCount)
    }
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
    @Published private(set) var rememberedDecisions: [RememberedDecision] = []
    private(set) var rememberedDecision: RememberedDecision? {
        get { rememberedDecisions.last }
        set {
            guard let value = newValue else { return }
            if let index = rememberedDecisions.firstIndex(where: { $0.requestID == value.requestID }) {
                rememberedDecisions[index] = value
            } else {
                rememberedDecisions.removeAll { $0.outcome != .unknown && $0.outcome != .sending }
                rememberedDecisions.append(value)
            }
        }
    }
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
    var attentionSnapshot: (() -> Set<String>)?
    var canonicalAttentionSnapshot: (() -> MobileAttention?)?
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
    private var waitingAttention: Set<String> = []
    private var watchedSessions: [String] = []
    private var workspacePending = false
    private var lastWorkspace: [Data] = []

    init(directory: URL, defaults: UserDefaults, resources: URL? = Bundle.main.resourceURL, transport: MobileTransport = .lan) {
        self.directory = directory
        self.defaults = defaults
        self.resources = resources
        self.transport = transport
        internetOrigin = defaults.string(forKey: "internetOrigin") ?? ""
        enabled = defaults.bool(forKey: transport == .lan ? "mobileEnabled" : "internetEnabled")
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
        defaults.set(value, forKey: transport == .lan ? "mobileEnabled" : "internetEnabled")
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
                if let decision = self.rememberedDecision, decision.outcome == .sending,
                   Date().timeIntervalSince(decision.sentAt) > 15 {
                    self.rememberedDecision?.outcome = .unknown
                    self.rememberedDecision?.message = "Decision not confirmed. Checking status; it will not be sent again."
                }
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
        if rememberedDecision?.outcome == .sending {
            rememberedDecision?.outcome = .unknown
            rememberedDecision?.message = "Decision not confirmed. Reconnect to check status; it will not be sent again."
        }
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
        waitingAttention.removeAll()
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
    func decideRemembered(_ allow: Bool, expected: RememberedProposal) {
        guard transport == .internet, enabled, !sleeping, process?.isRunning == true,
              internetStatus?.rememberPending == expected, expected.isValid(origin: internetOrigin), !expected.isExpired,
              rememberedDecision?.outcome != .sending,
              !rememberedDecisions.contains(where: { $0.proposal.id == expected.id && $0.outcome != .error }) else {
            error = "The remembered-phone prompt changed, expired, or was already sent. Check the current full key and status."
            return
        }
        guard rememberedDecisions.filter({ $0.outcome == .unknown }).count < 8 else {
            error = "Eight remembered-phone decisions remain unconfirmed. Check the service connection before sending another."
            return
        }
        let requestID = UUID().uuidString.lowercased()
        do {
            let proposal = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
            rememberedDecision = RememberedDecision(requestID: requestID, proposal: expected, allow: allow, outcome: .sending)
            error = nil
            send(["type": "remember-decision", "requestID": requestID, "proposal": proposal, "allow": allow])
        } catch { self.error = "Could not encode the remembered-phone decision: \(error.localizedDescription)" }
    }
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
        if transport == .internet, enabled, !sleeping, process?.isRunning == true,
           let waiting = attentionSnapshot?() {
            let changed = !waiting.subtracting(waitingAttention).isEmpty
            waitingAttention = waiting
            send(["type": "attention", "waiting": !waiting.isEmpty, "changed": changed])
        }
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
            let attention: MobileAttention?
        }
        do { write(try JSONEncoder().encode(Snapshot(requests: items, total: items.count,
            attention: canonicalAttentionSnapshot?()))) }
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
                          status.devices.allSatisfy({ $0.remembered.map(\.isValid) ?? true }),
                          status.devices.allSatisfy({ $0.publicKey.map(RememberedProposal.validKey) ?? ($0.remembered == nil) }),
                          status.rememberPending.map({ proposal in proposal.isValid(origin: internetOrigin) &&
                              status.devices.contains(where: { $0.id == proposal.deviceID && $0.publicKey == proposal.publicKey }) }) ?? true,
                          status.pendingPairingIDs.count <= 8,
                          Set(status.pendingPairingIDs).count == status.pendingPairingIDs.count,
                          status.pendingPairingIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
                          status.state != .connected || status.devices.contains(where: \.online),
                          status.setupURL.map(validInternetSetupURL) ?? true else { throw ProtocolError.invalid }
                    let wasConnected = internetStatus?.state == .connected
                    if status.state != .connected { invalidateAuthority() }
                    internetStatus = status
                    reconcileRemembered(status)
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
            case "remember-result":
                guard transport == .internet else { throw ProtocolError.invalid }
                let result = try JSONDecoder().decode(RememberedDecisionResult.self, from: data)
                guard result.outcome != .sending, result.message.map({ $0.count <= 500 }) ?? true,
                      RememberedProposal.validID(result.proposalID), RememberedProposal.validID(result.generation),
                      UUID(uuidString: result.requestID) != nil else { throw ProtocolError.invalid }
                guard var decision = rememberedDecisions.first(where: { $0.requestID == result.requestID }),
                      result.proposalID == decision.proposal.id, result.generation == decision.proposal.generation,
                      result.authorizationExpiresAt == decision.proposal.authorizationExpiresAt else { return }
                guard (result.outcome != .approved || decision.allow) &&
                      (result.outcome != .denied || !decision.allow) else { throw ProtocolError.invalid }
                if decision.outcome == .sending || decision.outcome == .unknown {
                    decision.outcome = result.outcome
                    decision.message = result.message
                    rememberedDecision = decision
                }
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

    private func reconcileRemembered(_ status: InternetStatus) {
        for var decision in rememberedDecisions where decision.allow && (decision.outcome == .sending || decision.outcome == .unknown) {
            guard let device = status.devices.first(where: { $0.id == decision.proposal.deviceID && $0.publicKey == decision.proposal.publicKey }),
                  let remembered = device.remembered, remembered.generation == decision.proposal.generation,
                  remembered.authorizationExpiresAt == decision.proposal.authorizationExpiresAt else { continue }
            decision.outcome = remembered.isActive ? .approved : .error
            decision.message = remembered.isActive ? nil : "This remembered authorization is no longer active."
            rememberedDecision = decision
        }
    }

    private func fail(_ message: String) { stop(); error = message }
}
