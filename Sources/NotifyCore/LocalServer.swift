import Foundation
import Network
import Darwin

public final class LocalServer {
    public var onPacket: (AgentPacket) -> Void = { _ in }
    public var onDisconnect: (String) -> Void = { _ in }
    public var onError: (String) -> Void = { _ in }
    public var onReady: () -> Void = {}
    private let directory: URL
    private let queue: DispatchQueue
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    private var peers: [UUID: Peer] = [:]
    private var sessions: [String: UUID] = [:]

    private final class Peer {
        let connection: NWConnection
        var framer = LineFramer()
        var sessionID: String?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    public init(directory: URL, queue: DispatchQueue = .main) {
        self.directory = directory
        self.queue = queue
    }

    public func start() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = listener.port {
                do {
                    let data = try JSONSerialization.data(withJSONObject: ["port": Int(port.rawValue), "token": self.token])
                    let path = self.directory.appendingPathComponent("connection.json")
                    try data.write(to: path, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                    self.onReady()
                } catch { self.onError("Cannot publish local connection: \(error.localizedDescription)"); self.stop() }
            } else if case .failed(let error) = state {
                self.onError("Local connection failed: \(error.localizedDescription)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.peers.count < 128 else { connection.cancel(); return }
            let id = UUID()
            let peer = Peer(connection)
            self.peers[id] = peer
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.peers[id]?.sessionID == nil { self?.close(id) }
            }
            self.receive(id)
        }
        listener.start(queue: queue)
    }

    private func receive(_ id: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.peers[id] != nil else { return }
            do {
                if let data {
                    for line in try peer.framer.append(data) {
                        let packet = try JSONDecoder().decode(AgentPacket.self, from: line)
                        if peer.sessionID == nil {
                            guard packet.type == "hello", packet.token == self.token,
                                  !packet.sessionID.isEmpty, packet.sessionID.count <= 128,
                                  ["claude", "copilot", "demo"].contains(packet.agent ?? ""),
                                  let cwd = packet.cwd, cwd.hasPrefix("/"), cwd.count < 4096 else { throw ProtocolError.invalid }
                            if let old = self.sessions[packet.sessionID] { self.close(old) }
                            peer.sessionID = packet.sessionID
                            self.sessions[packet.sessionID] = id
                            self.onPacket(packet)
                            try self.send(sessionID: packet.sessionID, message: ["type": "welcome"])
                        } else {
                            guard packet.sessionID == peer.sessionID, packet.type != "hello" else { throw ProtocolError.invalid }
                            self.onPacket(packet)
                        }
                    }
                }
                if complete || error != nil { self.close(id) }
                else { self.receive(id) }
            } catch {
                if peer.sessionID != nil { self.onError("Invalid launcher message: \(error.localizedDescription)") }
                self.close(id)
            }
        }
    }

    public func send(sessionID: String, message: [String: Any]) throws {
        guard let id = sessions[sessionID], let peer = peers[id] else { throw ProtocolError.stale }
        var body = message
        body["sessionID"] = sessionID
        var data = try JSONSerialization.data(withJSONObject: body)
        guard data.count < 1_048_576 else { throw ProtocolError.oversized }
        data.append(10)
        peer.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.onError("Reply could not be delivered: \(error.localizedDescription)"); self?.close(id) }
        })
    }
    private func close(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.connection.cancel()
        if let session = peer.sessionID, sessions[session] == id {
            sessions.removeValue(forKey: session)
            onDisconnect(session)
        }
    }
    public func stop() {
        listener?.cancel()
        listener = nil
        for id in Array(peers.keys) { close(id) }
        let path = directory.appendingPathComponent("connection.json")
        do {
            if FileManager.default.fileExists(atPath: path.path),
               let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
               json["token"] as? String == token { try FileManager.default.removeItem(at: path) }
        } catch { onError("Could not remove connection file: \(error.localizedDescription)") }
    }
}
