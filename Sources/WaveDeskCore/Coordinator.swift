import Foundation

public struct CoordSettings: Codable, Equatable {
    public var startMHz: Double = 470
    public var stopMHz: Double = 694
    public var stepKHz: Int = 25
    /// Minimum spacing between any two carriers.
    public var spacingKHz: Int = 350
    /// Minimum distance from 3rd-order 2-transmitter products (2f1 - f2).
    public var imd3x2KHz: Int = 100
    /// Minimum distance from 3rd-order 3-transmitter products (f1 + f2 - f3).
    public var imd3x3KHz: Int = 50
    /// Minimum distance from 5th-order 2-transmitter products (3f1 - 2f2).
    public var imd5x2KHz: Int = 50
    public var use3Tx = true
    public var use5th = true
    public var useScan = true
    /// Candidates whose scanned level (within +/-100 kHz) exceeds this are skipped.
    public var thresholdDBm: Double = -85
    public var avoidRegionBands = true
    /// Extra exclusions in MHz, e.g. "530-536, 584-590".
    public var exclusions: String = ""

    public init() {}

    public var exclusionRangesKHz: [ClosedRange<Int>] {
        exclusions.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }).compactMap { part in
            let nums = part.split(separator: "-").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard let a = nums.first else { return nil }
            let b = nums.count > 1 ? nums[1] : a
            let lo = Int((min(a, b) * 1000).rounded()), hi = Int((max(a, b) * 1000).rounded())
            return lo...hi
        }
    }
}

/// What one receiver can tune to. Frequencies must lie within low...high and on a multiple of step.
public struct TuningLimit: Equatable {
    public var lowKHz: Int?
    public var highKHz: Int?
    public var stepKHz: Int?
    public init(lowKHz: Int? = nil, highKHz: Int? = nil, stepKHz: Int? = nil) {
        self.lowKHz = lowKHz; self.highKHz = highKHz; self.stepKHz = stepKHz
    }
    public func allows(_ kHz: Int) -> Bool {
        if let l = lowKHz, kHz < l { return false }
        if let h = highKHz, kHz > h { return false }
        if let st = stepKHz, st > 0, kHz % st != 0 { return false }
        return true
    }
}

public struct NamedFrequency: Equatable {
    public var label: String
    public var kHz: Int
    public init(label: String, kHz: Int) { self.label = label; self.kHz = kHz }
}

public struct Conflict: Identifiable, Equatable {
    public var id: String { "\(kind)|\(victim)|\(sources)" }
    public var kind: String
    public var victim: String
    public var sources: String
    public var offsetKHz: Int
}

public enum Coordinator {
    /// Finds up to `count` new frequencies compatible with each other and with `fixed`
    /// (everything on air at the same time).
    public static func coordinate(count: Int, fixed: [Int], settings s: CoordSettings,
                                  region: RegionProfile? = nil,
                                  level: ((Int, Int) -> Double?)? = nil,
                                  timeBudget: TimeInterval = 1.5) -> [Int] {
        let r = coordinate(targets: Array(repeating: [0], count: count),
                           fixed: fixed.map { (kHz: $0, active: Set([0])) }, segmentCount: 1,
                           settings: s, region: region, level: level, timeBudget: timeBudget)
        return r.compactMap { $0 }.sorted()
    }

