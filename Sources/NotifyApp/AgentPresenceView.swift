import SwiftUI
import NotifyCore

enum WorkspaceType {
    static func text(_ size: CGFloat, strong: Bool = false) -> Font {
        .custom(strong ? "AvenirNext-DemiBold" : "AvenirNext-Regular", size: size)
    }
}

enum AgentPresence: Equatable {
    case working, thinking, waiting, resting, finished, stopped, disconnected, setup, saved, error, starting, unknown

    init(session: SessionRecord) {
        if session.isSaved { self = .saved }
        else if session.needsSetup { self = .setup }
        else if !session.connected { self = .disconnected }
        else if !session.requests.isEmpty { self = .waiting }
        else if session.baseState == "error" { self = .error }
        else if session.baseState == "starting" { self = .starting }
        else if session.stopped { self = .stopped }
        else if session.baseState == "ready" {
            let last = session.activity.entries.last { $0.agentID == nil && $0.kind != "status" }
            self = last?.kind == "assistant" && last?.status == "complete" ? .finished : .resting
        } else if session.baseState == "working" {
            let last = session.activity.entries.last { $0.agentID == nil }
            self = last?.kind == "reasoning" && last?.status == "running" ? .thinking : .working
        } else { self = .unknown }
    }

    var title: String {
        switch self {
        case .working: "Working"
        case .thinking: "Thinking"
        case .waiting: "Needs you"
        case .resting: "At rest"
        case .finished: "Response finished"
        case .stopped: "Stopped"
        case .disconnected: "Disconnected"
        case .setup: "Not connected yet"
        case .saved: "Saved for later"
        case .error: "Needs attention"
        case .starting: "Connecting"
        case .unknown: "State unavailable"
        }
    }

    var detail: String {
        switch self {
        case .working: "Following the agent's reported activity."
        case .thinking: "The agent is sharing its reasoning."
        case .waiting: "Your answer lets the agent continue."
        case .resting: "The main agent is idle, ready for direction."
        case .finished: "Reply complete. Review its output below."
        case .stopped: "Stop acknowledged. Existing changes were not undone."
        case .disconnected: "Previous activity may be out of date."
        case .setup: "Connect this terminal to see live work."
        case .saved: "Resume the conversation in your terminal."
        case .error: "Check the reported error before continuing."
        case .starting: "Waiting for the agent to become ready."
        case .unknown: "Check the original terminal for its current state."
        }
    }

    var symbol: String {
        switch self {
        case .working: "terminal"
        case .thinking: "ellipsis.bubble"
        case .waiting: "hand.raised"
        case .finished: "checkmark"
        case .stopped: "stop.fill"
        case .resting: "moon"
        case .disconnected, .setup: "link.badge.plus"
        case .saved: "bookmark"
        case .error: "exclamationmark"
        case .starting: "antenna.radiowaves.left.and.right"
        case .unknown: "questionmark"
        }
    }

    func animates(visible: Bool, reduceMotion: Bool) -> Bool {
        visible && !reduceMotion && [.working, .thinking, .resting, .finished].contains(self)
    }
}

struct AgentPose: Equatable {
    var leftHand: Double = 0
    var rightHand: Double = 0
    var blinking = false
    var glance: Double = 0
    init(presence: AgentPresence, time: Double?) {
        guard let time else { return }
        if presence == .working {
            leftHand = sin(time * 9) * 7
            rightHand = -leftHand
        }
        if presence == .resting || presence == .finished {
            let cycle = time.truncatingRemainder(dividingBy: 7)
            blinking = cycle < 0.18
            glance = cycle > 3 && cycle < 4.5 ? 4 : 0
        }
    }
}

struct AgentPresenceView: View {
    let presence: AgentPresence
    let visible: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presence.title).font(WorkspaceType.text(20, strong: true))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 8) {
                Text(presence.detail).font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                AnimatedAgentIllustration(presence: presence, visible: visible)
                    .frame(width: 116, height: 88).accessibilityHidden(true)
            }
        }.accessibilityElement(children: .combine)
    }

}

struct AnimatedAgentIllustration: View {
    let presence: AgentPresence
    let visible: Bool
    var accent: Color = Palette.accent
    var isLead = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var time: Double?

