import Foundation
import Darwin
import Yams

public struct DiscoveredCopilot {
    public let id: String
    public let pid: Int32
    public var title = ""
    public var cwd = ""
    public var synopsis = ""
    public var metadataError: String?
}

public struct SavedCopilot: Identifiable {
    public let id: String
    public let title: String
    public let cwd: String
    public let synopsis: String
    public let lastActivity: Date?
    public let pid: Int32?
    public let metadataError: String?
}

public enum CopilotDiscovery {
    private struct Workspace: Decodable {
        let name: String?
        let cwd: String?
        let summary: String?
    }

    private struct Activity: Decodable {
        let updated_at: String?
        let created_at: String?
    }

    static func isSessionID(_ id: String) -> Bool {
        id.count == 36 && UUID(uuidString: id)?.uuidString.lowercased() == id.lowercased()
    }

    static func requirePlainDirectory(_ url: URL) throws {
        var names = Array(url.pathComponents.dropFirst())
        // Foundation resolves /private/var back to the system-owned /var alias.
        if names.first == "var",
           (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var")) == "private/var" {
            names.insert("private", at: 0)
        }
        var component = URL(fileURLWithPath: "/", isDirectory: true)
        for name in names {
            component.appendPathComponent(name)
            let values = try component.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ProtocolError.invalid }
        }
    }

    private static func metadata(_ directory: URL, id: String, pid: Int32) -> (session: DiscoveredCopilot, lastActivity: Date?) {
        var result = DiscoveredCopilot(id: id, pid: pid)
        var lastActivity: Date?
        let path = directory.appendingPathComponent("workspace.yaml")
        do {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil else { throw ProtocolError.invalid }
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 65_536 else {
                throw ProtocolError.invalid
            }
            let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var fileInfo = stat()
            guard fstat(descriptor, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG else { throw ProtocolError.invalid }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else { throw ProtocolError.invalid }
            let workspace = try YAMLDecoder().decode(Workspace.self, from: text)
            lastActivity = values.contentModificationDate
            if let activity = try? YAMLDecoder().decode(Activity.self, from: text),
               let timestamp = activity.updated_at ?? activity.created_at {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let fractional = formatter.date(from: timestamp)
                formatter.formatOptions = [.withInternetDateTime]
                lastActivity = fractional ?? formatter.date(from: timestamp) ?? lastActivity
            }
            result.title = String((workspace.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            result.synopsis = String((workspace.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
            if let cwd = workspace.cwd {
                guard cwd.hasPrefix("/"), cwd.count < 4096 else { throw ProtocolError.invalid }
                result.cwd = cwd
            }
        } catch CocoaError.fileReadNoSuchFile {
            // Newly started sessions may not have saved workspace metadata yet.
        } catch {
            result.metadataError = "Could not read the saved title for \(id.prefix(8)): \(error.localizedDescription)"
        }
        return (result, lastActivity)
    }

    /// Saved workspace metadata only; never reads conversation or event files.
    public static func catalog(in root: URL, livePIDs: Set<Int32>) throws -> [SavedCopilot] {
        do { try requirePlainDirectory(root) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        let manager = FileManager.default
        var result: [SavedCopilot] = []
        for directory in try manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            let id = directory.lastPathComponent
            guard isSessionID(id) else { continue }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let owners = try manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                .compactMap { file -> Int32? in
                    let parts = file.lastPathComponent.split(separator: ".")
                    guard parts.count == 3, parts[0] == "inuse", parts[2] == "lock",
                          let pid = Int32(parts[1]), pid > 0, livePIDs.contains(pid),
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                          values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                    return pid
                }
            let pid = owners.min()
            let metadata = metadata(directory, id: id, pid: pid ?? 0)
            let session = metadata.session
            result.append(SavedCopilot(id: id, title: session.title, cwd: session.cwd,
                synopsis: session.synopsis, lastActivity: metadata.lastActivity, pid: pid,
                metadataError: session.metadataError))
        }
        return result.sorted {
            if $0.lastActivity != $1.lastActivity { return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            return $0.id < $1.id
        }
    }
    public static func runningPIDs() throws -> Set<Int32> {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-u", String(getuid()), "-o", "pid=,comm="]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NotifyDiscovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not list this user's Copilot processes."])
        }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, URL(fileURLWithPath: String(fields[1])).lastPathComponent == "copilot" else { return nil }
            return Int32(fields[0])
        })
    }

    public static func sessions(in root: URL, livePIDs: Set<Int32>) throws -> [DiscoveredCopilot] {
        guard !livePIDs.isEmpty else { return [] }
        func children(_ url: URL) throws -> [URL] {
            do {
                return try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            } catch CocoaError.fileReadNoSuchFile { return [] }
        }
        var result: [DiscoveredCopilot] = []
        for directory in try children(root) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            for file in try children(directory) {
                let parts = file.lastPathComponent.split(separator: ".")
                if parts.count == 3, parts[0] == "inuse", parts[2] == "lock",
                   let pid = Int32(parts[1]), livePIDs.contains(pid) {
                    result.append(metadata(directory, id: directory.lastPathComponent, pid: pid).session)
                    break
                }
            }
        }
        return result
    }
}
