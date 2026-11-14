import Foundation

public enum SetupAgent: String, CaseIterable {
    case copilot, claude
}

public struct AgentSetupSnapshot {
    public let node: URL?
    public let nodeVersion: String?
    public let copilot: URL?
    public let claude: URL?
    public let launcher: URL?
    public let script: URL?
    public let copilotHome: URL
    public var extensionPath: URL { copilotHome.appendingPathComponent("extensions/notify/extension.mjs") }
    public let extensionPresent: Bool
    public let searchPath: String
    public var nodeReady: Bool { nodeVersion.map(AgentSetup.supportsNodeVersion) == true }
    public var resourcesReady: Bool { launcher != nil && script != nil }
}

public enum AgentSetup {
    public static var searchPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ((ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
            .filter { $0.hasPrefix("/") }.joined(separator: ":")
    }

    public static func findExecutable(_ name: String, path: String) -> URL? {
        path.split(separator: ":").filter { $0.hasPrefix("/") }.lazy
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first { url in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
                    && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
            }
    }

    public static func supportsNodeVersion(_ version: String) -> Bool {
        guard version.range(of: #"^v?[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return false }
        let parts = version.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".")
        guard let major = Int(parts[0]), let minor = Int(parts[1]) else { return false }
        return major > 22 || major == 22 && minor >= 18
    }

    public static func inspect(resources: URL?, path: String = searchPath,
                               copilotHome: URL = TerminalSession.copilotHome) throws -> AgentSetupSnapshot {
        let node = findExecutable("node", path: path)
        let version = try node.map { try TerminalSession.run($0.path, ["--version"], timeout: 10) }
        let launcher = resources.flatMap { findExecutable("notify", path: $0.appendingPathComponent("bin").path) }
        let script = resources?.appendingPathComponent("bridge/dist/cli.js")
        let extensionPath = copilotHome.appendingPathComponent("extensions/notify/extension.mjs")
        return AgentSetupSnapshot(node: node, nodeVersion: version,
            copilot: findExecutable("copilot", path: path), claude: findExecutable("claude", path: path),
            launcher: launcher,
            script: script.flatMap { url in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue ? url : nil
            },
            copilotHome: copilotHome, extensionPresent: FileManager.default.fileExists(atPath: extensionPath.path),
            searchPath: path)
    }

    public static func installCopilot(_ snapshot: AgentSetupSnapshot) throws {
        guard snapshot.nodeReady, let node = snapshot.node, let script = snapshot.script else {
            throw NSError(domain: "NotifySetup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Install Node.js 22.18 or newer and reopen an installed copy of Notify before installing its extension."])
        }
        _ = try TerminalSession.run("/usr/bin/env",
            ["PATH=\(snapshot.searchPath)", "COPILOT_HOME=\(snapshot.copilotHome.path)",
             "NODE_TLS_REJECT_UNAUTHORIZED=1", node.path, script.path, "setup-copilot"], timeout: 20)
    }

    public static func launchCommand(launcher: URL, agent: SetupAgent, searchPath: String) -> String {
        "PATH=\(TerminalSession.shellQuote(searchPath)):\"$PATH\" \(TerminalSession.shellQuote(launcher.path)) \(agent.rawValue)"
    }

    public static func failureDescription(_ error: Error) -> String {
        switch error {
        case TerminalSessionError.automation(let detail): return detail.isEmpty ? "The setup command exited unsuccessfully." : detail
        case TerminalSessionError.timedOut: return "The setup command timed out. Check the extension file before retrying; installation may already have completed."
        default: return error.localizedDescription
        }
    }
}
