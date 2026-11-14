import Foundation
import NotifyCore

guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Pass a temporary test directory and optional permission scope") }
let permissionScope = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : nil
precondition(permissionScope == nil || permissionScope == "session" || permissionScope == "project")
let server = LocalServer(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
var registry = SessionRegistry()
server.onReady = {
    print("ready")
    fflush(stdout)
}
server.onError = { message in
    fputs("\(message)\n", stderr)
    exit(1)
}
server.onPacket = { packet in
    if packet.type == "resolved" || packet.type == "reply" {
        print("completion \(packet.type) \(packet.requestID ?? "")")
        fflush(stdout)
    }
    if packet.type == "hello" {
        registry.register(id: packet.sessionID, agent: packet.agent ?? "", cwd: packet.cwd ?? "")
    } else if packet.type == "request", let request = packet.request {
        if request.title == "Owner response" { return }
        do {
            try registry.add(request, to: packet.sessionID)
            let option = request.title == "Allow shell?" ? request.permissionOptions?.first(where: { $0.id == permissionScope }) : nil
            let decision = request.kind == "permission" ? (request.title == "Allow read?" || option != nil ? "allow" : "deny") : "answer"
            let answers = request.kind == "permission" ? [:] : ["0": ["B"]]
            precondition(registry.canReply(sessionID: packet.sessionID, requestID: request.id, decision: decision, answers: answers))
            var reply: [String: Any] = [
                "type": "reply", "requestID": request.id, "decision": decision, "answers": answers, "automatic": false
            ]
            if let option { reply["permissionOptionID"] = option.id }
            try server.send(sessionID: packet.sessionID, message: reply)
        } catch {
            fputs("Transport test failed: \(error)\n", stderr)
            exit(1)
        }
    } else if packet.type == "resolved", let id = packet.requestID {
        registry.resolve(sessionID: packet.sessionID, requestID: id)
    } else if packet.type == "activity", let activity = packet.activity {
        do {
            try registry.activity(packet.sessionID, entry: activity)
            print("activity \(activity.kind) \(activity.status)")
            fflush(stdout)
        } catch {
            fputs("Invalid activity event\n", stderr)
            exit(1)
        }
    }
}
try server.start()
dispatchMain()
