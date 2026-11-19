import Foundation

/// tinySA / tinySA Ultra USB shell. Each command is answered with its echo, output, then "ch> ".
/// Scans use `scan <start_hz> <stop_hz> <points> 3`, which prints "<freq_hz> <level_dBm>" per line.
public enum TinySAProtocol {
    public static let prompt = "ch> "
    /// Max points per sweep on the tinySA Ultra.
    public static let maxPoints = 450

    public struct Segment: Equatable {
        public var startHz: Double
        public var stopHz: Double
        public var points: Int
        public init(startHz: Double, stopHz: Double, points: Int) {
            self.startHz = startHz; self.stopHz = stopHz; self.points = points
        }
    }

    public static func scanCommand(_ s: Segment) -> String {
        "scan \(Int(s.startHz.rounded())) \(Int(s.stopHz.rounded())) \(s.points) 3"
    }

    /// Splits a wide span into sweeps of at most `maxPoints` on an exact `stepHz` grid.
    public static func segments(startHz: Double, stopHz: Double, stepHz: Double,
                                maxPoints: Int = maxPoints) -> [Segment] {
        guard stopHz > startHz, stepHz > 0 else { return [] }
        let total = Int(((stopHz - startHz) / stepHz).rounded()) + 1
        var segs: [Segment] = []
        var i = 0
        while i < total {
            let n = max(2, min(maxPoints, total - i))
            let a = startHz + Double(i) * stepHz
            segs.append(Segment(startHz: a, stopHz: a + Double(n - 1) * stepHz, points: n))
            i += n
        }
        return segs
    }

    /// Removes the echoed command line and the trailing prompt.
    public static func stripResponse(_ text: String, command: String) -> String {
        var t = text
        if t.hasSuffix(prompt) { t.removeLast(prompt.count) }
        if let nl = t.firstIndex(where: { $0.isNewline }) {
            let first = t[..<nl].trimmingCharacters(in: .whitespacesAndNewlines)
            if first == command.trimmingCharacters(in: .whitespacesAndNewlines) {
                t = String(t[t.index(after: nl)...])
            }
        }
        return t
    }

    public static func parseScan(_ text: String) -> [(hz: Double, dBm: Double)] {
        var out: [(hz: Double, dBm: Double)] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 2, let f = Double(p[0]), let l = Double(p[1]) else { continue }
            out.append((f, l))
        }
        return out
    }
}

/// Scan files: "MHz,dBm" per line, compatible with Wireless Workbench / most coordination tools.
public enum ScanCSV {
    public static func export(startKHz: Double, stepKHz: Double, levels: [Double]) -> String {
        var s = ""
        for (i, l) in levels.enumerated() where !l.isNaN {
            s += String(format: "%.3f,%.1f\n", (startKHz + Double(i) * stepKHz) / 1000, l)
        }
        return s
    }

    /// Accepts comma, semicolon or tab separated; frequency in MHz, kHz or Hz. Returns (kHz, dBm).
    public static func parse(_ text: String) -> [(kHz: Double, dBm: Double)] {
        var out: [(kHz: Double, dBm: Double)] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let f = Double(parts[0]), let l = Double(parts[1]) else { continue }
            let kHz: Double
            if f < 10_000 { kHz = f * 1000 } else if f < 10_000_000 { kHz = f } else { kHz = f / 1000 }
            out.append((kHz, l))
        }
        return out.sorted { $0.kHz < $1.kHz }
    }
}
