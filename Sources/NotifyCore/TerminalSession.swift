import Foundation
import Darwin

public enum TerminalSessionError: LocalizedError {
    case invalidSession, invalidDirectory, missingExecutable, missingITerm, activeOwner(Int32), noTTY
    case automation(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidSession: return "The saved session must have an exact UUID and an existing, non-linked session directory."
        case .invalidDirectory: return "The project directory must be an existing absolute directory."
        case .missingExecutable: return "The Copilot executable is not installed or is not executable."
        case .missingITerm: return "iTerm2 is not installed at /Applications/iTerm.app."
        case .activeOwner(let pid): return "This chat is already running (PID \(pid)). Open its existing terminal instead."
        case .noTTY: return "No terminal belonging to this user's process could be identified."
        case .automation(let detail): return "iTerm2 could not complete the action: \(detail)"
        case .timedOut: return "The terminal action timed out. Check iTerm2 before retrying; the action may already have completed."
        }
    }
}

public enum TerminalSession {
    public static var copilotHome: URL {
        ProcessInfo.processInfo.environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
    }

    public static func focus(pid: Int32) async throws {
        try await Task.detached(priority: .userInitiated) {
            try requireITerm()
            let processes = try run("/bin/ps", ["-axo", "pid=,ppid=,uid=,tty=,comm="])
            let tty = try terminalTTY(pid: pid, processList: processes, uid: getuid())
            _ = try run("/usr/bin/osascript", ["-e", focusScript, tty])
        }.value
    }

    public static func resume(id: String, cwd: String, copilotHome: URL = TerminalSession.copilotHome,
                              executableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/copilot")) async throws {
        try await Task.detached(priority: .userInitiated) {
            try requireITerm()
            let command = try resumeCommand(id: id, cwd: cwd, copilotHome: copilotHome,
                executableURL: executableURL, livePIDs: CopilotDiscovery.runningPIDs())
            _ = try run("/usr/bin/osascript", ["-e", resumeScript, command])
        }.value
    }

    public static func resumeClaude(id: String, cwd: String,
                                    executableURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try requireITerm()
            guard UUID(uuidString: id) != nil else { throw TerminalSessionError.invalidSession }
            var isDirectory: ObjCBool = false
            guard cwd.hasPrefix("/"), !cwd.utf8.contains(0),
                  FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw TerminalSessionError.invalidDirectory }
            guard executableURL.isFileURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw TerminalSessionError.missingExecutable
            }
            let command = "cd \(shellQuote(cwd)) && \(shellQuote(executableURL.path)) --resume \(shellQuote(id)); exec /bin/zsh -l"
            _ = try run("/usr/bin/osascript", ["-e", resumeScript, command])
        }.value
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func resumeCommand(id: String, cwd: String, copilotHome: URL, executableURL: URL,
                              livePIDs: Set<Int32>) throws -> String {
        guard CopilotDiscovery.isSessionID(id) else { throw TerminalSessionError.invalidSession }
        var isDirectory: ObjCBool = false
        guard cwd.hasPrefix("/"), !cwd.utf8.contains(0),
              FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TerminalSessionError.invalidDirectory
        }
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              !executableURL.path.utf8.contains(0),
              FileManager.default.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw TerminalSessionError.missingExecutable
        }
        let directory = copilotHome.appendingPathComponent("session-state").appendingPathComponent(id)
        do { try CopilotDiscovery.requirePlainDirectory(directory) }
        catch { throw TerminalSessionError.invalidSession }
        // A live owner's lock must block launch even when its metadata cannot be decoded.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let parts = file.lastPathComponent.split(separator: ".")
            if parts.count == 3, parts[0] == "inuse", parts[2] == "lock",
               let pid = Int32(parts[1]), pid > 0, livePIDs.contains(pid) {
                throw TerminalSessionError.activeOwner(pid)
            }
        }
        let launch = "cd \(shellQuote(cwd)) && /usr/bin/env \(shellQuote("COPILOT_HOME=" + copilotHome.path)) "
            + "\(shellQuote(executableURL.path)) --resume \(shellQuote(id)); exec /bin/zsh -l"
        return "/bin/sh -c \(shellQuote(launch))"
    }

    static func terminalTTY(pid: Int32, processList: String, uid: uid_t) throws -> String {
        var processes: [Int32: (parent: Int32, uid: uid_t, tty: String)] = [:]
        for line in processList.split(separator: "\n") {
            let fields = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
            guard fields.count == 5, let processID = Int32(fields[0]), let parent = Int32(fields[1]),
                  let owner = uid_t(fields[2]) else { continue }
            processes[processID] = (parent, owner, String(fields[3]))
        }
        var current = pid
        var visited: Set<Int32> = []
        while current > 1, visited.insert(current).inserted,
              let process = processes[current], process.uid == uid {
            let tty = process.tty
            if tty.range(of: #"^(?:/dev/)?tty[a-zA-Z0-9]+$"#, options: .regularExpression) != nil {
                return tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
            }
            if tty.range(of: #"^s[0-9]+$"#, options: .regularExpression) != nil { return "/dev/tty" + tty }
            if tty != "??" && tty != "?" && tty != "-" { throw TerminalSessionError.noTTY }
            current = process.parent
        }
        throw TerminalSessionError.noTTY
    }

    private static func requireITerm() throws {
        guard FileManager.default.fileExists(atPath: "/Applications/iTerm.app") else { throw TerminalSessionError.missingITerm }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            try? pipe.fileHandleForReading.close()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw TerminalSessionError.timedOut }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                guard output.count <= 1_048_576 else { throw TerminalSessionError.automation("Terminal response exceeded the size limit.") }
            } else if count == 0 && !process.isRunning {
                break
            } else {
                if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else { throw TerminalSessionError.automation(text) }
        return text
    }

    static let focusScript = """
    on run argv
        set wantedTTY to item 1 of argv
        if application id "com.googlecode.iterm2" is not running then error "iTerm2 is not running; no existing terminal can be selected."
        tell application id "com.googlecode.iterm2"
            set matches to {}
            repeat with w in windows
                set windowID to id of w
                repeat with tabNumber from 1 to count of tabs of w
                    repeat with s in sessions of tab tabNumber of w
                        if tty of s is wantedTTY then
                            set end of matches to {windowID, tabNumber, id of s}
                        end if
                    end repeat
                end repeat
            end repeat
            if (count of matches) is 0 then error "No iTerm2 session matches this terminal. It may have closed or belong to another terminal app."
            if (count of matches) is not 1 then error "More than one iTerm2 session matches this terminal; no session was selected."
            set target to item 1 of matches
            set matchedWindow to window id (item 1 of target)
            set matchedTab to tab (item 2 of target) of matchedWindow
            set matchedSession to session id (item 3 of target) of matchedTab
            if tty of matchedSession is not wantedTTY then error "The matching terminal changed; no session was selected."
            set miniaturized of matchedWindow to false
            select matchedWindow
            select matchedTab
            select matchedSession
            activate
        end tell
    end run
    """

    static let resumeScript = """
    on run argv
        set launchCommand to item 1 of argv
        tell application id "com.googlecode.iterm2"
            set newWindow to (create window with default profile command launchCommand)
            select newWindow
            activate
            return id of newWindow
        end tell
    end run
    """
}