    var body: some View {
        let active = presence.animates(visible: visible, reduceMotion: reduceMotion)
        let animationTime = active ? time : nil
        AgentIllustration(presence: presence, phase: animationTime.map { sin($0 * 4) } ?? 0,
                          accent: accent, time: animationTime, isLead: isLead)
            .equatable()
            .task(id: active) {
                guard active else { return }
                do {
                    while !Task.isCancelled {
                        time = Date().timeIntervalSinceReferenceDate
                        try await Task.sleep(for: .milliseconds(125))
                    }
                } catch is CancellationError {
                    // Hiding the view or enabling Reduce Motion cancels its clock.
                } catch {
                    NSLog("Notify animation clock stopped: %@", error.localizedDescription)
                }
            }
    }
}

struct AgentIllustration: View, Equatable {
    let presence: AgentPresence
    var phase: Double = 0
    var accent: Color = Palette.accent
    var portrait = false
    var time: Double? = nil
    var isLead = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presence == rhs.presence && lhs.accent == rhs.accent && lhs.portrait == rhs.portrait &&
            lhs.isLead == rhs.isLead &&
            AgentPose(presence: lhs.presence, time: lhs.time) == AgentPose(presence: rhs.presence, time: rhs.time) &&
            (lhs.presence != .thinking || lhs.phase == rhs.phase)
    }

    var body: some View {
        Canvas { context, size in
            if portrait {
                context.scaleBy(x: size.width / 58, y: size.height / 58)
                context.translateBy(x: -32, y: -17)
            } else {
                context.scaleBy(x: size.width / 180, y: size.height / 136)
            }
            func line(_ points: [CGPoint], color: Color = Palette.ink, width: CGFloat = 2) {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            func stroke(_ path: Path, color: Color = Palette.ink) {
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            let active = presence == .working || presence == .thinking
            let pose = AgentPose(presence: presence, time: time)
            let lean: CGFloat = active ? 7 + CGFloat(pose.leftHand) * 0.25 : CGFloat(pose.glance) * 0.4
            let head = CGRect(x: 43 + lean, y: 26, width: 33, height: 34)
            context.fill(Path(ellipseIn: head), with: .color(Palette.raised))
            stroke(Path(ellipseIn: head))
            if isLead {
                let hat = Path { path in
                    path.addLines([CGPoint(x: 45 + lean, y: 29), CGPoint(x: 47 + lean, y: 8),
                                   CGPoint(x: 72 + lean, y: 8), CGPoint(x: 75 + lean, y: 29)])
                    path.closeSubpath()
                }
                context.fill(hat, with: .color(Palette.ink))
                line([CGPoint(x: 46 + lean, y: 23), CGPoint(x: 73 + lean, y: 23)], color: accent, width: 4)
                line([CGPoint(x: 38 + lean, y: 29), CGPoint(x: 81 + lean, y: 29)], color: Palette.ink, width: 4)
            }
            let resting = pose.blinking || presence == .saved || presence == .disconnected
            if presence == .stopped {
                for x: CGFloat in [54, 67] {
                    line([CGPoint(x: x + lean - 2, y: 39), CGPoint(x: x + lean + 2, y: 44)])
                    line([CGPoint(x: x + lean - 2, y: 44), CGPoint(x: x + lean + 2, y: 39)])
                }
            } else if resting {
                line([CGPoint(x: 52 + lean, y: 41), CGPoint(x: 56 + lean, y: 42)])
                line([CGPoint(x: 65 + lean, y: 42), CGPoint(x: 69 + lean, y: 41)])
            } else {
                for x: CGFloat in [54, 67] {
                    context.fill(Path(ellipseIn: CGRect(x: x + lean + pose.glance, y: 40, width: 2.5, height: 3)), with: .color(Palette.ink))
                }
            }
            var smile = Path()
            smile.move(to: CGPoint(x: 57 + lean, y: 50))
            smile.addQuadCurve(to: CGPoint(x: 65 + lean, y: 50), control: CGPoint(x: 61 + lean, y: 54))
            stroke(smile)
            var coat = Path()
            coat.move(to: CGPoint(x: 50, y: 66))
            coat.addQuadCurve(to: CGPoint(x: 39, y: 99), control: CGPoint(x: 40, y: 74))
            coat.addLine(to: CGPoint(x: 80, y: 99))
            coat.addQuadCurve(to: CGPoint(x: 73, y: 66), control: CGPoint(x: 80, y: 74))
            stroke(coat)
            line([CGPoint(x: 54, y: 65), CGPoint(x: 61, y: 69), CGPoint(x: 68, y: 65),
                  CGPoint(x: 68, y: 73), CGPoint(x: 61, y: 69), CGPoint(x: 54, y: 73), CGPoint(x: 54, y: 65)],
                 color: accent)
            let handsOff = presence == .stopped || presence == .resting || presence == .finished
            line([CGPoint(x: 48, y: 80), CGPoint(x: 59, y: 91),
                  CGPoint(x: handsOff ? 67 : 96, y: handsOff ? 104 : 93 + pose.leftHand)])
            if presence == .waiting {
                line([CGPoint(x: 76, y: 79), CGPoint(x: 89, y: 63), CGPoint(x: 90, y: 36)], color: accent)
                line([CGPoint(x: 85, y: 42), CGPoint(x: 90, y: 49), CGPoint(x: 96, y: 38)], color: accent)
            } else if presence == .thinking {
                line([CGPoint(x: 75, y: 82), CGPoint(x: 88, y: 66), CGPoint(x: 77, y: 54 + phase)])
            } else {
                line([CGPoint(x: 76, y: 82), CGPoint(x: 82, y: 90),
                      CGPoint(x: handsOff ? 78 : 108, y: handsOff ? 103 : 94 + pose.rightHand)])
            }
            line([CGPoint(x: 30, y: 81), CGPoint(x: 30, y: 106), CGPoint(x: 68, y: 106)], color: Palette.line)
            line([CGPoint(x: 48, y: 107), CGPoint(x: 48, y: 127)], color: Palette.line)
            line([CGPoint(x: 65, y: 103), CGPoint(x: 73, y: 124), CGPoint(x: 86, y: 124)])
            line([CGPoint(x: 29, y: 100), CGPoint(x: 165, y: 100)], color: Palette.line)
            line([CGPoint(x: 149, y: 100), CGPoint(x: 149, y: 127)], color: Palette.line)
            let laptop = Path { path in
                path.addLines([CGPoint(x: 113, y: 65), CGPoint(x: 160, y: 65), CGPoint(x: 150, y: 90),
                               CGPoint(x: 105, y: 90), CGPoint(x: 113, y: 65)])
            }
            context.fill(laptop, with: .color(Palette.surface))
            stroke(laptop, color: accent)
            line([CGPoint(x: 87, y: 98), CGPoint(x: 144, y: 98)], color: accent)
            for row in 0..<2 {
                for key in 0..<7 {
                    let x = CGFloat(96 + key * 6 - row * 2)
                    line([CGPoint(x: x, y: CGFloat(92 + row * 3)), CGPoint(x: x + 3, y: CGFloat(92 + row * 3))],
                         color: Palette.muted, width: 1)
                }
            }
            context.draw(Text(Image(systemName: presence.symbol)).font(.system(size: 19, weight: .medium))
                .foregroundColor(accent), at: CGPoint(x: 137, y: 40))
        }
    }
}

struct SubagentTeamView: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var compact = false
    var selectedAgentID: String? = nil
    var selectAgent: ((String?) -> Void)? = nil
    private var presence: AgentPresence { AgentPresence(session: session) }
    private var current: Bool { session.connected && session.team?.error == nil }
    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your team").font(WorkspaceType.text(20, strong: true)).accessibilityAddTraits(.isHeader)
                if selectAgent != nil {
                    Text("Select an agent to chat").font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                }
                Button { selectAgent?(nil) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Main agent").font(WorkspaceType.text(16, strong: true))
                            Image(systemName: "bubble.left").accessibilityHidden(true)
                            Spacer(minLength: 4)
                            Text(presence.title).font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                        }
                        AnimatedAgentIllustration(presence: presence, visible: store.centerVisible && session.connected,
                                                  accent: store.sessionColor(session), isLead: true)
                            .frame(width: compact ? 156 : 220, height: compact ? 118 : 166)
                            .frame(maxWidth: .infinity).accessibilityHidden(true)
                    }.contentShape(Rectangle())
                }.buttonStyle(AgentSelectionStyle(selected: selectedAgentID == nil, accent: store.sessionColor(session)))
                    .disabled(selectAgent == nil).help("Open main agent chat")
                    .accessibilityLabel("Chat with main agent")
                Divider()
                if let team = session.team {
                    if let error = team.error {
                        Text(error).font(WorkspaceType.text(12)).foregroundStyle(Palette.amber)
                    } else {
                        Text(current ? "\(team.runningCount) subagent\(team.runningCount == 1 ? "" : "s") running" : "Previous team")
                            .font(WorkspaceType.text(13, strong: true))
                        if current && team.idleCount > 0 {
                            Text("\(team.idleCount) ready for follow-up").font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                        }
                        if team.agents.isEmpty {
                            Text("No subagents reported.").font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(team.agents) { agent in
                                        Button { selectAgent?(agent.id) } label: {
                                            member(agent)
                                        }.buttonStyle(AgentSelectionStyle(selected: selectedAgentID == agent.id, accent: store.sessionColor(session)))
                                            .disabled(selectAgent == nil || agent.status == .cancelled)
                                            .help(agent.status == .cancelled ? "Stopped helpers cannot be reopened." : "Open chat with \(agent.name)")
                                            .accessibilityLabel(agent.status == .cancelled ? "\(agent.name), stopped" : "Chat with \(agent.name)")
                                    }
                                    if team.truncated {
                                        Text("Showing the first 100 agents. Counts include the full team.")
                                            .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                                    }
                                }.padding(.vertical, 4)
                            }.frame(maxHeight: compact ? 120 : .infinity).scrollIndicators(.visible)
                        }
                        if !current {
                            Text("Reconnect to see current subagent status.").font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                        }
                    }
                } else {
                    Text("Subagent status is not available yet.").font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                    Text(session.agent == "copilot" ? "An updated Notify extension supplies the live team." :
                            "This connection does not report a live team.")
                        .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted)
                }
            }.frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
    }
    private func member(_ agent: SubagentRecord) -> some View {
        let state: AgentPresence = agent.status == .cancelled ? .stopped : !current ? .disconnected :
            agent.status == .running ? .working : agent.status == .idle ? .resting :
            agent.status == .failed ? .error : agent.status == .completed ? .finished : .stopped
        let recent = session.activity.entries.last { $0.agentID == agent.id }
        return HStack(alignment: .top, spacing: 8) {
            AnimatedAgentIllustration(presence: state, visible: store.centerVisible && current, accent: store.sessionColor(session))
                .frame(width: 88, height: 68).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(agent.name).font(WorkspaceType.text(13, strong: true)).lineLimit(2)
                    if agent.status != .cancelled {
                        Image(systemName: "bubble.left").font(.system(size: 11)).accessibilityHidden(true)
                    }
                }
                Text(!current ? "Last seen: \(agent.status.rawValue)" : agent.status == .idle ? "Ready for follow-up" :
                        agent.status == .cancelled ? "Stopped" : agent.status.rawValue.capitalized)
                    .font(WorkspaceType.text(11)).foregroundStyle(agent.status == .failed ? Palette.error : Palette.muted)
                Text(agent.task).font(WorkspaceType.text(12)).lineLimit(compact ? 2 : 4).help(agent.task)
                if current, agent.status == .running, let recent, recent.kind == "tool" || recent.kind == "reasoning" {
                    Text(recent.kind == "reasoning" ? "Thinking" : recent.title)
                        .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted).lineLimit(2).help(recent.title)
                }
                if !compact, let model = agent.model {
                    Text(model).font(WorkspaceType.text(10)).foregroundStyle(Palette.muted).lineLimit(1).help(model)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentSelectionStyle: ButtonStyle {
    let selected: Bool
    let accent: Color
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = enabled && configuration.isPressed
        let lifted = enabled && hovering && !pressed
        configuration.label.padding(6).contentShape(RoundedRectangle(cornerRadius: 8))
            .background {
                RoundedRectangle(cornerRadius: 8).fill(enabled ? Palette.surface : .clear)
                    .shadow(color: .black.opacity(enabled ? (colorScheme == .dark ? 0.3 : 0.13) : 0),
                            radius: pressed ? 1 : lifted ? 5 : 3, x: 0, y: pressed ? 1 : lifted ? 4 : 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected && enabled ? accent : Palette.line.opacity(enabled ? 0.65 : 0.25),
                        lineWidth: selected && enabled ? 2 : 1))
            .offset(y: reduceMotion ? 0 : pressed ? 1 : lifted ? -1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: lifted)
            .onHover { hovering = $0 }
    }
}
