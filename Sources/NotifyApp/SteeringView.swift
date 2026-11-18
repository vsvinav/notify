import SwiftUI
import NotifyCore

struct AutoYesWarning: View {
    var body: some View {
        Label("Auto-yes ON. Not recommended: AI can make mistakes. Commands may modify or delete files.", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
    }
}

struct DangerousAutoYesWarning: View {
    @ObservedObject var store: Store
    let sessionID: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dangerous Auto-yes is ON").font(.system(size: 12, weight: .semibold))
                    Text("Approves tools, including destructive actions.").font(.system(size: 11))
                }
            } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            Spacer(minLength: 0)
            Button("Turn off") { store.setSessionDangerousAutoYes(sessionID, enabled: false) }
                .controlSize(.small)
        }.foregroundStyle(Palette.error).padding(10)
            .background(Palette.error.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SessionAutoYesView: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var showsDangerWarning = true
    @State private var confirming = false
    @State private var confirmingDangerous = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Session Auto-yes (not recommended)", isOn: Binding(
                get: { store.automation.enabled.contains(session.id) },
                set: { if $0 { confirming = true } else { store.setSessionAutoYes(session.id, enabled: false) } }
            )).toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                .disabled(!session.connected || !session.canAutoYes)
                .alert("Enable Auto-yes for this session?", isPresented: $confirming) {
                    Button("Cancel", role: .cancel) {}
                    Button("Enable Auto-yes", role: .destructive) { store.setSessionAutoYes(session.id, enabled: true) }
                } message: {
                    Text("Not recommended. AI can make mistakes.\n\nNew eligible tool permissions in “\(session.name)” will be approved automatically. Commands may modify or delete files or perform external actions. Questions, existing prompts, managed restrictions and sandbox bypasses remain manual.\n\nTurns off on disconnect, app restart, Stop, or an approval/steering error. Turning it off cannot undo approvals already sent. Safe-read approval is a separate setting.")
                }
            if store.automation.enabled.contains(session.id) { AutoYesWarning() }
            Toggle("Dangerous Auto-yes", isOn: Binding(
                get: { store.automation.dangerous.contains(session.id) },
                set: { if $0 { confirmingDangerous = true } else { store.setSessionDangerousAutoYes(session.id, enabled: false) } }
            )).toggleStyle(.switch).controlSize(.small).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.error)
                .disabled(!session.connected || !session.canAutoYes)
                .alert("Enable Dangerous Auto-yes?", isPresented: $confirmingDangerous) {
                    Button("Cancel", role: .cancel) {}
                    Button("Enable dangerous mode", role: .destructive) { store.setSessionDangerousAutoYes(session.id, enabled: true) }
                } message: {
                    Text("For “\(session.name)” only.\n\nApproves currently waiting and future eligible tool permissions, including commands that delete files or perform external actions. This project name does not limit access to its files.\n\nQuestions, browser actions and agent-enforced restrictions stay manual. Normal Session Auto-yes will turn off.\n\nResets on disconnect, restart, Stop or delivery/steering error. Turning it off cannot undo approvals already sent.")
                }
            if store.automation.dangerous.contains(session.id), showsDangerWarning {
                DangerousAutoYesWarning(store: store, sessionID: session.id)
            }
            Text("Includes waiting eligible tools. Questions and restricted requests still need you.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}

struct FloatingSteeringView: View {
    @ObservedObject var store: Store
    let sessionID: String
    let openCenter: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Steer an agent").font(.system(size: 11)).foregroundStyle(Palette.noticeMuted)
                Spacer()
                Button("Close") { store.closeSteering() }.buttonStyle(.plain).font(.system(size: 11))
            }
            Picker("Session", selection: Binding(get: { sessionID }, set: { store.showSteering($0) })) {
                ForEach(store.sessions) { session in
                    Text("\(session.name) / \(session.id.prefix(8))").tag(session.id)
                }
            }.labelsHidden()
            if let session = store.registry.sessions[sessionID] {
                Text(session.cwd.isEmpty ? session.name : session.cwd).font(.system(size: 10))
                    .foregroundStyle(Palette.noticeMuted).lineLimit(2).help(session.cwd)
                SteeringEditor(store: store, session: session, floating: true).id(session.id)
            } else {
                Text("This session is no longer available. Choose another session.").font(.system(size: 12))
                Spacer()
            }
            HStack {
                Button("Control center") { store.select(sessionID); openCenter() }
                Spacer()
                if !store.floatingRequests.isEmpty {
                    Button("Approvals (\(store.floatingRequests.count))") { store.closeSteering() }
                }
            }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.noticeMuted)
        }.frame(maxHeight: .infinity, alignment: .top)
    }
}

