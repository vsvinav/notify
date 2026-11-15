import SwiftUI
import NotifyCore

struct IdleSubagentCleanupView: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var attempts: [IdleCleanupAttempt] = []
    private var supported: Int {
        store.sessions.filter {
            store.steeringWorkspace.unavailableReason(session: $0, agentID: nil, action: "stop_idle_subagents") == nil
        }.count
    }
    private var sending: Bool {
        attempts.contains { attempt in
            guard let id = attempt.commandID else { return false }
            return store.steeringWorkspace.receipt(sessionID: attempt.sessionID, commandID: id)?.status == "sending"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stop idle subagents").font(WorkspaceType.text(25, strong: true))
            Text("Across all connected sessions").font(WorkspaceType.text(14, strong: true))
            Text("Checks \(supported) supported session\(supported == 1 ? "" : "s"). Stops only helpers continuously observed idle for more than 10 minutes. Nothing runs automatically.")
            Text("Main agents and active descendants are protected. Unknown idle ages or ancestry are skipped. Existing work and files are not deleted.")
                .foregroundStyle(Palette.muted)
            Text("Copilot needs the updated Notify extension. Claude hooks cannot stop subagents. Observation starts when the extension connects; an agent's creation time is not its idle time.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.amber)
            if !attempts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(attempts) { attempt in
                            let receipt = attempt.commandID.flatMap {
                                store.steeringWorkspace.receipt(sessionID: attempt.sessionID, commandID: $0)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(attempt.name).font(WorkspaceType.text(13, strong: true))
                                Text(receipt.map { "\($0.status.capitalized): \($0.detail)" } ??
                                     attempt.detail ?? "Result unavailable. Check the original terminal.")
                                    .foregroundStyle(["failed", "unknown"].contains(receipt?.status ?? "") ? Palette.error : Palette.muted)
                            }.textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if attempts.isEmpty {
                    Button("Stop idle subagents") { attempts = store.stopIdleSubagents() }
                        .buttonStyle(ReplyButtonStyle(primary: true, destructive: true))
                        .disabled(supported == 0)
                } else if sending {
                    ProgressView().controlSize(.small)
                    Text("Waiting for runtime results").foregroundStyle(Palette.muted)
                }
            }
        }.font(WorkspaceType.text(13)).foregroundStyle(Palette.ink)
            .padding(24).frame(width: 540).background(Palette.surface)
    }
}
