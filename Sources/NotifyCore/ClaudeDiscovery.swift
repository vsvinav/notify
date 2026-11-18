import Foundation
import Darwin

public struct DiscoveredClaude {
    public let id: String
    public let pid: Int32
    public var cwd: String
    public var title: String
    public init(id: String, pid: Int32, cwd: String = "", title: String = "") {
        self.id = id; self.pid = pid; self.cwd = cwd; self.title = title
    }
}

public struct SavedClaude: Identifiable {
    public let id: String
    public let title: String
    public let cwd: String
    public let lastActivity: Date?
    public let pid: Int32?
    public init(id: String, title: String, cwd: String, lastActivity: Date?, pid: Int32? = nil) {
        self.id = id; self.title = title; self.cwd = cwd; self.lastActivity = lastActivity; self.pid = pid
    }
}

public enum ClaudeDiscovery {
    private struct Metadata {
        var inode: UInt64 = 0
        var size: UInt64 = 0
        var modified = Date.distantPast
        var offset: UInt64 = 0
        var discardingLine = false
        var cwd = ""
        var customTitle = ""
        var aiTitle = ""
    }
    private final class CachedMetadata: NSObject {
        let value: Metadata
        init(_ value: Metadata) { self.value = value }
    }
    private static let metadataCache: NSCache<NSString, CachedMetadata> = {
        let cache = NSCache<NSString, CachedMetadata>()
        cache.countLimit = 100
        return cache
    }()

    public static var home: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    // Returns PIDs of running `claude` processes owned by this user.
    public static func runningPIDs() throws -> Set<Int32> {
        let output = try TerminalSession.run("/bin/ps", ["-u", String(getuid()), "-o", "pid=,comm="])
        return Set(output
            .split(separator: "\n")
            .compactMap { line -> Int32? in
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2,
                      URL(fileURLWithPath: String(parts[1])).lastPathComponent == "claude",
                      let pid = Int32(parts[0]), pid > 0 else { return nil }
                return pid
            })
    }

