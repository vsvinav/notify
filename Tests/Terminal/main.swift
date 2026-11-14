import Foundation
import Darwin
@testable import NotifyCore

func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

func rejects(_ message: String, _ body: () throws -> Void) {
    do {
        try body()
        preconditionFailure(message)
    } catch {
        check(!error.localizedDescription.isEmpty, "Errors must be visible")
    }
}

let fm = FileManager.default
// Foundation canonicalizes /private/var back to /var on macOS; this is read-only.
try CopilotDiscovery.requirePlainDirectory(fm.temporaryDirectory.resolvingSymlinksInPath())
let timeoutStart = ProcessInfo.processInfo.systemUptime
do {
    _ = try TerminalSession.run("/bin/sleep", ["5"], timeout: 0.1)
    preconditionFailure("A stalled subprocess must time out")
} catch TerminalSessionError.timedOut {}
check(ProcessInfo.processInfo.systemUptime - timeoutStart < 2, "Timeout must bound subprocess waiting")
check(try TerminalSession.run("/usr/bin/printf", ["%s", "output"], timeout: 2) == "output", "Normal subprocess output survives")
do {
    _ = try TerminalSession.run("/bin/sh", ["-c", "printf 'denied' >&2; exit 7"], timeout: 2)
    preconditionFailure("Subprocess failure must not report success")
} catch TerminalSessionError.automation(let detail) {
    check(detail == "denied", "Retain subprocess failure details")
}
let fixture = URL(fileURLWithPath: fm.currentDirectoryPath)
    .appendingPathComponent(".terminal-checks-\(UUID().uuidString)")
try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: fixture) }
let home = fixture.appendingPathComponent("copilot home")
let root = home.appendingPathComponent("session-state")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let id = "12345678-1234-4234-9234-123456789abc"
let directory = root.appendingPathComponent(id)
try fm.createDirectory(at: directory, withIntermediateDirectories: false)
try Data("""
name: 'Saved: "quoted" chat'
cwd: /projects/saved
summary: |
  First line
  Second line
updated_at: 2026-11-13T20:30:00Z
""".utf8).write(to: directory.appendingPathComponent("workspace.yaml"))
try Data().write(to: directory.appendingPathComponent("inuse.42.lock"))
let saved = try CopilotDiscovery.catalog(in: root, livePIDs: [])
check(saved.count == 1 && saved[0].id == id && saved[0].pid == nil, "Stopped sessions remain in catalog")
check(saved[0].title == "Saved: \"quoted\" chat" && saved[0].synopsis == "First line\nSecond line", "Read bounded YAML metadata")
check(saved[0].cwd == "/projects/saved", "Read saved cwd")
check(saved[0].lastActivity == ISO8601DateFormatter().date(from: "2026-11-13T20:30:00Z"), "Read saved activity timestamp")
let live = try CopilotDiscovery.catalog(in: root, livePIDs: [42])
check(live[0].pid == 42, "Live owner is marked")
let oldDiscovery = try CopilotDiscovery.sessions(in: root, livePIDs: [42])
check(oldDiscovery[0].id == id && oldDiscovery[0].title == saved[0].title, "Preserve live discovery")

let linked = root.appendingPathComponent(UUID().uuidString)
try fm.createSymbolicLink(at: linked, withDestinationURL: directory)
let prefix = root.appendingPathComponent("12345678")
try fm.createDirectory(at: prefix, withIntermediateDirectories: false)
check(try CopilotDiscovery.catalog(in: root, livePIDs: []).count == 1, "Ignore symlink sessions and UUID prefixes")
let linkedRoot = fixture.appendingPathComponent("linked-root")
try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
rejects("Reject symbolic root") { _ = try CopilotDiscovery.catalog(in: linkedRoot, livePIDs: []) }
try Data(repeating: 65, count: 65_537).write(to: directory.appendingPathComponent("workspace.yaml"))
check(try CopilotDiscovery.catalog(in: root, livePIDs: [42])[0].metadataError != nil, "Oversized metadata must be reported")
try fm.removeItem(at: directory.appendingPathComponent("workspace.yaml"))
try fm.createSymbolicLink(at: directory.appendingPathComponent("workspace.yaml"), withDestinationURL: fixture.appendingPathComponent("not-read"))
check(try CopilotDiscovery.catalog(in: root, livePIDs: [42])[0].metadataError != nil, "Do not follow metadata links")

