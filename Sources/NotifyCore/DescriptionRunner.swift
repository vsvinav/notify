import Foundation

public final class DescriptionRunner {
    private var process: Process?
    public var isRunning: Bool { process != nil }
    public init() {}

    private final class Capture {
        var data = Data()
        var error: Error?
        var overflow = false
        func read(_ handle: FileHandle) {
            do {
                while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                    data.append(chunk)
                    if data.count > 16_384 { overflow = true; data = data.suffix(16_384) }
                }
            } catch { self.error = error }
        }
    }

    public func run(sessionID: String, script: URL, completion: @escaping (Result<SessionDescription, Error>) -> Void) throws {
        guard process == nil, UUID(uuidString: sessionID) != nil else { throw ProtocolError.invalid }
        let task = Process(), output = Pipe(), errors = Pipe()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["NODE_TLS_REJECT_UNAUTHORIZED"] = "1"
        env["PATH"] = [env["PATH"] ?? "", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        let node = env["PATH"]!.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard let node else {
            throw NSError(domain: "NotifySummary", code: 1, userInfo: [NSLocalizedDescriptionKey: "Node.js is unavailable. Install Node.js 22.18 or newer."])
        }
        task.executableURL = node
        task.arguments = [script.path, sessionID]
        task.environment = env
        task.currentDirectoryURL = FileManager.default.temporaryDirectory
        task.standardOutput = output; task.standardError = errors
        task.standardInput = FileHandle.nullDevice
        try task.run()
        process = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 65) { [weak self] in
            if self?.process === task, task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let stdout = Capture(), stderr = Capture(), group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async { stderr.read(errors.fileHandleForReading); group.leave() }
            stdout.read(output.fileHandleForReading)
            task.waitUntilExit()
            group.wait()
            let result: Result<SessionDescription, Error> = Result {
                if let error = stdout.error ?? stderr.error { throw error }
                if stdout.overflow { throw ProtocolError.oversized }
                guard task.terminationReason == .exit, task.terminationStatus == 0 else {
                    let detail = String(decoding: stderr.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw NSError(domain: "NotifySummary", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        detail.isEmpty ? "Summary cancelled or timed out. No description was changed." :
                            (stderr.overflow ? "Summary error (last part of log):\n" + detail : detail)])
                }
                struct Response: Decodable { let text: String; let model: String }
                let response = try JSONDecoder().decode(Response.self, from: stdout.data)
                guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      response.text.count <= 240, response.model.count <= 128 else { throw ProtocolError.invalid }
                return SessionDescription(text: response.text, model: response.model, generatedAt: Date())
            }
            DispatchQueue.main.async {
                self.process = nil
                completion(result)
            }
        }
    }

    public func cancel() {
        if let process, process.isRunning { process.terminate() }
    }
}