    /// Time-of-use aware coordination. The show day is split into `segmentCount` pieces
    /// (see `Schedule.segments`); each target / fixed carrier lists the pieces it is on air in.
    /// Carriers only need to be compatible with carriers that are on air at the same time,
    /// so groups that never overlap can share frequencies.
    /// Returns one frequency (kHz) per target, or nil where none could be found.
    /// `limits[i]` (optional) restricts target i to what that receiver can tune to.
    public static func coordinate(targets: [Set<Int>], fixed: [(kHz: Int, active: Set<Int>)],
                                  segmentCount: Int, settings s: CoordSettings,
                                  region: RegionProfile? = nil,
                                  limits: [TuningLimit?]? = nil,
                                  level: ((Int, Int) -> Double?)? = nil,
                                  timeBudget: TimeInterval = 1.5) -> [Int?] {
        let none = [Int?](repeating: nil, count: targets.count)
        guard !targets.isEmpty else { return [] }
        let startK = Int((s.startMHz * 1000).rounded()), stopK = Int((s.stopMHz * 1000).rounded())
        guard stopK > startK, s.stepKHz > 0 else { return none }
        let segCount = max(1, segmentCount)

        var excl = s.exclusionRangesKHz
        if s.avoidRegionBands, let r = region {
            excl += r.restricted.map { Int($0.lowMHz * 1000)...Int($0.highMHz * 1000) }
        }

        // Candidate grid with scan level bucket (3 dB) so quiet spectrum is tried first.
        var cands: [(f: Int, bucket: Int)] = []
        var f = startK
        while f <= stopK {
            defer { f += s.stepKHz }
            if excl.contains(where: { $0.contains(f) }) { continue }
            var bucket = 0
            if s.useScan, let lv = level?(f - 100, f + 100) {
                if lv > s.thresholdDBm { continue }
                bucket = Int((lv / 3).rounded(.down))
            }
            cands.append((f, bucket))
        }

        var best = none
        var bestCount = -1
        let deadline = Date().addingTimeInterval(timeBudget)
        var attempt = 0
        while bestCount < targets.count && (attempt == 0 || Date() < deadline) && attempt < 400 {
            let order: [Int]
            if attempt == 0 {
                order = cands.sorted { ($0.bucket, $0.f) < ($1.bucket, $1.f) }.map { $0.f }
            } else {
                order = cands.map { ($0.f, $0.bucket, Int.random(in: 0..<1_000_000)) }
                    .sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map { $0.0 }
            }
            var plans = [Plan](repeating: Plan(settings: s), count: segCount)
            for fx in fixed {
                for seg in segs(fx.active, segCount) { plans[seg].add(fx.kHz) }
            }
            var assign = none
            var found = 0
            for (ti, mask) in targets.enumerated() {
                let tsegs = segs(mask, segCount)
                let limit = (limits != nil && ti < limits!.count) ? limits![ti] : nil
                for c in order where (limit?.allows(c) ?? true) && tsegs.allSatisfy({ plans[$0].accepts(c) }) {
                    for seg in tsegs { plans[seg].add(c) }
                    assign[ti] = c
                    found += 1
                    break
                }
            }
            if found > bestCount { best = assign; bestCount = found }
            attempt += 1
        }
        return best
    }

    private static func segs(_ mask: Set<Int>, _ count: Int) -> [Int] {
        let v = mask.filter { $0 >= 0 && $0 < count }.sorted()
        return v.isEmpty ? Array(0..<count) : v
    }

    /// Conflicts among carriers that are on air together. `active[i]` lists the schedule
    /// segments item i is on air in (empty = always).
    public static func analyze(_ items: [NamedFrequency], active: [Set<Int>], segmentCount: Int,
                               settings s: CoordSettings) -> [Conflict] {
        guard segmentCount > 1, active.count == items.count else { return analyze(items, settings: s) }
        var seen = Set<String>()
        var out: [Conflict] = []
        for seg in 0..<segmentCount {
            let on = items.indices.filter { active[$0].isEmpty || active[$0].contains(seg) }
            for c in analyze(on.map { items[$0] }, settings: s) where !seen.contains(c.id) {
                seen.insert(c.id)
                out.append(c)
            }
        }
        return out
    }