let ps = """
42 41 501 ?? /opt/homebrew/bin/copilot
41 40 501 s007 /bin/zsh
40 1 501 ?? /Applications/iTerm.app/Contents/MacOS/iTerm2
70 71 501 ?? copilot
71 1 502 s008 zsh
80 81 501 ?? copilot
81 80 501 ?? zsh
"""
check(try TerminalSession.terminalTTY(pid: 42, processList: ps, uid: 501) == "/dev/ttys007", "Walk same-user ancestry to terminal")
check(try TerminalSession.terminalTTY(pid: 41, processList: ps, uid: 501) == "/dev/ttys007", "Direct TTY")
rejects("Reject foreign ancestors") { _ = try TerminalSession.terminalTTY(pid: 70, processList: ps, uid: 501) }
rejects("Reject ancestry cycles") { _ = try TerminalSession.terminalTTY(pid: 80, processList: ps, uid: 501) }
rejects("Reject absent PID") { _ = try TerminalSession.terminalTTY(pid: 99, processList: ps, uid: 501) }
rejects("Reject foreign PID") { _ = try TerminalSession.terminalTTY(pid: 71, processList: ps, uid: 501) }
check(try TerminalSession.terminalTTY(pid: 5, processList: "5 1 501 ttys123 copilot", uid: 501) == "/dev/ttys123", "Accept full tty name")

let hostile = "spaces ' \" ; $(touch SHOULD_NOT_EXIST)\nline"
let shell = Process(), output = Pipe()
shell.executableURL = URL(fileURLWithPath: "/bin/sh")
shell.arguments = ["-c", "printf %s \(TerminalSession.shellQuote(hostile))"]
shell.standardOutput = output
try shell.run()
let echoed = output.fileHandleForReading.readDataToEndOfFile()
shell.waitUntilExit()
check(String(decoding: echoed, as: UTF8.self) == hostile, "Shell quoting preserves literals without executing input")
check(!fm.fileExists(atPath: "SHOULD_NOT_EXIST"), "No command injection")
let executable = URL(fileURLWithPath: "/bin/echo")
let command = try TerminalSession.resumeCommand(id: id, cwd: fixture.path, copilotHome: home,
    executableURL: executable, livePIDs: [])
check(command.contains("--resume") && command.contains(id), "Resume exact UUID")
check(command.contains("COPILOT_HOME="), "Launch uses the same configured state directory as ownership checks")
let quotedDirectory = fixture.appendingPathComponent("project ' \" ; $HOME")
let quotedExecutable = fixture.appendingPathComponent("copilot ' \" ; $HOME")
try fm.createDirectory(at: quotedDirectory, withIntermediateDirectories: false)
try Data("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$COPILOT_HOME\" \"$#\" \"$@\"\n".utf8).write(to: quotedExecutable)
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quotedExecutable.path)
let quotedCommand = try TerminalSession.resumeCommand(id: id, cwd: quotedDirectory.path, copilotHome: home,
    executableURL: quotedExecutable, livePIDs: [])
