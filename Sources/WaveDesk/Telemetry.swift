import Foundation

struct TelemetrySample {
    var t: TimeInterval        // seconds since 1970
    var rf: Int16              // dBm, max of both antennas; Int16.min = none
    var audio: Int16           // dBFS; Int16.min = none
    var batt: Int8             // bars; -1 = unknown
    var online: Bool
}

/// Records one sample per channel per second (up to `maxAge`) for the timeline view.
final class TelemetryStore: ObservableObject {
    static let none = Int16.min
    let maxAge: TimeInterval = 12 * 3600

    @Published private(set) var revision = 0
    private(set) var series: [String: [TelemetrySample]] = [:]
    private(set) var labels: [String: String] = [:]
    private(set) var events: [(t: TimeInterval, key: String, text: String)] = []

    func record(key: String, label: String, channel c: ChannelState, online: Bool, at t: TimeInterval) {
        let rf = [c.rfA, c.rfB].compactMap { $0 }.max()
        let s = TelemetrySample(t: t, rf: rf.map { Int16(clamping: $0) } ?? Self.none,
                                audio: c.audio.map { Int16(clamping: $0) } ?? Self.none,
                                batt: c.battBars.map { Int8(clamping: $0) } ?? -1, online: online)
        series[key, default: []].append(s)
        labels[key] = label
        if let first = series[key]?.first, t - first.t > maxAge + 600 {
            series[key]?.removeAll { t - $0.t > maxAge }
        }
    }

    func event(_ key: String, _ text: String, at t: TimeInterval = Date().timeIntervalSince1970) {
        events.append((t: t, key: key, text: text))
        if events.count > 5000 { events.removeFirst(events.count - 5000) }
    }

    func commit() { revision &+= 1 }

    func clear() {
        series = [:]; events = []; revision &+= 1
    }

    func csv() -> String {
        let df = ISO8601DateFormatter()
        var out = "Time,Channel,Online,RF dBm,Audio dBFS,Battery bars\n"
        for (key, rows) in series.sorted(by: { (labels[$0.key] ?? "") < (labels[$1.key] ?? "") }) {
            let name = (labels[key] ?? key).replacingOccurrences(of: ",", with: " ")
            for s in rows {
                out += "\(df.string(from: Date(timeIntervalSince1970: s.t))),\(name),\(s.online ? 1 : 0),"
                out += "\(s.rf == Self.none ? "" : String(s.rf)),\(s.audio == Self.none ? "" : String(s.audio)),"
                out += "\(s.batt < 0 ? "" : String(s.batt))\n"
            }
        }
        return out
    }
}
