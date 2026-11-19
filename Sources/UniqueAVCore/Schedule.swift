import Foundation

/// A time window within the show day, in minutes after midnight. If `endMin <= startMin`
/// the slot runs past midnight (e.g. 22:00-02:00).
public struct TimeSlot: Codable, Equatable, Hashable {
    public var startMin: Int
    public var endMin: Int
    public init(startMin: Int, endMin: Int) { self.startMin = startMin; self.endMin = endMin }

    /// Half-open intervals within 0..<1440.
    public var intervals: [Range<Int>] {
        let a = ((startMin % 1440) + 1440) % 1440, b = ((endMin % 1440) + 1440) % 1440
        if a == b { return [0..<1440] }
        if b > a { return [a..<b] }
        return [a..<1440, 0..<b].filter { !$0.isEmpty }
    }
}

/// A set of channels that is only on air during certain times (an act, a session, a scene).
/// Groups that are never on air together may reuse each other's frequencies.
public struct UsageGroup: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var colorIndex: Int
    public var slots: [TimeSlot]   // empty = on air all day

    public init(id: UUID = UUID(), name: String, colorIndex: Int = 0, slots: [TimeSlot] = []) {
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.slots = slots
    }
}

public enum Schedule {
    /// Parses "18:00-20:30, 21:15-23:00" (also "18-20" or "1800-2030").
    public static func parseSlots(_ text: String) -> [TimeSlot] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).compactMap { part in
            let ends = part.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count == 2, let a = minutes(ends[0]), let b = minutes(ends[1]) else { return nil }
            return TimeSlot(startMin: a, endMin: b)
        }
    }

    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":")
        if p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...24).contains(h), (0..<60).contains(m) {
            return h * 60 + m
        }
        if p.count == 1, let v = Int(p[0]) {
            if v <= 24 { return v * 60 }
            if v <= 2400, v % 100 < 60 { return (v / 100) * 60 + v % 100 }
        }
        return nil
    }

    public static func format(_ slots: [TimeSlot]) -> String {
        slots.map { "\(clock($0.startMin))-\(clock($0.endMin))" }.joined(separator: ", ")
    }

    public static func clock(_ m: Int) -> String {
        let v = ((m % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", v / 60, v % 60)
    }

    /// Splits the day into elementary pieces at every slot boundary.
    public static func segments(_ groups: [UsageGroup]) -> [Range<Int>] {
        var cuts: Set<Int> = [0, 1440]
        for g in groups { for s in g.slots { for r in s.intervals { cuts.insert(r.lowerBound); cuts.insert(r.upperBound) } } }
        let c = cuts.sorted()
        return zip(c, c.dropFirst()).map { $0..<$1 }.filter { !$0.isEmpty }
    }

    /// Indices of `segments` during which `group` is on air (nil / no slots = always).
    public static func activeSegments(_ group: UsageGroup?, _ segments: [Range<Int>]) -> Set<Int> {
        guard let g = group, !g.slots.isEmpty else { return Set(segments.indices) }
        let ivs = g.slots.flatMap(\.intervals)
        return Set(segments.indices.filter { i in ivs.contains { $0.contains(segments[i].lowerBound) } })
    }

    public static func overlaps(_ a: UsageGroup?, _ b: UsageGroup?) -> Bool {
        let segs = segments([a, b].compactMap { $0 })
        return !activeSegments(a, segs).isDisjoint(with: activeSegments(b, segs))
    }
}
