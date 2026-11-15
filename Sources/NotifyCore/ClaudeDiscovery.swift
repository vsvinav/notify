import Foundation
import Darwin

public struct DiscoveredClaude {
    public let id: String
    public let pid: Int32
    public var cwd: String = ""
    public var title: String = ""
}

public struct SavedClaude: Identifiable {
    public let id: String
    public let title: String
    public let cwd: String
    public let lastActivity: Date?
}

public enum ClaudeDiscovery {
    public static var home: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    // Returns PIDs of running `claude` processes owned by this user.
    public static func runningPIDs() throws -> Set<Int32> {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-u", String(getuid()), "-o", "pid=,comm="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Set(String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> Int32? in
                let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard parts.count == 2,
                      URL(fileURLWithPath: String(parts[1])).lastPathComponent == "claude",
                      let pid = Int32(parts[0]) else { return nil }
                return pid
            })
    }

    // Reads ~/.claude/sessions/<pid>.json for each live PID.
    public static func sessions(livePIDs: Set<Int32>, home: URL = ClaudeDiscovery.home) throws -> [DiscoveredClaude] {
        guard !livePIDs.isEmpty else { return [] }
        let sessionsDir = home.appendingPathComponent("sessions")
        guard (try? sessionsDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
        var result: [DiscoveredClaude] = []
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".json"),
                  let pid = Int32(name.dropLast(5)),
                  pid > 0,
                  livePIDs.contains(pid) else { continue }
            var item = DiscoveredClaude(id: "", pid: pid)
            if let data = try? Data(contentsOf: file),
               data.count <= 65_536,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let sessionID = obj["sessionId"] as? String ?? ""
                guard !sessionID.isEmpty, sessionID.count <= 128 else { continue }
                item = DiscoveredClaude(id: sessionID, pid: pid,
                    cwd: (obj["cwd"] as? String) ?? "")
            } else { continue }
            result.append(item)
        }
        return result
    }

    // Reads the 100 newest ~/.claude/projects/*/*.jsonl files for saved sessions.
    public static func catalog(home: URL = ClaudeDiscovery.home, livePIDs: Set<Int32>) throws -> [SavedClaude] {
        let projectsDir = home.appendingPathComponent("projects")
        guard (try? projectsDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
        let manager = FileManager.default
        // Collect all .jsonl files across all project subdirectories.
        var jsonlFiles: [(url: URL, modified: Date)] = []
        let projectDirs = (try? manager.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = (try? manager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for file in files {
                guard file.pathExtension == "jsonl",
                      UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                jsonlFiles.append((file, values.contentModificationDate ?? .distantPast))
            }
        }
        // Newest 100.
        let top100 = jsonlFiles.sorted { $0.modified > $1.modified }.prefix(100)
        var result: [SavedClaude] = []
        for (url, modified) in top100 {
            let sessionID = url.deletingPathExtension().lastPathComponent
            // Skip if this session is currently live (it will appear in running list).
            let saved = readSavedClaude(url: url, id: sessionID, modified: modified, livePIDs: livePIDs)
            if let saved { result.append(saved) }
        }
        return result
    }

    private static func readSavedClaude(url: URL, id: String, modified: Date, livePIDs: Set<Int32>) -> SavedClaude? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let window = 65_536
        guard let size = try? handle.seekToEnd() else { return nil }
        // First 64 KB: extract cwd from first JSON line with a cwd field.
        var cwd = ""
        if let _ = try? handle.seek(toOffset: 0),
           let firstChunk = try? handle.read(upToCount: window) {
            let text = String(decoding: firstChunk, as: UTF8.self)
            for line in text.split(separator: "\n").prefix(50) {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let c = obj["cwd"] as? String, c.hasPrefix("/"), c.count < 4096 {
                    cwd = c; break
                }
            }
        }
        // Last 64 KB: find most recent customTitle or aiTitle from summary entries.
        var title = ""
        let startOffset = size > UInt64(window) ? size - UInt64(window) : 0
        if let _ = try? handle.seek(toOffset: startOffset),
           let tailChunk = try? handle.read(upToCount: window) {
            let text = String(decoding: tailChunk, as: UTF8.self)
            for line in text.split(separator: "\n") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   obj["type"] as? String == "summary" {
                    let t = (obj["customTitle"] as? String) ?? (obj["aiTitle"] as? String) ?? ""
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
                    }
                }
            }
        }
        return SavedClaude(id: id, title: title, cwd: cwd, lastActivity: modified)
    }
}
