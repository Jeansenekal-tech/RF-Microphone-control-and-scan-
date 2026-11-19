import Foundation
import UniqueAVCore

/// A stored scan, tagged with the venue so it can be reused next time you work there.
struct LibraryScan: Codable, Identifiable, Equatable {
    var id = UUID()
    var venue: String
    var title: String
    var date: Date
    var regionID: String
    var source: String          // "tinySA", "Shure WWB import", ...
    var notes: String = ""
    var kHz: [Double]
    var dBm: [Double]

    var startMHz: Double { (kHz.first ?? 0) / 1000 }
    var stopMHz: Double { (kHz.last ?? 0) / 1000 }
    var points: [(kHz: Double, dBm: Double)] { zip(kHz, dBm).map { (kHz: $0, dBm: $1) } }
}

/// Venue scan library: a local, offline database of every scan you've taken or imported.
final class ScanLibrary: ObservableObject {
    @Published private(set) var scans: [LibraryScan] = []

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.scans, includingPropertiesForKeys: nil)) ?? []
        scans = files.filter { $0.pathExtension == "json" }
            .compactMap { Storage.read(LibraryScan.self, from: $0) }
            .sorted { $0.date > $1.date }
    }

    var venues: [String] {
        Array(Set(scans.map(\.venue))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func scan(_ id: UUID) -> LibraryScan? { scans.first { $0.id == id } }

    @discardableResult
    func add(venue: String, title: String, regionID: String, source: String,
             points: [(kHz: Double, dBm: Double)], notes: String = "") -> LibraryScan {
        let s = LibraryScan(venue: venue.isEmpty ? "Unknown venue" : venue, title: title, date: Date(),
                            regionID: regionID, source: source, notes: notes,
                            kHz: points.map { $0.kHz }, dBm: points.map { $0.dBm })
        Storage.write(s, to: url(s.id))
        scans.insert(s, at: 0)
        return s
    }

    func update(_ s: LibraryScan) {
        Storage.write(s, to: url(s.id))
        if let i = scans.firstIndex(where: { $0.id == s.id }) { scans[i] = s }
    }

    func delete(_ s: LibraryScan) {
        try? FileManager.default.removeItem(at: url(s.id))
        scans.removeAll { $0.id == s.id }
    }

    private func url(_ id: UUID) -> URL { Storage.scans.appendingPathComponent(id.uuidString + ".json") }
}