struct SteeringEditor: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var floating = false
    var compact = false
    private var secondary: Color { floating ? Palette.noticeMuted : Palette.muted }
    @State private var confirmAction: String?
    private var draft: String { store.steeringWorkspace.drafts[session.id] ?? "" }
    private var enabled: Bool {
        session.connected && session.canSteer && store.steeringWorkspace.receipts[session.id]?.status != "sending"
    }
    private var validText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf16.count <= 16000 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
            SessionAutoYesView(store: store, session: session)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !session.connected || !session.canSteer {
                        Text(session.connected
                             ? "Remote controls are unavailable. For an original Copilot terminal, reload its Notify extension to load this update. SDK launchers and Claude steering are not supported."
                             : "Connect the Notify extension in this Copilot terminal before steering it.")
                            .font(.system(size: 12)).foregroundStyle(Palette.amber)
                    }
                    if let receipt = store.steeringWorkspace.receipts[session.id] {
                        Text(receipt.detail).font(.system(size: 12))
                            .foregroundStyle(["unknown", "failed"].contains(receipt.status) ? Palette.amber : secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if !compact {
                    Text("Agent activity").font(.system(size: 11)).foregroundStyle(secondary)
                    Text(session.summary.isEmpty ? stateName(session.state) : session.summary).font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    if !session.output.isEmpty {
                        Text(String(session.output.suffix(8000))).font(.system(size: 11)).foregroundStyle(secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    }
                    if let error = store.sessionErrors[session.id] ?? store.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: compact ? 0 : 45, maxHeight: compact ? 90 : .infinity).scrollIndicators(.visible)
            TextField("Direction for this agent...", text: Binding(
                get: { draft }, set: { store.steeringWorkspace.drafts[session.id] = $0 }
            ), axis: .vertical).lineLimit(3...6).textFieldStyle(.plain).font(.system(size: 12))
                .padding(10).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Direction for \(session.name)")
                .disabled(!session.connected || !session.canSteer)
            if draft.utf16.count > 16000 { Text("Shorten your message to 16,000 characters.").font(.system(size: 10)).foregroundStyle(Palette.amber) }
            HStack(spacing: 8) {
                if session.canSendImmediately {
                    Button("Send") { store.steer(session.id, action: "send") }
                        .buttonStyle(ReplyButtonStyle(primary: true)).disabled(!enabled || !validText)
                }
                Button("Queue") { store.steer(session.id, action: "queue") }
                    .buttonStyle(ReplyButtonStyle(primary: !session.canSendImmediately)).disabled(!enabled || !validText)
                Button("Interrupt") { confirmAction = "interrupt" }
                    .buttonStyle(ReplyButtonStyle(primary: false)).disabled(!enabled || !validText)
                Button("Stop") { confirmAction = "stop" }
                    .buttonStyle(ReplyButtonStyle(primary: false)).disabled(!enabled)
            }
            Text(session.canSendImmediately
                 ? "Send: steer before the next model request. Queue: next turn. Interrupt: stop and redirect."
                 : "Queue: next turn. Reload the updated Notify extension for immediate Send. Interrupt remains separate.")
                .font(.system(size: 9)).foregroundStyle(secondary)
        }
        .alert(confirmAction == "stop" ? "Stop this session's work?" : "Interrupt and send this direction?",
               isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } })) {
            Button("Cancel", role: .cancel) { confirmAction = nil }
            Button(confirmAction == "stop" ? "Stop" : "Interrupt and send", role: .destructive) {
                if let action = confirmAction { store.steer(session.id, action: action) }
                confirmAction = nil
            }
        } message: {
            Text(confirmAction == "stop"
                 ? "Stop current work in “\(session.name)” and clear queued prompts, including those queued in the terminal. Auto-yes turns off. Existing file changes are not undone, and external processes may continue. The terminal stays open."
                 : "Interrupt the main turn in “\(session.name)” and send your direction. Queued prompts and background work are preserved. Existing changes are not undone.")
        }
    }
}
