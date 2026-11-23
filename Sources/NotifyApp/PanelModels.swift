import Foundation

struct PanelFeed: Decodable {
    let version: Int
    let title: String?
    let updatedAt: String?
    let copilot: Copilot?
    let tabs: [PanelTab]
    struct Copilot: Decodable { let connected: Bool; let busy: Bool }
}

struct PanelTab: Decodable, Identifiable {
    let id: String
    let label: String
    let badge: Int?
    let sections: [PanelSection]
    let track: PanelTrack?
    let form: PanelForm?
    var items: [PanelLocatedItem] {
        sections.enumerated().flatMap { section, value in
            value.items.enumerated().map { index, item in
                PanelLocatedItem(key: "\(id)/\(section)/\(index)", section: value.title, item: item)
            }
        }
    }
    var validTrack: PanelTrack? {
        guard let track, track.version == 1, (1...24).contains(track.stages.count),
              Set(track.stages.map(\.id)).count == track.stages.count else { return nil }
        let counts = Dictionary(grouping: items, by: { $0.item.id })
        guard Set(track.placements.map(\.itemId)).count == track.placements.count,
              track.placements.allSatisfy({ counts[$0.itemId]?.count == 1 }) else { return nil }
        guard track.placements.allSatisfy({ placement in track.stages.contains { $0.id == placement.stageId } }) else { return nil }
        return track
    }
    var unplacedItems: [PanelLocatedItem] {
        guard let track = validTrack else { return items }
        let placed = Set(track.placements.map(\.itemId))
        return items.filter { !placed.contains($0.item.id) }
    }
    func items(in stage: String) -> [PanelLocatedItem] {
        let ids = Set(validTrack?.placements.filter { $0.stageId == stage }.map(\.itemId) ?? [])
        return items.filter { ids.contains($0.item.id) }
    }
}

struct PanelSection: Decodable {
    let title: String
    let emphasis: String?
    let items: [PanelItem]
}
struct PanelLocatedItem: Identifiable {
    let key: String
    let section: String
    let item: PanelItem
    var id: String { key }
}
struct PanelItem: Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let tone: String?
    let url: String?
    let log: PanelLog?
    let actions: [PanelAction]
}
struct PanelAction: Decodable { let id: String; let label: String; let style: String? }
struct PanelLog: Decodable {
    let entries: [Entry]
    let truncated: Bool
    struct Entry: Decodable { let text: String; let at: String? }
}
struct PanelTrack: Decodable {
    let version: Int
    let title: String
    let stages: [Stage]
    let placements: [Placement]
    struct Stage: Decodable, Identifiable { let id: String; let label: String; let kind: String; let hint: String? }
    struct Placement: Decodable { let itemId: String; let stageId: String }
}
struct PanelForm: Decodable {
    let version: Int
    let actionId: String
    let title: String
    let submitLabel: String
    let minLength: Int
    let maxLength: Int
    let placeholder: String?
    func accepts(_ text: String) -> Bool {
        version == 1 && minLength >= 1 && maxLength <= 300 && minLength <= maxLength &&
        (minLength...maxLength).contains(text.utf16.count) &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !text.unicodeScalars.contains { (0...8).contains($0.value) || (11...12).contains($0.value) ||
            (14...31).contains($0.value) || (127...159).contains($0.value) }
    }
}
struct PanelResponse: Decodable {
    let status: Int
    let data: Body
    var successful: Bool { (200..<300).contains(status) }
    struct Body: Decodable {
        let available: Bool?
        let panel: PanelFeed?
        let reason: String?
        let ok: Bool?
        let sent: Bool?
        let demo: Bool?
        let wasBusy: Bool?
        let label: String?
        let confirm: String?
        let confirmationToken: String?
        let error: String?
    }
}
struct PanelReceipt: Codable {
    enum Delivery: String, Codable { case sending, accepted, unknown }
    let id: UUID
    let createdAt: Date
    var delivery: Delivery
}
struct PanelConfirmation: Identifiable {
    let id = UUID()
    let actionID: String
    let tabID: String
    let text: String?
    let label: String
    let message: String
    let token: String
    let generation: UInt64
}
