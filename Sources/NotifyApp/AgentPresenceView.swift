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
                    illustration(phase: moving ? sin(clock.date.timeIntervalSinceReferenceDate * 4) : 0)
                }.frame(width: 116, height: 88).accessibilityHidden(true)
            }
        }.accessibilityElement(children: .combine)
    }

    private func illustration(phase: Double) -> some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 180, y: size.height / 136)
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
                 color: Palette.accent)
            line([CGPoint(x: 48, y: 80), CGPoint(x: 59, y: 91), CGPoint(x: 91, y: 93 + (active ? phase * 1.8 : 0))])
            if presence == .waiting {
                line([CGPoint(x: 76, y: 79), CGPoint(x: 89, y: 63), CGPoint(x: 90, y: 36)], color: Palette.accent)
                line([CGPoint(x: 85, y: 42), CGPoint(x: 90, y: 49), CGPoint(x: 96, y: 38)], color: Palette.accent)
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
            stroke(laptop, color: Palette.accent)
            context.draw(Text(Image(systemName: presence.symbol)).font(.system(size: 19, weight: .medium))
                .foregroundColor(Palette.accent), at: CGPoint(x: 137, y: 40))
        }
    }
}
