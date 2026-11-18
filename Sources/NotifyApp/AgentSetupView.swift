import SwiftUI
import AppKit
import NotifyCore

struct AgentSetupView: View {
    @ObservedObject var store: Store
    @State private var confirmInstall = false
    @State private var confirmClaudeInstall = false
    @State private var copiedCommand: String?
    private var agent: SetupAgent { store.setupAgent }
    private var snapshot: AgentSetupSnapshot? { store.setupSnapshot }
    private var connected: Int { store.setupConnectionCount(agent) }
    private var executable: URL? { agent == .copilot ? snapshot?.copilot : snapshot?.claude }
    private var visibleError: String? { store.setupError ?? (agent == .copilot ? store.copilotSetupError : store.claudeSetupError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect your agents").font(WorkspaceType.text(32, strong: true))
                    Text("Keep your terminal. Answer from anywhere.")
                        .font(WorkspaceType.text(15)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Back to sessions") { store.setupVisible = false }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(SetupAgent.allCases, id: \.self) { choice in
                        Button { store.setupAgent = choice; copiedCommand = nil } label: {
                            HStack(spacing: 10) {
                                AgentIcon(agent: choice.rawValue)
                                Text(agentName(choice.rawValue)).font(WorkspaceType.text(15, strong: true))
                                Spacer()
                                if choice == agent { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
                            }.padding(10).contentShape(Rectangle())
                                .background(choice == agent ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(choice == agent ? .isSelected : [])
                    }
                    Text("Other agents need a Notify adapter. Choosing a different model doesn't create a connection.")
                        .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                        .padding(.top, 12).fixedSize(horizontal: false, vertical: true)
                }.frame(width: 196)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Text(agentName(agent.rawValue)).font(WorkspaceType.text(24, strong: true))
                            Spacer()
                            Label(connected > 0 ? "\(connected) connected" : "Not connected",
                                  systemImage: connected > 0 ? "checkmark.circle" : "link")
                                .font(WorkspaceType.text(13, strong: connected > 0))
                                .foregroundStyle(connected > 0 ? Palette.accent : Palette.muted)
                        }
                        if let error = visibleError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Palette.error).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if connected > 0 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("You're connected.").font(WorkspaceType.text(17, strong: true))
                                Text("Notify will show requests this agent shares. Your terminal and its permission rules stay in control.")
                                    .foregroundStyle(Palette.muted)
                                Button("View sessions") { store.setupVisible = false }
                            }
                        }
                        if let snapshot {
                            if connected > 0 {
                                DisclosureGroup("Connect another session") { setupSteps(snapshot).padding(.top, 16) }
                            } else { setupSteps(snapshot) }
                        } else {
                            Text(store.setupBusy ? "Checking installed tools..." : "Check installed tools to get started.")
                                .foregroundStyle(Palette.muted)
                        }
                    }.font(WorkspaceType.text(13))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4).padding(.trailing, 8)
                }.scrollIndicators(.visible)
            }.frame(maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(alignment: .center) {
                Text("Accounts, models and API keys stay in your agent. Notify doesn't need a separate login.")
                    .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                Spacer()
                Button(store.setupBusy ? "Checking..." : "Check again") { store.refreshSetup() }
                    .disabled(store.setupBusy)
            }
        }.padding(32).background(Palette.surface).foregroundStyle(Palette.ink).tint(Palette.accent)
            .onAppear { if store.setupSnapshot == nil { store.refreshSetup() } }
            .alert("Install the Notify extension?", isPresented: $confirmInstall) {
                Button("Cancel", role: .cancel) {}
                Button("Install extension") { store.installCopilotExtension() }
            } message: {
                Text("Adds Notify at \(snapshot?.extensionPath.path ?? ""). Existing files are not overwritten. You'll enable it and grant access in Copilot yourself. No running terminal or permission policy is changed.")
            }
            .alert("Add Notify hooks to Claude Code?", isPresented: $confirmClaudeInstall) {
                Button("Cancel", role: .cancel) {}
                Button("Add hooks") { store.installClaudeHooks() }
            } message: {
                Text("Adds hooks to \(snapshot?.claudeSettingsPath.path ?? ""). Hooks share session activity and supported permission requests with Notify, including any phones you have paired. Existing settings are preserved. No terminal is restarted or permission rule relaxed.")
            }
    }

    private func setupSteps(_ snapshot: AgentSetupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            prerequisites(snapshot)
            if agent == .copilot { copilotSteps(snapshot) }
            else { claudeSteps(snapshot) }
        }
    }

    private func prerequisites(_ snapshot: AgentSetupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(executable == nil ? "\(agentName(agent.rawValue)) not found" : "Installed CLI found",
                  systemImage: executable == nil ? "exclamationmark.circle" : "checkmark")
                .font(WorkspaceType.text(14, strong: true))
            if let executable {
                Text(executable.path).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.muted).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle).help(executable.path)
                Text("Use your existing signed-in account. Finding the CLI does not verify sign-in or connect a session.")
                    .foregroundStyle(Palette.muted)
            } else {
                Text("Install and sign in to \(agentName(agent.rawValue)), then check again. Custom terminal-only PATH settings may not be visible to this app.")
                    .foregroundStyle(Palette.muted)
                Link("Installation guide", destination: agent == .copilot
                     ? URL(string: "https://github.com/github/copilot-cli#installation")!
                     : URL(string: "https://code.claude.com/docs/en/setup")!)
            }
            if !snapshot.nodeReady {
                Text("Node.js 22.18 or newer is required\(snapshot.nodeVersion.map { "; found \($0)" } ?? "").")
                    .foregroundStyle(Palette.amber)
                Link("Get Node.js", destination: URL(string: "https://nodejs.org/en/download")!)
            }
            if !snapshot.resourcesReady {
                Text("Notify's bundled launcher is missing. Open an installed build of Notify, or rebuild and reinstall it.")
                    .foregroundStyle(Palette.error)
            }
        }
    }

    private func copilotSteps(_ snapshot: AgentSetupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Add Notify to Copilot").font(WorkspaceType.text(16, strong: true))
                Text(store.setupInstalledAgent == .copilot ? "Extension installed. Enable it in the terminal next." :
                     snapshot.extensionPresent ? "An extension file is present. Installation checks it without replacing an existing file." :
                     "Install the local extension once, then enable it in each terminal you want to connect.")
                    .foregroundStyle(Palette.muted)
                Button(store.setupBusy ? "Working..." : snapshot.extensionPresent ? "Check extension installation" : "Install extension") {
                    confirmInstall = true
                }.buttonStyle(.borderedProminent)
                    .disabled(store.setupBusy || !snapshot.nodeReady || !snapshot.resourcesReady || executable == nil)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("2. Enable it in your terminal").font(WorkspaceType.text(16, strong: true))
                Text("If experimental mode is already on: open /extensions manage, enable notify, press Esc to close the manager, then grant permission access. If Notify is missing, ask Copilot to reload extensions.")
                    .foregroundStyle(Palette.muted)
                Text("Don't turn experimental mode on during active work: it can restart the session UI. For a new terminal, start copilot --experimental.")
                    .foregroundStyle(Palette.amber)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("3. Watch for Connected").font(WorkspaceType.text(16, strong: true))
                Text("The status above changes only when a real session connects. Installing the extension alone isn't enough.")
                    .foregroundStyle(Palette.muted)
            }
            DisclosureGroup("Prefer a new SDK-backed chat?") { launchInstructions(snapshot) }
            Text("Using a custom COPILOT_HOME? Run notify setup-copilot in that terminal instead.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
        }
    }

    private func claudeSteps(_ snapshot: AgentSetupSnapshot) -> some View {
        let hooksInstalled = store.setupInstalledAgent == .claude || AgentSetup.claudeHooksInstalled(snapshot)
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Add Notify hooks").font(WorkspaceType.text(16, strong: true))
                Text(hooksInstalled
                     ? "Hooks installed. For existing terminals, wait until Claude is idle, then review and close /hooks. Notify connects on the next hook event."
                     : "Add hooks once. Wait until Claude is idle, then review and close /hooks to accept the changes. Notify connects on the next hook event.")
                    .foregroundStyle(Palette.muted)
                Button(store.setupBusy ? "Working..." :
                       hooksInstalled ? "Reinstall hooks" : "Add hooks") {
                    confirmClaudeInstall = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.setupBusy || !snapshot.nodeReady || !snapshot.resourcesReady || !snapshot.claudeHookReady || executable == nil)
                if hooksInstalled {
                    Label("Hooks are present in \(snapshot.claudeSettingsPath.path)",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(Palette.accent)
                        .font(WorkspaceType.text(13, strong: true))
                }
                if !snapshot.claudeHookReady {
                    Text("The Claude hook helper is missing. Rebuild or update Notify before adding hooks.")
                        .foregroundStyle(Palette.error)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("2. Watch for Connected").font(WorkspaceType.text(16, strong: true))
                Text("The status above changes when a live session connects. Each new terminal picks up the hooks automatically.")
                    .foregroundStyle(Palette.muted)
            }
            DisclosureGroup("Prefer an SDK-backed chat instead?") { launchInstructions(snapshot) }
            Text("Already-waiting prompts cannot be recovered. Keep using the terminal for unsupported questions, messaging and subagent controls.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
            Text("Opening /hooks ends the current turn in Claude Code 2.1.81. Do not open it during active work.")
                .font(WorkspaceType.text(12)).foregroundStyle(Palette.amber)
        }
    }

    @ViewBuilder private func launchInstructions(_ snapshot: AgentSetupSnapshot) -> some View {
        if let launcher = snapshot.launcher {
            let command = AgentSetup.launchCommand(launcher: launcher, agent: agent, searchPath: snapshot.searchPath)
            VStack(alignment: .leading, spacing: 8) {
                Text("Run this from your project folder in any terminal.")
                Button(copiedCommand == command ? "Copied" : "Copy launch command") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(command, forType: .string) { copiedCommand = command }
                    else { store.setupError = "The command could not be copied. Select and copy the text above instead." }
                }.buttonStyle(.borderedProminent)
                DisclosureGroup("View command") {
                    Text(command).font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 4)
        }
    }
}
