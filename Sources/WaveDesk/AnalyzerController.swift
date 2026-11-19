import Foundation
import CoreGraphics
import WaveDeskCore

/// A scan loaded from a file (Shure Wireless Workbench, Sennheiser WSM, RF Explorer, tinySA app...).
struct ImportedScan: Identifiable {
    let id = UUID()
    var libraryID: UUID?
    var name: String
    var points: [(kHz: Double, dBm: Double)]   // sorted by kHz
    var enabled = true

    func maxLevel(fromKHz a: Double, toKHz b: Double) -> Double? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count
        while lo < hi { let m = (lo + hi) / 2; if points[m].kHz < a { lo = m + 1 } else { hi = m } }
        var best: Double?
        var i = lo
        while i < points.count && points[i].kHz <= b { best = max(best ?? -999, points[i].dBm); i += 1 }
        if best == nil {
            // No sample inside the window: use the nearest neighbour if it is close.
            let cands = [lo - 1, lo].filter { $0 >= 0 && $0 < points.count }
            if let n = cands.min(by: { abs(points[$0].kHz - a) < abs(points[$1].kHz - a) }),
               abs(points[n].kHz - (a + b) / 2) < 500 { best = points[n].dBm }
        }
        return best
    }
}

/// Immutable copy of all scan data, safe to use from a background queue.
struct SpectrumSnapshot {
    var startKHz: Double
    var stepKHz: Double
    var levels: [Double]       // NaN = not scanned
    var imported: [ImportedScan]

    var isEmpty: Bool { !levels.contains { !$0.isNaN } && imported.isEmpty }

    func maxLevel(fromKHz a: Double, toKHz b: Double) -> Double? {
        var best: Double?
        if stepKHz > 0, !levels.isEmpty {
            let i0 = max(0, Int(((a - startKHz) / stepKHz).rounded(.down)))
            let i1 = min(levels.count - 1, Int(((b - startKHz) / stepKHz).rounded(.up)))
            if i0 <= i1 {
                for i in i0...i1 where !levels[i].isNaN { best = max(best ?? -999, levels[i]) }
            }
        }
        for s in imported where s.enabled {
            if let l = s.maxLevel(fromKHz: a, toKHz: b) { best = max(best ?? -999, l) }
        }
        return best
    }
}

final class AnalyzerController: ObservableObject {
    @Published var sourceKind: SpectrumSourceKind = .tinySA
    @Published var ports: [SerialPortInfo] = []
    @Published var selectedPort = ""
    @Published var connected = false
    @Published var deviceName = ""
    @Published var scanning = false
    @Published var status = "No analyzer connected"
    @Published var passes = 0

    @Published var startMHz: Double = 470 { didSet { save() } }
    @Published var stopMHz: Double = 694 { didSet { save() } }
    @Published var stepKHz: Double = 25 { didSet { save() } }
    @Published var rbwKHz: Int = 0 { didSet { save() } }   // 0 = auto
    @Published var continuous = true
    @Published var showPeak = true
    @Published var showLive = true

    // Current sweep grid
    @Published private(set) var gridStartKHz: Double = 470_000
    @Published private(set) var gridStepKHz: Double = 25
    @Published private(set) var live: [Double] = []
    @Published private(set) var peak: [Double] = []

    @Published var imported: [ImportedScan] = []

    // Waterfall: one row per ~second of live data, newest at the top.
    @Published private(set) var waterfall: CGImage?
    @Published var showWaterfall = true
    var waterfallFloor: Double = -110
    var waterfallCeiling: Double = -40
    private var wfRows: [[Float]] = []
    private var wfLast = Date.distantPast
    private let wfMaxRows = 160
    private let wfMaxCols = 1200

