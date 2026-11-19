import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import WaveDeskCore

/// Built-in web server: phone/tablet monitor page (opened via QR code) and an HTTP API
/// for Bitfocus Companion (Stream Deck) and other control systems.
final class RemoteController: ObservableObject {
    @Published var enabled: Bool { didSet { save(); restart() } }
    @Published var port: Int { didSet { save(); restart() } }
    @Published var allowControl: Bool { didSet { save() } }
    @Published private(set) var key: String
    @Published private(set) var status = "Stopped"
    @Published private(set) var requests = 0

    private let server = HTTPServer()
    private weak var state: AppState?

    init(state: AppState) {
        self.state = state
        let d = UserDefaults.standard
        enabled = d.object(forKey: "remote.enabled") as? Bool ?? true
        port = d.object(forKey: "remote.port") as? Int ?? 8088
        allowControl = d.object(forKey: "remote.control") as? Bool ?? false
        key = d.string(forKey: "remote.key") ?? Self.newKey()
        d.set(key, forKey: "remote.key")
        server.onStateChange = { [weak self] s in self?.status = s }
        server.handler = { [weak self] req in self?.route(req) ?? .text("Unavailable", status: 503) }
        restart()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "remote.enabled")
        d.set(port, forKey: "remote.port")
        d.set(allowControl, forKey: "remote.control")
        d.set(key, forKey: "remote.key")
    }

    private static func newKey() -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<10).map { _ in chars.randomElement()! })
    }

    func regenerateKey() {
        key = Self.newKey()
        save()
    }

    func restart() {
        server.stop()
        guard enabled else { status = "Stopped"; return }
        guard (1024...65535).contains(port) else { status = "Choose a port between 1024 and 65535"; return }
        do { try server.start(port: UInt16(port)) } catch { status = "Could not start: \(error.localizedDescription)" }
    }

    /// Monitor URLs for every network interface (one per IP).
    var monitorURLs: [String] {
        LocalNetwork.ipv4Addresses().map { "http://\($0):\(port)/?key=\(key)" }
    }

    var baseURLs: [String] { LocalNetwork.ipv4Addresses().map { "http://\($0):\(port)" } }

    static func qrCode(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: Routing

    private func route(_ r: HTTPRequest) -> HTTPResponse {
        requests &+= 1
        let given = r.query["key"] ?? r.headers["x-wavedesk-key"] ?? ""
        guard given == key else {
            if r.path == "/" || r.path.isEmpty {
                return .html(MonitorPage.locked, status: 401)
            }
            return .text("Missing or wrong key. Add ?key=… (shown in WaveDesk › Remote).", status: 401)
        }
        guard let state else { return .text("Not ready", status: 503) }
        let parts = r.path.split(separator: "/").map(String.init)

        if parts.isEmpty { return .html(MonitorPage.html) }
        guard parts.first == "api" else { return .text("Not found", status: 404) }
        let p = Array(parts.dropFirst())

        switch p.first ?? "" {
        case "state": return .json(snapshot(state))
        case "spectrum": return .json(spectrum(state))
        case "channels":
            return .json(channelList(state).map { ["n": "\($0.n)", "name": state.label($0.device, $0.channel)] })
        case "alerts":
            if p.count >= 2 && p[1] == "count" { return .text("\(state.health.active.count)") }
            return .json(snapshot(state).alerts)
        case "ch":
            return channelRoute(state, Array(p.dropFirst()))
        case "scan", "coordinate", "apply":
            guard allowControl else { return forbidden }
            return controlRoute(state, p)
        default:
            return .text("Not found", status: 404)
        }
    }

    private var forbidden: HTTPResponse {
        .text("Remote control is switched off. Enable “Allow control” in WaveDesk › Remote.", status: 403)
    }

    private func controlRoute(_ s: AppState, _ p: [String]) -> HTTPResponse {
        switch (p[0], p.count > 1 ? p[1] : "") {
        case ("scan", "start"): s.analyzer.startScan()
        case ("scan", "stop"): s.analyzer.stopScan()
        case ("scan", "toggle"): if s.analyzer.scanning { s.analyzer.stopScan() } else { s.analyzer.startScan() }
        case ("coordinate", _): s.runCoordination()
        case ("apply", _): s.applyAllProposals()
        default: return .text("Unknown command", status: 404)
        }
        return .text("OK")
    }

    /// /api/ch/{n}/{field} (read) and /api/ch/{n}/mute/{on|off|toggle}, /api/ch/{n}/gain/{up|down} (control)
    private func channelRoute(_ s: AppState, _ p: [String]) -> HTTPResponse {
        let list = channelList(s)
        guard let first = p.first, let n = Int(first), let item = list.first(where: { $0.n == n }) else {
            return .text("Unknown channel. See /api/channels for numbers.", status: 404)
        }
        let d = item.device, c = item.channel
        let field = p.count > 1 ? p[1].lowercased() : "json"
        if p.count > 2 {
            guard allowControl else { return forbidden }
            switch (field, p[2].lowercased()) {
            case ("mute", "on"): d.set(.mute(true), channel: c.idx)
            case ("mute", "off"): d.set(.mute(false), channel: c.idx)
            case ("mute", "toggle"): d.set(.mute(!(c.mute ?? false)), channel: c.idx)
            case ("gain", "up"): if let g = c.gain { d.set(.gain(g + 1), channel: c.idx) }
            case ("gain", "down"): if let g = c.gain { d.set(.gain(g - 1), channel: c.idx) }
            default: return .text("Unknown command", status: 404)
            }
            return .text("OK")
        }
        let key = AppState.key(d, c.idx)
        func t(_ v: Int?) -> String { v.map(String.init) ?? "" }
        switch field {
        case "json": return .json(remoteChannel(s, n: n, d: d, c: c))
        case "name": return .text(s.label(d, c))
        case "freq": return .text(c.freqKHz.map { String(format: "%.3f", Double($0) / 1000) } ?? "")
        case "rf": return .text(t([c.rfA, c.rfB].compactMap { $0 }.max()))
        case "rfa": return .text(t(c.rfA))
        case "rfb": return .text(t(c.rfB))
        case "audio": return .text(t(c.audio))
        case "battery": return .text(t(c.battBars))
        case "batterymin": return .text(t(c.battMin))
        case "gain": return .text(t(c.gain))
        case "mute": return .text(c.mute == true ? "1" : "0")
        case "online": return .text(d.online ? "1" : "0")
        case "alerts": return .text("\(s.health.activeAlerts(for: key).count)")
        case "group": return .text(s.group(forKey: key)?.name ?? "")
        default: return .text("Unknown field", status: 404)
        }
    }

    // MARK: JSON models

    struct Item { var n: Int; var device: Device; var channel: ChannelState }

    /// Every channel numbered 1...N in the order shown in the app (stable while devices don't change).
    func channelList(_ s: AppState) -> [Item] {
        var out: [Item] = []
        for d in s.devices { for c in d.channels { out.append(Item(n: out.count + 1, device: d, channel: c)) } }
        return out
    }

    struct RChannel: Encodable {
        var n: Int, name: String, device: String, kind: String, online: Bool
        var freqMHz: Double?, proposedMHz: Double?
        var rfA: Int?, rfB: Int?, audio: Int?, battBars: Int?, battMin: Int?, gain: Int?, mute: Bool?
        var group: String?, groupColor: Int?, alerts: [String], severity: String?
    }
    struct RAlert: Encodable { var title: String, detail: String, severity: String, since: Double }
    struct RAnalyzer: Encodable { var connected: Bool, scanning: Bool, status: String, passes: Int }
    struct RState: Encodable {
        var app: String, version: String, project: String, venue: String, region: String, time: Double
        var control: Bool, conflicts: Int, analyzer: RAnalyzer, alerts: [RAlert], channels: [RChannel]
    }

    private func sev(_ s: Severity) -> String { s == .critical ? "critical" : s == .warning ? "warning" : "info" }

    private func remoteChannel(_ s: AppState, n: Int, d: Device, c: ChannelState) -> RChannel {
        let key = AppState.key(d, c.idx)
        let alerts = s.health.activeAlerts(for: key)
        let g = s.group(forKey: key)
        return RChannel(n: n, name: s.label(d, c), device: d.displayName, kind: d.kind.short, online: d.online,
                        freqMHz: c.freqKHz.map { Double($0) / 1000 }, proposedMHz: s.proposals[key].map { Double($0) / 1000 },
                        rfA: c.rfA, rfB: c.rfB, audio: c.audio, battBars: c.battBars, battMin: c.battMin,
                        gain: c.gain, mute: c.mute, group: g?.name, groupColor: g?.colorIndex,
                        alerts: alerts.map(\.title), severity: alerts.map(\.severity).max().map(sev))
    }

    private func snapshot(_ s: AppState) -> RState {
        let a = s.analyzer
        return RState(app: "WaveDesk", version: Updater.currentVersion, project: s.project.name, venue: s.project.venue,
                      region: s.region.name, time: Date().timeIntervalSince1970, control: allowControl,
                      conflicts: s.conflicts.count,
                      analyzer: RAnalyzer(connected: a.connected, scanning: a.scanning, status: a.status, passes: a.passes),
                      alerts: s.health.active.map { RAlert(title: $0.title, detail: $0.detail, severity: sev($0.severity),
                                                           since: $0.since.timeIntervalSince1970) },
                      channels: channelList(s).map { remoteChannel(s, n: $0.n, d: $0.device, c: $0.channel) })
    }

    struct RMarker: Encodable { var label: String, kHz: Int, conflict: Bool }
    struct RBand: Encodable { var label: String, lo: Double, hi: Double }
    struct RSpectrum: Encodable {
        var startKHz: Double, stopKHz: Double
        var live: [Double?], peak: [Double?]
        var markers: [RMarker], tv: [RBand], restricted: [RBand], threshold: Double
    }

    private func spectrum(_ s: AppState) -> RSpectrum {
        let a = s.analyzer
        let n = a.live.count
        let lo = n > 1 ? a.gridStartKHz : a.startMHz * 1000
        let hi = n > 1 ? a.gridStartKHz + Double(n - 1) * a.gridStepKHz : a.stopMHz * 1000
        func down(_ v: [Double]) -> [Double?] {
            guard !v.isEmpty else { return [] }
            let cols = min(700, v.count)
            var out = [Double?](repeating: nil, count: cols)
            for (i, x) in v.enumerated() where !x.isNaN {
                let c = i * cols / v.count
                out[c] = max(out[c] ?? -999, x)
            }
            return out
        }
        let bad = Set(s.conflicts.map(\.victim))
        let r = s.region
        return RSpectrum(startKHz: lo, stopKHz: hi, live: down(a.live), peak: down(a.peak),
                         markers: s.markers.map { RMarker(label: $0.label, kHz: $0.kHz, conflict: bad.contains($0.label)) },
                         tv: r.tvChannels.filter { $0.highMHz * 1000 > lo && $0.lowMHz * 1000 < hi }
                            .map { RBand(label: "\($0.number)", lo: $0.lowMHz * 1000, hi: $0.highMHz * 1000) },
                         restricted: r.restricted.map { RBand(label: $0.label, lo: $0.lowMHz * 1000, hi: $0.highMHz * 1000) },
                         threshold: s.project.coord.thresholdDBm)
    }
}
