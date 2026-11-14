import Foundation

public struct SessionAppearance {
    public private(set) var overrides: [String: UInt32] = [:]
    public init() {}
    private static let palette: [UInt32] = [0xA6C8FF, 0xD8AFF5, 0x70D6C4, 0xEAAFBC, 0xC1D58D, 0xE5BF8C, 0xA9B6EF, 0x8ACBDF]
    private static let choices = palette + [0xF29A78, 0xB9B0A3]

    public func suggestedColors(for session: SessionRecord, among sessions: [SessionRecord]) -> [UInt32] {
        let key = session.sourceSessionID ?? session.id
        var seen: Set<String> = [key]
        var usage: [UInt32: Int] = [:]
        for peer in sessions where peer.connected && !peer.isSaved && !peer.needsSetup {
            guard seen.insert(peer.sourceSessionID ?? peer.id).inserted else { continue }
            usage[color(for: peer), default: 0] += 1
        }
        let current = Self.choices.firstIndex(of: color(for: session)) ?? -1
        let count = Self.choices.count
        return Self.choices.enumerated().sorted { left, right in
            let a = usage[left.element, default: 0], b = usage[right.element, default: 0]
            if a != b { return a < b }
            return (left.offset - current + count - 1) % count < (right.offset - current + count - 1) % count
        }.map(\.element)
    }

    public func color(for session: SessionRecord) -> UInt32 {
        let key = session.sourceSessionID ?? session.id
        if let value = overrides[key] { return value }
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }

    public static func load(from directory: URL) throws -> SessionAppearance {
        var result = SessionAppearance()
        let path = directory.appendingPathComponent("session-colors.json")
        do {
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 524288 else { throw ProtocolError.invalid }
            let data = try Data(contentsOf: path)
            guard data.count <= 524288 else { throw ProtocolError.oversized }
            let colors = try JSONDecoder().decode([String: UInt32].self, from: data)
            guard colors.count <= 5000, colors.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 128 && $0.value <= 0xFFFFFF }) else { throw ProtocolError.invalid }
            result.overrides = colors
        } catch CocoaError.fileReadNoSuchFile {}
        return result
    }

    public mutating func set(_ color: UInt32?, for session: SessionRecord, in directory: URL) throws {
        let key = session.sourceSessionID ?? session.id
        guard !key.isEmpty, key.count <= 128, color == nil || color! <= 0xFFFFFF else { throw ProtocolError.invalid }
        var next = overrides
        next[key] = color
        guard next.count <= 5000 else { throw ProtocolError.oversized }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("session-colors.json")
        try JSONEncoder().encode(next).write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        overrides = next
    }
}