let launchCheck = Process(), launchOutput = Pipe()
launchCheck.executableURL = URL(fileURLWithPath: "/bin/sh")
// Run only a local argument-printing fixture, without the post-exit login shell.
launchCheck.arguments = ["-c", quotedCommand.replacingOccurrences(of: "; exec /bin/zsh -l", with: "")]
launchCheck.standardOutput = launchOutput
try launchCheck.run()
let arguments = launchOutput.fileHandleForReading.readDataToEndOfFile()
launchCheck.waitUntilExit()
check(launchCheck.terminationStatus == 0 &&
    String(decoding: arguments, as: UTF8.self) == "\(quotedDirectory.path)\n\(home.path)\n2\n--resume\n\(id)\n",
    "Nested launch quoting preserves cwd, home, executable path, and exact arguments")
rejects("Reject live owner") {
    _ = try TerminalSession.resumeCommand(id: id, cwd: fixture.path, copilotHome: home,
        executableURL: executable, livePIDs: [42])
}
for invalid in ["12345678", id + ";echo", "--help", " \(id)", "{\(id)}"] {
    rejects("Reject invalid UUID") {
        _ = try TerminalSession.resumeCommand(id: invalid, cwd: fixture.path, copilotHome: home,
            executableURL: executable, livePIDs: [])
    }
}
for invalid in ["relative", fixture.appendingPathComponent("missing").path, fixture.path + "\0"] {
    rejects("Reject invalid cwd") {
        _ = try TerminalSession.resumeCommand(id: id, cwd: invalid, copilotHome: home,
            executableURL: executable, livePIDs: [])
    }
}
rejects("Reject missing executable") {
    _ = try TerminalSession.resumeCommand(id: id, cwd: fixture.path, copilotHome: home,
        executableURL: fixture.appendingPathComponent("missing"), livePIDs: [])
}
rejects("Reject unsaved session") {
    _ = try TerminalSession.resumeCommand(id: UUID().uuidString, cwd: fixture.path, copilotHome: home,
        executableURL: executable, livePIDs: [])
}
do {
    try await TerminalSession.focus(pid: -1)
    preconditionFailure("An absent PID must not trigger AppleScript")
} catch TerminalSessionError.noTTY {}
do {
    try await TerminalSession.resume(id: "--help", cwd: fixture.path, copilotHome: home, executableURL: executable)
    preconditionFailure("Invalid resume must not trigger AppleScript")
} catch TerminalSessionError.invalidSession {}
for (name, source) in [("focus", TerminalSession.focusScript), ("resume", TerminalSession.resumeScript)] {
    let compiler = Process(), errors = Pipe()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
    compiler.arguments = ["-o", fixture.appendingPathComponent(name + ".scpt").path, "-e", source]
    compiler.standardError = errors
    try compiler.run()
    let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
    compiler.waitUntilExit()
    check(compiler.terminationStatus == 0, "Compile \(name) against installed iTerm2 dictionary: \(String(decoding: diagnostics, as: UTF8.self))")
}
func validateITermFixture(in fixture: URL) async throws {
    let fm = FileManager.default
    func script(_ source: String, _ arguments: [String] = []) throws -> String {
        try TerminalSession.run("/usr/bin/osascript", ["-e", source] + arguments)
    }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "NotifyTerminalFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let original = try script("""
    tell application id "com.googlecode.iterm2"
        if (count of windows) is 0 then return "0"
        return id of current window
    end tell
    """)
    let info = fixture.appendingPathComponent("iterm-launch-info")
    let executable = fixture.appendingPathComponent("iterm-fixture-copilot")
    let home = fixture.appendingPathComponent("iterm fixture home")
    let id = UUID().uuidString.lowercased()
    try fm.createDirectory(at: home.appendingPathComponent("session-state").appendingPathComponent(id), withIntermediateDirectories: true)
    try Data("""
    #!/bin/sh
    printf '%s\\n' "$$" "$PWD" "$COPILOT_HOME" "$#" "$@" > \(TerminalSession.shellQuote(info.path))
    exec /bin/sleep 120
    """.utf8).write(to: executable)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let command = try TerminalSession.resumeCommand(id: id, cwd: fixture.path, copilotHome: home,
        executableURL: executable, livePIDs: CopilotDiscovery.runningPIDs())
    var ownedWindow: String?
    var cleaned = false
    func cleanup() throws {
        if let ownedWindow {
            _ = try script("""
            on run argv
                set ownedID to (item 1 of argv) as integer
                set originalID to (item 2 of argv) as integer
                tell application id "com.googlecode.iterm2"
                    if (id of windows) contains ownedID then close (window id ownedID)
                    if (id of windows) contains originalID then select (window id originalID)
                end tell
            end run
            """, [ownedWindow, original])
            // Closing is asynchronous; inspect a fresh application event, not cached specifiers.
            var removed = false
            for _ in 0..<50 {
                let state = try script("""
                on run argv
                    set ownedID to (item 1 of argv) as integer
                    set originalID to (item 2 of argv) as integer
                    tell application id "com.googlecode.iterm2"
                        if (id of windows) contains ownedID then return "pending"
                        if (id of windows) contains originalID then
                            if id of current window is not originalID then error "Original window selection was not restored."
                        end if
                        return "removed"
                    end tell
                end run
                """, [ownedWindow, original])
                if state == "removed" { removed = true; break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            try require(removed, "Disposable window did not close.")
        }
    }
    defer {
        if !cleaned {
            do { try cleanup() }
            catch { fputs("Disposable iTerm fixture cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
    }
    ownedWindow = try script(TerminalSession.resumeScript, [command])
    try require(Int(ownedWindow!) != nil, "Launch must return the exact newly created window ID.")
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !fm.fileExists(atPath: info.path) && ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let launchInfo = try String(contentsOf: info, encoding: .utf8).split(separator: "\n").map(String.init)
    try require(launchInfo.count == 6, "Disposable executable must record launch arguments.")
    try require(Array(launchInfo.dropFirst()) == [fixture.path, home.path, "2", "--resume", id],
        "iTerm must launch the exact synthetic UUID, cwd, home, and original resume arguments.")
    guard let pid = Int32(launchInfo[0]) else {
        throw NSError(domain: "NotifyTerminalFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing owned process PID"])
    }
    let ownedTTY = try script("""
    on run argv
        set ownedID to (item 1 of argv) as integer
        tell application id "com.googlecode.iterm2" to return tty of current session of (window id ownedID)
    end run
    """, [ownedWindow!])
    let processes = try TerminalSession.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,tty=,comm="])
    try require(try TerminalSession.terminalTTY(pid: pid, processList: processes, uid: getuid()) == ownedTTY,
        "Disposable process and newly created iTerm session must have the same exact TTY.")
    if original != "0" {
        _ = try script("""
        on run argv
            set originalID to (item 1 of argv) as integer
            tell application id "com.googlecode.iterm2" to select (window id originalID)
        end run
        """, [original])
    }
    try await TerminalSession.focus(pid: pid)
    let selected = try script("""
    tell application id "com.googlecode.iterm2"
        return (id of current window as text) & linefeed & (tty of current session of current window)
    end tell
    """)
    try require(selected == "\(ownedWindow!)\n\(ownedTTY)", "Production focus must select the exact owned window and TTY.")
    try cleanup()
    cleaned = true
    print("Disposable iTerm launch arguments and production PID focus validated; owned window closed and original selection restored")
}
if CommandLine.arguments.contains("--iterm-fixture") {
    try await validateITermFixture(in: fixture)
}
if CommandLine.arguments.contains("--live-catalog") {
    let realRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/session-state")
    let realCatalog = try CopilotDiscovery.catalog(in: realRoot, livePIDs: CopilotDiscovery.runningPIDs())
    check(!realCatalog.isEmpty, "Read-only real home catalog should contain saved sessions")
    check(realCatalog.allSatisfy { $0.metadataError == nil }, "Real saved metadata should decode")
    print("Read-only real home catalog validated (no session content displayed)")
}
print("Terminal catalog, quoting, validation, and TTY checks passed")
