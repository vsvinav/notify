import Foundation
import NotifyCore

struct SessionTerminal {
    var unavailable: (SessionRecord) -> String?
    var owner: (SessionRecord) async throws -> Int32?
    var launch: (SessionRecord) async throws -> Void
    var focus: (Int32) async throws -> Void
    var connectionTimeout: TimeInterval = 30

    static let live = SessionTerminal(
        unavailable: { session in
            guard let executable = AgentSetup.findExecutable(session.agent, path: AgentSetup.searchPath) else {
                return "The original \(session.agent) CLI is unavailable on the Mac. Check setup."
            }
            return TerminalSession.resumeUnavailableReason(agent: session.agent,
                id: session.sourceSessionID ?? session.id, cwd: session.cwd, executableURL: executable)
        },
        owner: { session in
            try await Task.detached {
                let id = session.sourceSessionID ?? session.id
                if session.agent == "copilot" {
                    return try CopilotDiscovery.sessions(in: TerminalSession.copilotHome.appendingPathComponent("session-state"),
                        livePIDs: CopilotDiscovery.runningPIDs()).first { $0.id == id }?.pid
                }
                return try ClaudeDiscovery.sessions(livePIDs: ClaudeDiscovery.runningPIDs()).first { $0.id == id }?.pid
            }.value
        },
        launch: { session in
            guard let executable = AgentSetup.findExecutable(session.agent, path: AgentSetup.searchPath) else {
                throw TerminalSessionError.missingExecutable
            }
            if session.agent == "copilot" {
                try await TerminalSession.resume(id: session.sourceSessionID ?? session.id, cwd: session.cwd, executableURL: executable)
            } else {
                try await TerminalSession.resumeClaude(id: session.sourceSessionID ?? session.id, cwd: session.cwd, executableURL: executable)
            }
        },
        focus: { try await TerminalSession.focus(pid: $0) })
}