    /// Lists spacing violations and intermod hits among existing frequencies.
    public static func analyze(_ items: [NamedFrequency], settings s: CoordSettings) -> [Conflict] {
        var out: [Conflict] = []
        let n = items.count
        guard n >= 2 else { return [] }
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = abs(items[i].kHz - items[j].kHz)
                if d < s.spacingKHz {
                    out.append(Conflict(kind: "Spacing", victim: items[i].label,
                                        sources: items[j].label, offsetKHz: d))
                }
            }
        }
        func check(_ p: Int, _ tol: Int, _ kind: String, _ src: String, skip: Set<Int>) {
            for v in 0..<n where !skip.contains(v) {
                let d = abs(items[v].kHz - p)
                if d < tol { out.append(Conflict(kind: kind, victim: items[v].label, sources: src, offsetKHz: d)) }
            }
        }
        for a in 0..<n {
            for b in 0..<n where b != a {
                let fa = items[a].kHz, fb = items[b].kHz
                let src = "\(items[a].label) × \(items[b].label)"
                check(2 * fa - fb, s.imd3x2KHz, "3rd order 2-Tx", src, skip: [a, b])
                if s.use5th { check(3 * fa - 2 * fb, s.imd5x2KHz, "5th order 2-Tx", src, skip: [a, b]) }
            }
        }
        if s.use3Tx {
            for a in 0..<n {
                for b in (a + 1)..<n {
                    for c in 0..<n where c != a && c != b {
                        let p = items[a].kHz + items[b].kHz - items[c].kHz
                        check(p, s.imd3x3KHz, "3rd order 3-Tx",
                              "\(items[a].label) + \(items[b].label) − \(items[c].label)", skip: [a, b, c])
                    }
                }
            }
        }
        return out
    }

    // MARK: - Incremental plan state

    struct Plan {
        let s: CoordSettings
        var chosen: [Int] = []   // sorted
        var p32: [Int] = []      // 2f1 - f2
        var p33: [Int] = []      // f1 + f2 - f3
        var p52: [Int] = []      // 3f1 - 2f2

        init(settings: CoordSettings) { s = settings }

        static func lowerBound(_ a: [Int], _ v: Int) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if a[mid] < v { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        static func insert(_ a: inout [Int], _ v: Int) {
            a.insert(v, at: lowerBound(a, v))
        }

        static func nearest(_ a: [Int], _ v: Int) -> Int {
            guard !a.isEmpty else { return Int.max }
            let i = lowerBound(a, v)
            var d = Int.max
            if i < a.count { d = a[i] - v }
            if i > 0 { d = min(d, v - a[i - 1]) }
            return d
        }

        func accepts(_ c: Int) -> Bool {
            if Plan.nearest(chosen, c) < s.spacingKHz { return false }
            if Plan.nearest(p32, c) < s.imd3x2KHz { return false }
            if s.use5th && Plan.nearest(p52, c) < s.imd5x2KHz { return false }
            if s.use3Tx && Plan.nearest(p33, c) < s.imd3x3KHz { return false }
            // Products created by c must not land on existing carriers.
            for f in chosen {
                if Plan.nearest(chosen, 2 * c - f) < s.imd3x2KHz { return false }
                if Plan.nearest(chosen, 2 * f - c) < s.imd3x2KHz { return false }
                if s.use5th {
                    if Plan.nearest(chosen, 3 * c - 2 * f) < s.imd5x2KHz { return false }
                    if Plan.nearest(chosen, 3 * f - 2 * c) < s.imd5x2KHz { return false }
                }
            }
            if s.use3Tx {
                let n = chosen.count
                for i in 0..<n {
                    for j in 0..<n where j != i {
                        if Plan.nearest(chosen, c + chosen[i] - chosen[j]) < s.imd3x3KHz {
                            // c + fi - fj landing on fj means c = 2fj - fi, already covered above.
                            return false
                        }
                    }
                    for j in (i + 1)..<n {
                        if Plan.nearest(chosen, chosen[i] + chosen[j] - c) < s.imd3x3KHz { return false }
                    }
                }
            }
            return true
        }

        mutating func add(_ c: Int) {
            for f in chosen {
                Plan.insert(&p32, 2 * c - f)
                Plan.insert(&p32, 2 * f - c)
                if s.use5th {
                    Plan.insert(&p52, 3 * c - 2 * f)
                    Plan.insert(&p52, 3 * f - 2 * c)
                }
            }
            if s.use3Tx {
                let n = chosen.count
                for i in 0..<n {
                    for j in 0..<n where j != i { Plan.insert(&p33, c + chosen[i] - chosen[j]) }
                    for j in (i + 1)..<n { Plan.insert(&p33, chosen[i] + chosen[j] - c) }
                }
            }
            Plan.insert(&chosen, c)
        }
    }
}
