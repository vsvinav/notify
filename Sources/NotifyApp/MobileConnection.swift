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

struct MobilePairing: Identifiable {
    let id: String
    let name: String
    let code: String
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
    let status: MobileStatus?
    let id: String?
    let name: String?
    let code: String?
    let message: String?
    let sessionIDs: [String]?
}

final class MobileConnection: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var starting = false
    @Published private(set) var status: MobileStatus?
    @Published private(set) var pairings: [MobilePairing] = []
    var pairing: MobilePairing? { pairings.first }
    @Published private(set) var error: String?
    var snapshot: (() -> [MobileItem])?
    var onReply: ((MobileReply) -> Void)?
    var onControl: ((MobileControl) -> Void)?
    var workspaceSnapshot: (([String]) throws -> [Data])?
    var onUnavailable: (() -> Void)?
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

    init(directory: URL, defaults: UserDefaults, resources: URL? = Bundle.main.resourceURL) {
        self.directory = directory
        self.defaults = defaults
        self.resources = resources
        enabled = defaults.bool(forKey: "mobileEnabled")
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "mobileEnabled")
        if value { start() } else { stop() }
    }

    func start() {
        guard enabled, process == nil else { return }
        error = nil
        guard let node = AgentSetup.findExecutable("node", path: AgentSetup.searchPath),
              let script = resources?.appendingPathComponent("mobile/src/main.mjs"),
              FileManager.default.fileExists(atPath: script.path) else {
            error = "Phone support needs Node.js 22.18 or newer and the bundled mobile companion. Rebuild Notify with the mobile repository."
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
                guard let self, self.process === child else { return }
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
            send(["type": "start", "directory": directory.path])
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
                    self?.tickets.removeAll()
                    self?.send(["type": "offline"])
                    self?.onUnavailable?()
                },
                center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.sleeping = false
                    self?.lastEvent = Date()
                    self?.publish()
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
        if child?.isRunning == true { child?.terminate() }
        tickets.removeAll()
        watchedSessions = []
        lastWorkspace = []
        status = nil
        pairings.removeAll()
        starting = false
        sleeping = false
        onUnavailable?()
    }

    func invite() { error = nil; send(["type": "invite"]) }
    func confirmPairing(_ allow: Bool) {
        guard let pairing else { return }
        send(["type": "pair", "id": pairing.id, "allow": allow])
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
        guard !reply.id.isEmpty, reply.id.count <= 128, !sleeping,
              let current = tickets[reply.sessionID + "\0" + reply.requestID] else { return false }
        return current.request == request && current.token == reply.ticket
    }

    func complete(_ id: String, error: String? = nil) {
        var result: [String: Any] = ["type": "result", "id": id, "ok": error == nil]
        if let error { result["error"] = error }
        send(result)
    }

    func publish(heartbeat: Bool = false) {
        guard process?.isRunning == true, status != nil, !sleeping else { return }
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
        guard !workspacePending, process?.isRunning == true, !sleeping else { return }
        workspacePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.workspacePending = false
            self.publishWorkspace()
        }
    }
    private func publishWorkspace(heartbeat: Bool = false) {
        guard process?.isRunning == true, status != nil, !sleeping, let workspaceSnapshot else { return }
        do {
            let messages = try workspaceSnapshot(watchedSessions)
            for message in messages where heartbeat || !lastWorkspace.contains(message) { write(message) }
            lastWorkspace = messages
        } catch { fail("Could not encode phone workspace: \(error.localizedDescription)") }
    }
    func completeControl(_ id: String, commandID: String? = nil, status: String, detail: String, error: String? = nil) {
        var result: [String: Any] = ["type": "control_result", "id": id, "ok": error == nil,
                                     "status": status, "detail": detail]
        if let commandID { result["commandID"] = commandID }
        if let error { result["error"] = error }
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
                guard let status = event.status,
                      status.pendingPairingIDs.count <= 8,
                      URL(string: status.url)?.scheme == "https",
                      URL(string: status.setupURL)?.scheme == "http" else { throw ProtocolError.invalid }
                let first = self.status == nil
                self.status = status
                pairings.removeAll { !status.pendingPairingIDs.contains($0.id) }
                starting = false
                if first { publish() }
            case "pairing":
                guard let id = event.id, let name = event.name, let code = event.code,
                      id.count <= 128, name.count <= 100, code.count <= 32 else { throw ProtocolError.invalid }
                pairings.removeAll { $0.id == id }
                guard pairings.count < 8 else { throw ProtocolError.oversized }
                pairings.append(MobilePairing(id: id, name: name, code: code))
            case "reply":
                onReply?(try JSONDecoder().decode(MobileReply.self, from: data))
            case "workspace_watch":
                guard let ids = event.sessionIDs, ids.count <= 8, Set(ids).count == ids.count,
                      ids.allSatisfy({ !$0.isEmpty && $0.count <= 128 }) else { throw ProtocolError.invalid }
                watchedSessions = ids
                lastWorkspace = []
                workspaceChanged()
            case "control":
                let control = try JSONDecoder().decode(MobileControl.self, from: data)
                guard control.isValid, !sleeping else { throw ProtocolError.invalid }
                onControl?(control)
            case "error":
                error = event.message ?? "The phone companion reported an error."
                starting = false
            default: throw ProtocolError.invalid
            }
        } catch { fail("The phone companion sent an invalid message: \(error.localizedDescription)") }
    }

    private func fail(_ message: String) { stop(); error = message }
}
