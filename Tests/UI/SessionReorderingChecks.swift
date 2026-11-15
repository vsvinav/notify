import Foundation

enum SessionReorderingChecks {
    static func run() {
        let group = ["first", "middle", "last"]
        precondition(sessionMoveTarget("first", in: group, offset: -1) == nil,
                     "The first session must not offer Move up")
        precondition(sessionMoveTarget("last", in: group, offset: 1) == nil,
                     "The last session must not offer Move down")
        precondition(sessionMoveTarget("middle", in: group, offset: -1) == "first")
        precondition(sessionMoveTarget("middle", in: group, offset: 1) == "last")
        precondition(sessionMoveTarget("hidden", in: group, offset: 1) == nil,
                     "Move controls cannot reach a session outside the visible group")
        precondition(sessionMoveTarget("only", in: ["only"], offset: -1) == nil &&
                     sessionMoveTarget("only", in: ["only"], offset: 1) == nil,
                     "A singleton group has no move controls")
        let filtered = ["first", "last"]
        let target = sessionMoveTarget("last", in: filtered, offset: -1)!
        precondition(reorderedSessionIDs(group, moving: "last", over: target) == ["last", "first", "middle"],
                     "Filtered movement uses a visible neighbor without discarding hidden sessions")
    }
}

#if SESSION_REORDERING_CHECKS
@main struct SessionReorderingCheckRunner {
    static func main() {
        SessionReorderingChecks.run()
        print("Session reordering checks passed")
    }
}
#endif
