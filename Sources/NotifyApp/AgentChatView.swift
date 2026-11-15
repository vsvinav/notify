import SwiftUI
import NotifyCore

struct AgentChatView: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    let agentID: String?
    @State private var follow = true
    @State private var confirmAction: String?
    private var targetName: String {
        guard let agentID else { return "Main agent" }
        return session.team?.agents.first { $0.id == agentID }?.name ?? "Unavailable subagent"
    }
    private var draft: String { store.steeringWorkspace.draft(sessionID: session.id, agentID: agentID) }
    private var unavailable: String? { store.steeringWorkspace.unavailableReason(session: session, agentID: agentID) }
    private var commands: [ControlReceipt] {
        (store.steeringWorkspace.history[session.id] ?? []).filter { $0.agentID == agentID }
    }
    private var sending: Bool { (store.steeringWorkspace.history[session.id] ?? []).contains { $0.status == "sending" } }
    private var valid: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf16.count <= 16000 }
    private var events: [ActivityEntry] {
        let ownIDs = Set(commands.map(\.id))
        return session.activity.entries.filter {
            if ResponseFeed.includes(kind: $0.kind, agentID: $0.agentID, target: agentID) { return true }
            // Child runtime prompts may include injected instructions and lack a client correlation ID.
            return agentID == nil && $0.agentID == nil && $0.kind == "user" &&
                !ownIDs.contains($0.clientTurnID ?? "")
        }
    }
    var rows: [ChatRow] {
        (events.map(ChatRow.activity) + commands.map(ChatRow.command)).map { (row: $0, date: $0.date) }.sorted {
            if $0.date == $1.date { return $0.row.id < $1.row.id }
            return $0.date < $1.date
        }.map(\.row)
    }
    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if agentID != nil {
                    AgentIllustration(presence: .resting, accent: store.sessionColor(session), portrait: true)
                        .frame(width: 40, height: 40).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(targetName).font(WorkspaceType.text(20, strong: true)).lineLimit(2).textSelection(.enabled)
                    if agentID != nil {
                        Text("Subagent chat · messages go to this helper only")
                            .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer()
                CopyTextButton(text: rows.map(\.copyText).joined(separator: "\n\n"), label: "Copy chat")
            }
            .padding(agentID == nil ? 0 : 10)
            .background(agentID == nil ? Color.clear : store.sessionColor(session).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
            AgentActivityPanel(session: session, agentID: agentID)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Text(agentID == nil ? "Messages observed while Notify is connected. Earlier history stays in the terminal." :
                            "This helper's observed replies and messages you send here. Internal prompts are not shown.")
                            .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                        if rows.isEmpty {
                            Text("Start a conversation with \(targetName).")
                                .font(WorkspaceType.text(14)).foregroundStyle(Palette.muted).padding(.vertical, 16)
                        }
                        ForEach(rows) { row in
                            switch row {
                            case .activity(let entry):
                                if entry.kind == "assistant" { ActivityRow(entry: entry) }
                                else { userMessage(entry.detail, status: nil) }
                            case .command(let receipt):
                                userMessage(receipt.action == "stop" ? "Stop requested" : receipt.message, status: receipt)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }.background(ActivityScrollIntent { follow = false })
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
                    .onChange(of: rows) { _, _ in if follow { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
                HStack {
                    Toggle("Follow chat", isOn: $follow).toggleStyle(.checkbox)
                        .onChange(of: follow) { _, enabled in if enabled { proxy.scrollTo("chat-bottom", anchor: .bottom) } }
                    Spacer()
                    Button("Latest") { follow = true; proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }.font(WorkspaceType.text(11))
            }.frame(maxHeight: .infinity)
            Divider()
            if let unavailable {
                Text(unavailable).font(WorkspaceType.text(12)).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Message \(targetName)...", text: Binding(
                get: { draft },
                set: { store.steeringWorkspace.setDraft($0, sessionID: session.id, agentID: agentID) }
            ), axis: .vertical).lineLimit(2...4).textFieldStyle(.plain).font(WorkspaceType.text(13))
                .padding(10).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
                .disabled(unavailable != nil).accessibilityLabel("Message \(targetName)")
            if draft.utf16.count > 16000 {
                Text("Shorten your message to 16,000 characters.").font(WorkspaceType.text(11)).foregroundStyle(Palette.error)
            }
            HStack(spacing: 10) {
                Button("Send") { store.steer(session.id, action: "queue", agentID: agentID) }
                    .buttonStyle(ReplyButtonStyle(primary: true)).disabled(unavailable != nil || sending || !valid)
                if agentID == nil {
                    Button("Interrupt") { confirmAction = "interrupt" }.buttonStyle(ReplyButtonStyle(primary: false))
                        .disabled(unavailable != nil || sending || !valid)
                }
                Spacer(minLength: 0)
                Button(agentID == nil ? "Stop main" : "Stop subagent") { confirmAction = "stop" }
                    .buttonStyle(ReplyButtonStyle(primary: true, destructive: true))
                    .disabled(sending || store.steeringWorkspace.unavailableReason(session: session, agentID: agentID, action: "stop") != nil)
            }
            Text(agentID == nil ? "Send queues your message if the main agent is busy." :
                "Send steers this helper only. Other agents keep working.")
                .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
        }.alert(confirmAction == "stop" ? "Stop \(targetName)?" : "Interrupt the main agent?",
                isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } })) {
            Button("Cancel", role: .cancel) { confirmAction = nil }
            Button(confirmAction == "stop" ? "Stop" : "Interrupt and send", role: .destructive) {
                if let action = confirmAction { store.steer(session.id, action: action, agentID: agentID) }
                confirmAction = nil
            }
        } message: {
            Text(agentID != nil ? "Cancel this helper's work. Its descendants may also stop; the main agent and unrelated helpers are not stopped. Existing changes are not undone." :
                confirmAction == "stop" ? "Stop current work and clear queued main prompts. Existing changes are not undone; external processes may continue." :
                    "Interrupt the main turn and send your message. Queued prompts and background work are preserved.")
        }
    }
    private func userMessage(_ text: String, status: ControlReceipt?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You").font(WorkspaceType.text(12, strong: true)).foregroundStyle(Palette.muted)
            Text(text).font(WorkspaceType.text(13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let status {
                Text(status.status.capitalized + " · " + status.detail).font(WorkspaceType.text(11))
                    .foregroundStyle(["failed", "unknown"].contains(status.status) ? Palette.error : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CopyTextButton(text: text, label: "Copy message")
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AgentActivityPanel: View {
    let session: SessionRecord
    let agentID: String?
    @State private var expanded = true
    var reported: [ActivityEntry] {
        Array(session.activity.entries.filter {
            $0.agentID == agentID && ["tool", "reasoning", "status"].contains($0.kind)
        }.suffix(12))
    }
    private var state: String {
        guard let agentID else { return AgentPresence(session: session).title }
        guard session.connected, session.team?.error == nil,
              let agent = session.team?.agents.first(where: { $0.id == agentID }) else { return "Unavailable" }
        return agent.status == .running ? "Working" : agent.status == .idle ? "At rest" :
            agent.status == .cancelled ? "Stopped" : agent.status.rawValue.capitalized
    }
    var body: some View {
        let entries = reported
        DisclosureGroup(isExpanded: $expanded) {
            if entries.isEmpty {
                Text("No tool or thinking activity has been reported for this agent yet.")
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entries.reversed()) { entry in
                            DisclosureGroup {
                                ScrollView(.horizontal) {
                                    Text(entry.detail)
                                        .font(entry.kind == "tool" ? .system(size: 12, design: .monospaced) : WorkspaceType.text(12))
                                        .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                                }
                                CopyTextButton(text: entry.detail, label: "Copy activity")
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Label(entry.kind == "reasoning" ? "Thinking" : entry.kind == "tool" ? "Tool" : "Status",
                                          systemImage: entry.kind == "reasoning" ? "ellipsis.bubble" :
                                            entry.kind == "tool" ? "wrench.and.screwdriver" : "info.circle")
                                        .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                                    Text(entry.title).font(WorkspaceType.text(12, strong: true)).lineLimit(1).help(entry.title)
                                    Spacer(minLength: 6)
                                    Text(entry.status.capitalized).font(WorkspaceType.text(11))
                                        .foregroundStyle(entry.status == "failed" ? Palette.error : Palette.muted)
                                }
                            }
                        }
                    }.padding(.vertical, 4)
                }.frame(height: min(72, max(36, CGFloat(entries.count) * 28 + 8))).scrollIndicators(.visible)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label("Tools & thinking", systemImage: "wrench.and.screwdriver")
                        .font(WorkspaceType.text(12, strong: true))
                        .help("Up to 12 agent-published updates. Reported statuses are not proof of task success.")
                    Spacer(minLength: 4)
                    Text(state).font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                }
                if !expanded {
                    Text(entries.last?.title ?? "Waiting for an activity update")
                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
        }.padding(10).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

enum ChatRow: Identifiable, Equatable {
    case activity(ActivityEntry), command(ControlReceipt)
    var id: String {
        switch self {
        case .activity(let entry): "event:" + entry.id
        case .command(let receipt): "command:" + receipt.id
        }
    }
    var date: Date {
        switch self {
        case .command(let receipt): return receipt.createdAt
        case .activity(let entry):
            return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(entry.timestamp)) ??
                (try? Date.ISO8601FormatStyle().parse(entry.timestamp)) ?? .distantPast
        }
    }
    var copyText: String {
        switch self {
        case .activity(let entry): "\(entry.kind == "assistant" ? "Agent" : "You"):\n\(entry.detail)"
        case .command(let receipt): "You:\n\(receipt.action == "stop" ? "Stop requested" : receipt.message)\n[\(receipt.status)]"
        }
    }
}
