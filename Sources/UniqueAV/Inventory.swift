import Foundation

enum ItemStatus: String, Codable, CaseIterable, Identifiable {
    case available = "Available", checkedOut = "Checked out", repair = "In repair", missing = "Missing"
    var id: String { rawValue }
}

struct InventoryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var category = "Transmitter"
    var make = ""
    var model = ""
    var serial = ""
    var label = ""        // asset tag / name on the pack
    var band = ""         // e.g. "G50 470-534", "Bw 626-698"
    var status: ItemStatus = .available
    var holder = ""       // who has it checked out
    var checkedOutAt: Date?
    var notes = ""
}

struct InventoryEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var itemID: UUID
    var itemName: String
    var action: String
    var person: String
}

/// Equipment list with check-out / check-in log. Stored once for all projects.
final class InventoryStore: ObservableObject {
    static let categories = ["Transmitter", "Receiver", "IEM transmitter", "IEM pack", "Headset / lav",
                             "Antenna", "Antenna distro / combiner", "Charger", "Cable", "Intercom", "Other"]

    @Published var items: [InventoryItem] = [] { didSet { save() } }
    @Published private(set) var log: [InventoryEvent] = []

    private struct Saved: Codable { var items: [InventoryItem]; var log: [InventoryEvent] }
    private var loading = true

    init() {
        if let s = Storage.read(Saved.self, from: Storage.inventoryFile) {
            items = s.items
            log = s.log
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        Storage.write(Saved(items: items, log: Array(log.prefix(5000))), to: Storage.inventoryFile)
    }

    static func name(_ i: InventoryItem) -> String {
        let base = [i.make, i.model].filter { !$0.isEmpty }.joined(separator: " ")
        let tag = i.label.isEmpty ? i.serial : i.label
        return tag.isEmpty ? (base.isEmpty ? i.category : base) : "\(base) [\(tag)]"
    }

    func upsert(_ item: InventoryItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
    }

    func delete(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) } }

    func checkOut(_ ids: Set<UUID>, to person: String) {
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            items[i].status = .checkedOut
            items[i].holder = person
            items[i].checkedOutAt = Date()
            record(items[i], "Checked out", person)
        }
        save()
    }

    func checkIn(_ ids: Set<UUID>) {
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            let who = items[i].holder
            items[i].status = .available
            items[i].holder = ""
            items[i].checkedOutAt = nil
            record(items[i], "Checked in", who)
        }
        save()
    }

    func setStatus(_ ids: Set<UUID>, _ status: ItemStatus) {
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            items[i].status = status
            record(items[i], status.rawValue, "")
        }
        save()
    }

    private func record(_ item: InventoryItem, _ action: String, _ person: String) {
        log.insert(InventoryEvent(itemID: item.id, itemName: Self.name(item), action: action, person: person), at: 0)
    }

    struct SummaryRow: Identifiable { var id: String { name }; var name: String; var total: Int; var available: Int }

    /// Quantity per make/model with how many are available.
    var summary: [SummaryRow] {
        var d: [String: (Int, Int)] = [:]
        for i in items {
            let k = [i.category, i.make, i.model].filter { !$0.isEmpty }.joined(separator: " · ")
            let v = d[k] ?? (0, 0)
            d[k] = (v.0 + 1, v.1 + (i.status == .available ? 1 : 0))
        }
        return d.map { SummaryRow(name: $0.key, total: $0.value.0, available: $0.value.1) }.sorted { $0.name < $1.name }
    }

    func csv() -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let df = ISO8601DateFormatter()
        var out = "Category,Make,Model,Serial,Label,Band,Status,Holder,Checked out at,Notes\n"
        for i in items {
            out += [i.category, i.make, i.model, i.serial, i.label, i.band, i.status.rawValue, i.holder,
                    i.checkedOutAt.map { df.string(from: $0) } ?? "", i.notes].map(q).joined(separator: ",") + "\n"
        }
        return out
    }
}