    private var source: SpectrumSource?
    private let simulated = SimulatedSource()
    private let queue = DispatchQueue(label: "wavedesk.analyzer")
    private let stopLock = NSLock()
    private var stopFlag = false
    private var shouldStop: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return stopFlag }
        set { stopLock.lock(); stopFlag = newValue; stopLock.unlock() }
    }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "an.start") != nil {
            startMHz = d.double(forKey: "an.start")
            stopMHz = d.double(forKey: "an.stop")
            stepKHz = d.double(forKey: "an.step")
            rbwKHz = d.integer(forKey: "an.rbw")
        }
        refreshPorts()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(startMHz, forKey: "an.start"); d.set(stopMHz, forKey: "an.stop")
        d.set(stepKHz, forKey: "an.step"); d.set(rbwKHz, forKey: "an.rbw")
    }

    func refreshPorts() {
        ports = SerialPort.available()
        if !ports.contains(where: { $0.path == selectedPort }) { selectedPort = ports.first?.path ?? "" }
    }

    func setDemoCarriers(_ kHz: [Int]) { simulated.setCarriers(kHz) }

    // MARK: Connection

    func connect() {
        disconnect()
        let kind = sourceKind, port = selectedPort
        if kind.needsPort && port.isEmpty { status = "Plug in the tinySA and press refresh"; return }
        status = "Connecting…"
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let src: SpectrumSource
                if kind == .tinySA { src = try TinySASource(path: port) } else { src = self.simulated }
                DispatchQueue.main.async {
                    self.source = src
                    self.connected = true
                    self.deviceName = src.name
                    self.status = "Connected: \(src.name)"
                }
            } catch {
                DispatchQueue.main.async { self.status = error.localizedDescription }
            }
        }
    }

    func disconnect() {
        stopScan()
        let s = source
        source = nil
        connected = false
        deviceName = ""
        queue.async { s?.close() }
        status = "Disconnected"
    }

    // MARK: Scanning

    func startScan() {
        guard let src = source, !scanning else { return }
        guard stopMHz > startMHz, stepKHz > 0 else { status = "Check start/stop/step"; return }
        let startHz = startMHz * 1e6, stopHz = stopMHz * 1e6, stepHz = stepKHz * 1e3
        let segs = TinySAProtocol.segments(startHz: startHz, stopHz: stopHz, stepHz: stepHz, maxPoints: src.maxPoints)
        let n = segs.reduce(0) { $0 + $1.points }
        gridStartKHz = startHz / 1e3
        gridStepKHz = stepHz / 1e3
        live = Array(repeating: .nan, count: n)
        peak = Array(repeating: .nan, count: n)
        passes = 0
        scanning = true
        shouldStop = false
        status = "Scanning \(segs.count) segment(s)…"
        let cont = continuous, rbw = rbwKHz
        queue.async { [weak self] in
            do {
                try src.prepare(startHz: startHz, stopHz: stopHz, rbwKHz: rbw)
                repeat {
                    for seg in segs {
                        if self?.shouldStop ?? true { break }
                        let pts = try src.sweep(startHz: seg.startHz, stopHz: seg.stopHz, points: seg.points)
                        DispatchQueue.main.async { self?.merge(pts) }
                    }
                    DispatchQueue.main.async { self?.passes += 1 }
                } while cont && !(self?.shouldStop ?? true)
                DispatchQueue.main.async {
                    self?.scanning = false
                    self?.status = "Scan complete (\(self?.passes ?? 0) pass(es))"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.scanning = false
                    self?.status = "Scan error: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopScan() {
        shouldStop = true
    }

    private func merge(_ pts: [(hz: Double, dBm: Double)]) {
        var l = live, p = peak
        for (hz, db) in pts {
            let i = Int(((hz / 1e3 - gridStartKHz) / gridStepKHz).rounded())
            guard i >= 0 && i < l.count else { continue }
            l[i] = db
            p[i] = p[i].isNaN ? db : max(p[i], db)
        }
        live = l
        peak = p
        if Date().timeIntervalSince(wfLast) > 0.8 {
            wfLast = Date()
            pushWaterfallRow(l)
        }
    }

    private func pushWaterfallRow(_ levels: [Double]) {
        guard !levels.isEmpty else { return }
        let cols = min(wfMaxCols, levels.count)
        var row = [Float](repeating: .nan, count: cols)
        for i in 0..<levels.count where !levels[i].isNaN {
            let c = i * cols / levels.count
            row[c] = row[c].isNaN ? Float(levels[i]) : max(row[c], Float(levels[i]))
        }
        if let first = wfRows.first, first.count != cols { wfRows = [] }
        wfRows.insert(row, at: 0)
        if wfRows.count > wfMaxRows { wfRows.removeLast(wfRows.count - wfMaxRows) }
        waterfall = renderWaterfall()
    }

    func clearWaterfall() { wfRows = []; waterfall = nil }

    private func renderWaterfall() -> CGImage? {
        guard let w = wfRows.first?.count, w > 0 else { return nil }
        let h = wfMaxRows
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let lo = Float(waterfallFloor), span = Float(max(1, waterfallCeiling - waterfallFloor))
        for (y, row) in wfRows.enumerated() {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let v = row[x]
                if v.isNaN { px[o + 3] = 0; continue }
                let (r, g, b) = Self.heat(max(0, min(1, (v - lo) / span)))
                px[o] = r; px[o + 1] = g; px[o + 2] = b; px[o + 3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Dark blue -> cyan -> yellow -> red.
    private static func heat(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, Float, Float)] = [(0.02, 0.03, 0.15), (0.0, 0.45, 0.75), (0.1, 0.85, 0.6),
                                              (0.98, 0.9, 0.2), (0.95, 0.2, 0.1)]
        let x = t * Float(stops.count - 1)
        let i = min(Int(x), stops.count - 2), f = x - Float(i)
        let a = stops[i], b = stops[i + 1]
        func c(_ p: Float, _ q: Float) -> UInt8 { UInt8(max(0, min(255, (p + (q - p) * f) * 255))) }
        return (c(a.0, b.0), c(a.1, b.1), c(a.2, b.2))
    }

    func clearPeak() { peak = live }

    // MARK: Files

    /// Reads a scan exported from Shure WWB, Sennheiser WSM, SoundBase, RF Explorer, tinySA-App...
    static func readScanFile(_ url: URL) throws -> [(kHz: Double, dBm: Double)] {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let pts = ScanCSV.parse(text)
        guard pts.count >= 2 else {
            throw NSError(domain: "WaveDesk", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No frequency/level pairs found in \(url.lastPathComponent). Export the scan as CSV or TXT (MHz, dBm)."])
        }
        return pts
    }

    func showOverlay(_ s: LibraryScan) {
        guard !imported.contains(where: { $0.libraryID == s.id }) else { return }
        imported.append(ImportedScan(libraryID: s.id, name: "\(s.venue) – \(s.title)", points: s.points))
    }

    func removeOverlay(_ id: UUID) { imported.removeAll { $0.id == id } }

    /// Current trace (peak hold if available) as points, for saving to the library.
    var currentPoints: [(kHz: Double, dBm: Double)] {
        let src = peak.contains { !$0.isNaN } ? peak : live
        return src.enumerated().compactMap { (i, v) -> (kHz: Double, dBm: Double)? in
            v.isNaN ? nil : (kHz: gridStartKHz + Double(i) * gridStepKHz, dBm: v)
        }
    }

    func exportCSV() -> String {
        ScanCSV.export(startKHz: gridStartKHz, stepKHz: gridStepKHz, levels: showPeak ? peak : live)
    }

    var snapshot: SpectrumSnapshot {
        let hasPeak = peak.contains { !$0.isNaN }
        return SpectrumSnapshot(startKHz: gridStartKHz, stepKHz: gridStepKHz,
                                levels: hasPeak ? peak : live, imported: imported.filter(\.enabled))
    }
}
