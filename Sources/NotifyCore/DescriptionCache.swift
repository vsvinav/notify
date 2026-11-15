import Foundation

public struct SessionDescription: Codable {
    public let text: String
    public let model: String
    public let generatedAt: Date

    public init(text: String, model: String, generatedAt: Date) {
        self.text = text; self.model = model; self.generatedAt = generatedAt
    }
}

public enum DescriptionCache {
    public static func load(from directory: URL) throws -> [String: SessionDescription] {
        let path = directory.appendingPathComponent("descriptions.json")
        do {
            let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 1_048_576 else { throw ProtocolError.invalid }
            let data = try Data(contentsOf: path)
            guard data.count <= 1_048_576 else { throw ProtocolError.oversized }
            return try JSONDecoder().decode([String: SessionDescription].self, from: data)
        } catch CocoaError.fileReadNoSuchFile { return [:] }
    }

    public static func save(_ descriptions: [String: SessionDescription], in directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var latest = Array(descriptions.sorted { $0.value.generatedAt > $1.value.generatedAt }.prefix(200))
        var data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: latest.map { ($0.key, $0.value) }))
        while data.count > 1_048_576, !latest.isEmpty {
            latest.removeLast()
            data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: latest.map { ($0.key, $0.value) }))
        }
        let path = directory.appendingPathComponent("descriptions.json")
        try data.write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