    // Reads ~/.claude/sessions/<pid>.json for each live PID.
    public static func sessions(livePIDs: Set<Int32>, home: URL = ClaudeDiscovery.home) throws -> [DiscoveredClaude] {
        guard !livePIDs.isEmpty else { return [] }
        let sessionsDir = home.appendingPathComponent("sessions")
        do { try CopilotDiscovery.requirePlainDirectory(sessionsDir) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        var result: [DiscoveredClaude] = []
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".json"),
                  let pid = Int32(name.dropLast(5)),
                  pid > 0,
                  livePIDs.contains(pid),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let handle = try openPlainFile(file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw ProtocolError.oversized }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = obj["sessionId"] as? String,
                  sessionID.count == 36, UUID(uuidString: sessionID) != nil else { continue }
            let cwd = obj["cwd"] as? String ?? ""
            guard cwd.isEmpty || (cwd.hasPrefix("/") && cwd.utf8.count < 4096 && !cwd.utf8.contains(0)) else { continue }
            result.append(DiscoveredClaude(id: sessionID, pid: pid, cwd: cwd))
        }
        return result
    }

    // Reads the 100 newest ~/.claude/projects/*/*.jsonl files for saved sessions.
    public static func catalog(home: URL = ClaudeDiscovery.home, livePIDs: Set<Int32>) throws -> [SavedClaude] {
        let manager = FileManager.default
        // Collect all .jsonl files across all project subdirectories.
        var jsonlFiles: [(url: URL, modified: Date)] = []
        for dir in try projectDirectories(home) {
            let files = try manager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            for file in files {
                guard file.pathExtension == "jsonl",
                      UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                jsonlFiles.append((file, values.contentModificationDate ?? .distantPast))
            }
        }
        // Newest 100.
        let top100 = jsonlFiles.sorted { $0.modified > $1.modified }.prefix(100)
        let running = try sessions(livePIDs: livePIDs, home: home)
        var result: [SavedClaude] = []
        for (url, modified) in top100 {
            let sessionID = url.deletingPathExtension().lastPathComponent
            result.append(try readSavedClaude(url: url, id: sessionID, modified: modified,
                pid: running.first(where: { $0.id == sessionID })?.pid))
        }
        return result
    }

    public static func transcript(id: String, home: URL = ClaudeDiscovery.home) throws -> URL {
        guard id.count == 36, UUID(uuidString: id) != nil else { throw TerminalSessionError.invalidSession }
        var matches: [URL] = []
        for directory in try projectDirectories(home) {
            let candidate = directory.appendingPathComponent("\(id).jsonl")
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let handle = try openPlainFile(candidate)
            try handle.close()
            matches.append(candidate)
        }
        guard matches.count == 1, let match = matches.first else { throw TerminalSessionError.invalidSession }
        return match
    }

    private static func projectDirectories(_ home: URL) throws -> [URL] {
        let root = home.appendingPathComponent("projects")
        do { try CopilotDiscovery.requirePlainDirectory(root) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        return try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter {
                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }
    }

    private static func openPlainFile(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            try handle.close()
            throw ProtocolError.invalid
        }
        return handle
    }

    private static func readSavedClaude(url: URL, id: String, modified: Date, pid: Int32?) throws -> SavedClaude {
        let handle = try openPlainFile(url)
        defer { try? handle.close() }
        let window = 65_536
        let size = try handle.seekToEnd()
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let key = url.path as NSString
        var metadata = metadataCache.object(forKey: key)?.value ?? Metadata()
        if metadata.inode != UInt64(info.st_ino) || size < metadata.size ||
            (size == metadata.size && modified != metadata.modified) {
            metadata = Metadata()
        }
        func readMetadata(_ line: Data) {
            guard line.count <= window else { return }
            let text = String(decoding: line, as: UTF8.self)
            guard (metadata.cwd.isEmpty && text.contains("\"cwd\"")) || text.contains("\"custom-title\"") || text.contains("\"ai-title\""),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if metadata.cwd.isEmpty, let cwd = object["cwd"] as? String,
               cwd.hasPrefix("/"), cwd.utf8.count < 4096, !cwd.utf8.contains(0) { metadata.cwd = cwd }
            if object["type"] as? String == "custom-title", let title = object["customTitle"] as? String {
                metadata.customTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            } else if object["type"] as? String == "ai-title", let title = object["aiTitle"] as? String {
                metadata.aiTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            }
        }
        // Index each transcript once, then only appended bytes. Cache names and offsets, never messages.
        if size != metadata.size || modified != metadata.modified {
            try handle.seek(toOffset: metadata.offset)
            var offset = metadata.offset, pending = Data()
            while offset < size, let chunk = try handle.read(upToCount: min(window, Int(size - offset))), !chunk.isEmpty {
                offset += UInt64(chunk.count)
                pending.append(chunk)
                let lines = pending.split(separator: 10, omittingEmptySubsequences: false)
                for line in lines.dropLast() {
                    if !metadata.discardingLine { readMetadata(Data(line)) }
                    metadata.discardingLine = false
                }
                let remainder = lines.last ?? Data()
                metadata.discardingLine = metadata.discardingLine || remainder.count > window
                metadata.offset = metadata.discardingLine ? offset : offset - UInt64(remainder.count)
                pending = metadata.discardingLine ? Data() : Data(remainder)
            }
            if !metadata.discardingLine { readMetadata(pending) }
            metadata.inode = UInt64(info.st_ino)
            metadata.size = size
            metadata.modified = modified
            metadataCache.setObject(CachedMetadata(metadata), forKey: key)
        }
        return SavedClaude(id: id, title: metadata.customTitle.isEmpty ? metadata.aiTitle : metadata.customTitle, cwd: metadata.cwd,
                           lastActivity: modified, pid: pid)
    }
}
