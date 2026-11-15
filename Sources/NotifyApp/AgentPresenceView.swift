import SwiftUI
import NotifyCore

enum WorkspaceType {
    static func text(_ size: CGFloat, strong: Bool = false) -> Font {
        .custom(strong ? "AvenirNext-DemiBold" : "AvenirNext-Regular", size: size)
    }
}

enum AgentPresence: Equatable {
    case working, thinking, waiting, resting, finished, disconnected, setup, saved, error, starting, unknown

    init(session: SessionRecord) {
        if session.isSaved { self = .saved }
        else if session.needsSetup { self = .setup }
        else if !session.connected { self = .disconnected }
        else if !session.requests.isEmpty { self = .waiting }
        else if session.baseState == "error" { self = .error }
        else if session.baseState == "starting" { self = .starting }
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
        case .resting: "moon"
        case .disconnected, .setup: "link.badge.plus"
        case .saved: "bookmark"
        case .error: "exclamationmark"
        case .starting: "antenna.radiowaves.left.and.right"
        case .unknown: "questionmark"
        }
    }

    func animates(visible: Bool, reduceMotion: Bool) -> Bool {
        visible && !reduceMotion && (self == .working || self == .thinking)
    }
}

struct AgentPresenceView: View {
    let presence: AgentPresence
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let moving = presence.animates(visible: visible, reduceMotion: reduceMotion)
        VStack(alignment: .leading, spacing: 6) {
            Text(presence.title).font(WorkspaceType.text(20, strong: true))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 8) {
                Text(presence.detail).font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                TimelineView(.animation(minimumInterval: 0.125, paused: !moving)) { clock in
                    AgentIllustration(presence: presence, phase: moving ? sin(clock.date.timeIntervalSinceReferenceDate * 4) : 0)
                }.frame(width: 116, height: 88).accessibilityHidden(true)
            }
        }.accessibilityElement(children: .combine)
    }

}

struct AgentIllustration: View {
    let presence: AgentPresence
    var phase: Double = 0
    var accent: Color = Palette.accent
    var portrait = false

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
            let lean: CGFloat = active ? 5 : 0
            let head = CGRect(x: 43 + lean, y: 26, width: 33, height: 34)
            context.fill(Path(ellipseIn: head), with: .color(Palette.raised))
            stroke(Path(ellipseIn: head))
            let resting = presence == .resting || presence == .finished || presence == .saved || presence == .disconnected
            if resting {
                line([CGPoint(x: 52 + lean, y: 41), CGPoint(x: 56 + lean, y: 42)])
                line([CGPoint(x: 65 + lean, y: 42), CGPoint(x: 69 + lean, y: 41)])
            } else {
                for x: CGFloat in [54, 67] {
                    context.fill(Path(ellipseIn: CGRect(x: x + lean, y: 40, width: 2.5, height: 3)), with: .color(Palette.ink))
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
            line([CGPoint(x: 48, y: 80), CGPoint(x: 59, y: 91), CGPoint(x: 91, y: 93 + (active ? phase * 1.8 : 0))])
            if presence == .waiting {
                line([CGPoint(x: 76, y: 79), CGPoint(x: 89, y: 63), CGPoint(x: 90, y: 36)], color: accent)
                line([CGPoint(x: 85, y: 42), CGPoint(x: 90, y: 49), CGPoint(x: 96, y: 38)], color: accent)
            } else if presence == .thinking {
                line([CGPoint(x: 75, y: 82), CGPoint(x: 88, y: 66), CGPoint(x: 77, y: 54 + phase)])
            } else {
                line([CGPoint(x: 76, y: 82), CGPoint(x: 82, y: 90), CGPoint(x: 98, y: 91 - (active ? phase * 1.8 : 0))])
            }
            line([CGPoint(x: 30, y: 81), CGPoint(x: 30, y: 106), CGPoint(x: 68, y: 106)], color: Palette.line)
            line([CGPoint(x: 48, y: 107), CGPoint(x: 48, y: 127)], color: Palette.line)
            line([CGPoint(x: 65, y: 103), CGPoint(x: 73, y: 124), CGPoint(x: 86, y: 124)])
            line([CGPoint(x: 29, y: 100), CGPoint(x: 165, y: 100)], color: Palette.line)
            line([CGPoint(x: 149, y: 100), CGPoint(x: 149, y: 127)], color: Palette.line)
            let laptop = Path { path in
                path.addLines([CGPoint(x: 98, y: 71), CGPoint(x: 153, y: 71), CGPoint(x: 143, y: 98),
                               CGPoint(x: 89, y: 98), CGPoint(x: 98, y: 71)])
            }
            context.fill(laptop, with: .color(Palette.surface))
            stroke(laptop, color: accent)
            context.draw(Text(Image(systemName: presence.symbol)).font(.system(size: 19, weight: .medium))
                .foregroundColor(accent), at: CGPoint(x: 137, y: 40))
        }
    }
}

struct SubagentTeamView: View {
    @ObservedObject var store: Store
    let session: SessionRecord
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var presence: AgentPresence { AgentPresence(session: session) }
    private var current: Bool { session.connected && session.team?.error == nil }
    private var moving: Bool {
        store.centerVisible && !reduceMotion && session.connected &&
            (presence.animates(visible: true, reduceMotion: false) || (current && (session.team?.runningCount ?? 0) > 0))
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: !moving)) { clock in
            let phase = moving ? sin(clock.date.timeIntervalSinceReferenceDate * 4) : 0
            VStack(alignment: .leading, spacing: 12) {
                Text("Your team").font(WorkspaceType.text(20, strong: true)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    AgentIllustration(presence: presence, phase: phase, accent: store.sessionColor(session))
                        .frame(width: 92, height: 72).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Main agent").font(WorkspaceType.text(13, strong: true))
                        Text(presence.title).font(WorkspaceType.text(12)).foregroundStyle(Palette.muted)
                    }
                }
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
                                        member(agent, phase: phase)
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
    }
    private func member(_ agent: SubagentRecord, phase: Double) -> some View {
        let state: AgentPresence = !current ? .disconnected :
            agent.status == .running ? .working : agent.status == .idle ? .resting :
            agent.status == .failed ? .error : agent.status == .completed ? .finished : .resting
        let recent = session.activity.entries.last { $0.agentID == agent.id }
        return HStack(alignment: .top, spacing: 8) {
            AgentIllustration(presence: state, phase: state == .working ? phase : 0, accent: store.sessionColor(session))
                .frame(width: 68, height: 53).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name).font(WorkspaceType.text(13, strong: true)).lineLimit(2)
                Text(!current ? "Last seen: \(agent.status.rawValue)" : agent.status == .idle ? "Ready for follow-up" : agent.status.rawValue.capitalized)
                    .font(WorkspaceType.text(11)).foregroundStyle(agent.status == .failed ? Palette.error : Palette.muted)
                Text(agent.task).font(WorkspaceType.text(12)).lineLimit(compact ? 2 : 4).help(agent.task)
                if current, agent.status == .running, let recent, recent.kind == "tool" || recent.kind == "reasoning" {
                    Text(recent.kind == "reasoning" ? "Thinking" : recent.title)
                        .font(WorkspaceType.text(11)).foregroundStyle(Palette.muted).lineLimit(2).help(recent.title)
                }
                if !compact, let model = agent.model {
                    Text(model).font(WorkspaceType.text(10)).foregroundStyle(Palette.muted).lineLimit(1).help(model)
                }
            }.textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
