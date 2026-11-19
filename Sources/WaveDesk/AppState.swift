import Foundation
import Combine
import Network
import WaveDeskCore

struct ChannelPlan: Codable, Equatable {
    var include = true      // let the coordinator choose a new frequency for this channel
    var locked = false      // keep the current frequency (still protected against intermod)
    var groupID: UUID?      // time-of-use group; nil = on air all the time
}

struct Marker: Identifiable, Equatable {
    var id: String          // channel key
    var label: String
    var kHz: Int
    var kind: DeviceKind
    var groupID: UUID?
}

/// Everything that belongs to one show / venue. Saved as JSON in Application Support.
struct Project: Codable, Equatable {
    var name: String
    var venue = ""
    var notes = ""
    var devices: [DeviceConfig] = []
    var regionID = "za"
    var coord = CoordSettings()
    var plans: [String: ChannelPlan] = [:]
    var groups: [UsageGroup] = []
    var health = HealthSettings()
    var overlayScanIDs: [UUID] = []
}

final class AppState: ObservableObject {
    @Published var devices: [Device] = []
    @Published var project: Project { didSet { if project != oldValue { scheduleSave(); if project.coord != oldValue.coord || project.groups != oldValue.groups || project.plans != oldValue.plans { scheduleRecompute() } } } }
    @Published private(set) var projectNames: [String] = []
    @Published var proposals: [String: Int] = [:]
    @Published private(set) var markers: [Marker] = []
    @Published private(set) var conflicts: [Conflict] = []
    @Published var coordMessage = ""
    @Published var coordinating = false
    @Published var showIMDProducts = false
    @Published var selectedChannel: String?

    let analyzer = AnalyzerController()
    let library = ScanLibrary()
    let inventory = InventoryStore()
    let telemetry = TelemetryStore()
    let health = HealthMonitor()

    private var sinks: [AnyCancellable] = []
    private var healthTimer: Timer?
    private var savePending = false
    private var recomputePending = false

    var region: RegionProfile { RegionProfile.byID(project.regionID) }

    init() {
        let last = UserDefaults.standard.string(forKey: "wavedesk.lastProject") ?? "My first show"
        project = Self.loadProject(named: last) ?? Self.newProjectValue(named: last)
        refreshProjectNames()
        // The analyzer is a separate ObservableObject; forward its changes so markers/overlays redraw.
        sinks.append(analyzer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        sinks.append(health.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        activateProject()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.healthTick() }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
    }

    // MARK: Keys and lookups

    static func key(_ d: Device, _ idx: Int) -> String { "\(d.id.uuidString)#\(idx)" }

    func plan(_ d: Device, _ idx: Int) -> ChannelPlan { project.plans[Self.key(d, idx)] ?? ChannelPlan() }

    func setPlan(_ d: Device, _ idx: Int, _ p: ChannelPlan) { project.plans[Self.key(d, idx)] = p }

    func lookup(_ key: String) -> (Device, Int)? {
        let parts = key.split(separator: "#")
        guard parts.count == 2, let idx = Int(parts[1]),
              let d = devices.first(where: { $0.id.uuidString == parts[0] }) else { return nil }
        return (d, idx)
    }

    func label(_ d: Device, _ c: ChannelState) -> String {
        c.name.isEmpty ? "\(d.displayName) ch\(c.idx)" : c.name
    }

    func group(_ id: UUID?) -> UsageGroup? {
        guard let id else { return nil }
        return project.groups.first { $0.id == id }
    }

    func group(forKey key: String) -> UsageGroup? { group(project.plans[key]?.groupID) }

    // MARK: Devices

    func addDevice(kind: DeviceKind, host: String, nickname: String, password: String? = nil) {
        let d = Device.make(DeviceConfig(kind: kind, host: host.trimmingCharacters(in: .whitespaces),
                                         nickname: nickname, password: password))
        attach(d)
        devices.append(d)
        d.start()
        scheduleSave()
        recomputeMarkers()
    }

    func remove(_ d: Device) {
        d.stop()
        devices.removeAll { $0.id == d.id }
        project.plans = project.plans.filter { !$0.key.hasPrefix(d.id.uuidString) }
        proposals = proposals.filter { !$0.key.hasPrefix(d.id.uuidString) }
        scheduleSave()
        recomputeMarkers()
    }

    func rename(_ d: Device, nickname: String) {
        d.nickname = nickname
        scheduleSave()
        recomputeMarkers()
    }

    private func attach(_ d: Device) {
        d.onIdentityChange = { [weak self] in self?.scheduleRecompute() }
    }

    private func scheduleRecompute() {
        guard !recomputePending else { return }
        recomputePending = true
        DispatchQueue.main.async { [weak self] in
            self?.recomputePending = false
            self?.recomputeMarkers()
        }
    }

    func recomputeMarkers() {
        var m: [Marker] = []
        for d in devices {
            for c in d.channels {
                if let f = c.freqKHz {
                    let k = Self.key(d, c.idx)
                    m.append(Marker(id: k, label: label(d, c), kHz: f, kind: d.kind, groupID: project.plans[k]?.groupID))
                }
            }
        }
        m.sort { $0.kHz < $1.kHz }
        if m != markers { markers = m }
        analyzer.setDemoCarriers(devices.filter { $0.kind == .demo }.flatMap { $0.channels.compactMap(\.freqKHz) })

        let segs = Schedule.segments(project.groups)
        let items = m.map { NamedFrequency(label: $0.label, kHz: $0.kHz) }
        let active = m.map { mk -> Set<Int> in
            let g = group(mk.groupID)
            return g == nil ? [] : Schedule.activeSegments(g, segs)
        }
        let c = Coordinator.analyze(items, active: active, segmentCount: segs.count, settings: project.coord)
        if c != conflicts { conflicts = c }
    }

    func conflictsFor(_ label: String) -> [Conflict] { conflicts.filter { $0.victim == label } }

    /// 3rd-order 2-Tx products of the current frequencies (spectrum overlay).
    var imdProductsKHz: [Int] {
        let f = markers.map(\.kHz)
        var p: [Int] = []
        for a in f { for b in f where a != b { p.append(2 * a - b) } }
        return p
    }

    // MARK: Coordination

    func runCoordination() {
        let segs = Schedule.segments(project.groups)
        func mask(_ k: String) -> Set<Int> {
            guard let g = group(forKey: k) else { return Set(segs.indices) }
            return Schedule.activeSegments(g, segs)
        }
        var fixed: [(kHz: Int, active: Set<Int>)] = []
        var targets: [(key: String, current: Int)] = []
        for d in devices {
            for c in d.channels {
                let k = Self.key(d, c.idx)
                let p = plan(d, c.idx)
                if p.include && !p.locked && d.kind.supported.contains(.frequency) {
                    targets.append((k, c.freqKHz ?? 0))
                } else if let f = c.freqKHz {
                    fixed.append((f, mask(k)))
                }
            }
        }
        guard !targets.isEmpty else {
            coordMessage = "No channels selected. Tick “Coordinate” on the channels that need new frequencies."
            return
        }
        targets.sort { $0.current < $1.current }
        let tgt = targets, fx = fixed
        let masks = tgt.map { mask($0.key) }
        let snap = analyzer.snapshot
        let s = project.coord, reg = region
        let useScan = s.useScan && !snap.isEmpty
        coordinating = true
        coordMessage = "Calculating…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let freqs = Coordinator.coordinate(
                targets: masks, fixed: fx, segmentCount: segs.count, settings: s, region: reg,
                level: useScan ? { snap.maxLevel(fromKHz: Double($0), toKHz: Double($1)) } : nil)
            DispatchQueue.main.async {
                guard let self else { return }
                self.coordinating = false
                var props: [String: Int] = [:]
                for (t, f) in zip(tgt, freqs) { if let f { props[t.key] = f } }
                self.proposals = props
                var msg = "Found \(props.count) of \(tgt.count) compatible frequencies"
                if !useScan { msg += " (no scan data used)" }
                if props.count < tgt.count {
                    msg += ". Widen the range, reduce spacing, or turn off 5th-order / 3-Tx checks."
                }
                self.coordMessage = msg
            }
        }
    }

    func applyProposal(_ key: String) {
        guard let f = proposals[key], let hit = lookup(key) else { return }
        hit.0.set(.frequency(f), channel: hit.1)
        proposals[key] = nil
    }

    func applyAllProposals() {
        for k in proposals.keys.sorted() { applyProposal(k) }
    }

    // MARK: Health check + telemetry (every second)

    private func healthTick() {
        let now = Date()
        let t = now.timeIntervalSince1970
        let hs = project.health
        let refScans = analyzer.imported.filter(\.enabled)
        var alerts: [HealthAlert] = []
        func add(_ id: String, _ key: String?, _ sev: Severity, _ title: String, _ detail: String) {
            alerts.append(HealthAlert(id: id, channelKey: key, severity: sev, title: title, detail: detail, since: now))
        }
        for d in devices {
            if !d.online {
                add("offline|\(d.id)", nil, .critical, "\(d.displayName) offline", d.status)
            }
            for c in d.channels {
                let k = Self.key(d, c.idx)
                let name = label(d, c)
                telemetry.record(key: k, label: name, channel: c, online: d.online, at: t)
                guard d.online else { continue }
                let txPresent = c.battBars != nil || !c.txType.isEmpty
                if txPresent, let rf = [c.rfA, c.rfB].compactMap({ $0 }).max(), rf < hs.rfMinDBm {
                    add("rf|\(k)", k, .warning, "Low RF: \(name)", "\(rf) dBm (limit \(hs.rfMinDBm) dBm)")
                }
                if let b = c.battBars, b <= hs.battBarsWarn {
                    add("batt|\(k)", k, b == 0 ? .critical : .warning, "Battery low: \(name)", "\(b) bar(s) left")
                } else if let m = c.battMin, m < hs.battMinutesWarn {
                    add("batt|\(k)", k, .warning, "Battery low: \(name)", "\(m) min left")
                }
                if let a = c.audio, a >= hs.audioClipDBFS {
                    add("clip|\(k)", k, .warning, "Audio clipping: \(name)", "Peak \(a) dBFS – reduce gain")
                }
                if let f = c.freqKHz {
                    let mhz = Double(f) / 1000
                    if let band = region.restricted.first(where: { mhz >= $0.lowMHz && mhz <= $0.highMHz }) {
                        add("band|\(k)", k, .critical, "Restricted band: \(name)",
                            String(format: "%.3f MHz is in %@ (%@)", mhz, band.label, region.name))
                    }
                    let lvl = refScans.compactMap { $0.maxLevel(fromKHz: Double(f - 100), toKHz: Double(f + 100)) }.max()
                    if let lvl, lvl > hs.interferenceDBm {
                        add("intf|\(k)", k, .warning, "Interference: \(name)",
                            String(format: "%.1f dBm at %.3f MHz in reference scan", lvl, mhz))
                    }
                }
            }
        }
        let keyByLabel = Dictionary(markers.map { ($0.label, $0.id) }, uniquingKeysWith: { a, _ in a })
        for cf in conflicts {
            add("conflict|\(cf.id)", keyByLabel[cf.victim], .warning, "\(cf.kind): \(cf.victim)",
                "Hit by \(cf.sources) (\(cf.offsetKHz) kHz away)")
        }
        health.update(hs.enabled ? alerts : [], settings: hs, telemetry: telemetry)
        telemetry.commit()
    }

    // MARK: Time-of-use groups

    func addGroup(name: String) {
        let g = UsageGroup(name: name, colorIndex: project.groups.count % GroupColors.count, slots: [])
        project.groups.append(g)
    }

    func deleteGroup(_ id: UUID) {
        project.groups.removeAll { $0.id == id }
        for (k, p) in project.plans where p.groupID == id { project.plans[k]?.groupID = nil }
    }

    // MARK: Scan library

    func importScanFile(_ url: URL) throws {
        let pts = try AnalyzerController.readScanFile(url)
        let s = library.add(venue: project.venue, title: url.deletingPathExtension().lastPathComponent,
                            regionID: project.regionID, source: "Imported \(url.pathExtension.uppercased())", points: pts)
        showOverlay(s)
        analyzer.status = "Imported \(pts.count) points into the scan library"
    }

    func saveCurrentScan(title: String, notes: String) {
        let pts = analyzer.currentPoints
        guard pts.count >= 2 else { analyzer.status = "Nothing to save – run a scan first"; return }
        let src = analyzer.deviceName.isEmpty ? "tinySA" : analyzer.deviceName
        library.add(venue: project.venue, title: title.isEmpty ? "Scan" : title, regionID: project.regionID,
                    source: src, points: pts, notes: notes)
        analyzer.status = "Saved scan to library (\(project.venue.isEmpty ? "no venue set" : project.venue))"
    }

    func showOverlay(_ s: LibraryScan) {
        analyzer.showOverlay(s)
        if !project.overlayScanIDs.contains(s.id) { project.overlayScanIDs.append(s.id) }
        scheduleRecompute()
    }

    func removeOverlay(_ o: ImportedScan) {
        analyzer.removeOverlay(o.id)
        if let lid = o.libraryID { project.overlayScanIDs.removeAll { $0 == lid } }
    }

    // MARK: Shure discovery

    @Published var discovering = false
    @Published var discovered: [String] = []

    /// Probes every address in the local /24 subnet(s) for Shure's control port (TCP 2202).
    func discoverShure() {
        guard !discovering else { return }
        let prefixes = LocalNetwork.ipv4Prefixes()
        guard !prefixes.isEmpty else { coordMessage = "No IPv4 network found"; return }
        discovering = true
        discovered = []
        var conns: [NWConnection] = []
        let known = Set(devices.map(\.host))
        for prefix in prefixes {
            for i in 1...254 {
                let host = "\(prefix).\(i)"
                if known.contains(host) { continue }
                let c = NWConnection(host: NWEndpoint.Host(host), port: 2202, using: .tcp)
                c.stateUpdateHandler = { [weak self, weak c] st in
                    if case .ready = st {
                        if let self, !self.discovered.contains(host) { self.discovered.append(host) }
                        c?.cancel()
                    }
                }
                c.start(queue: .main)
                conns.append(c)
            }
        }
        let all = conns
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            all.forEach { $0.cancel() }
            self?.discovering = false
        }
    }

    // MARK: Projects

    private static func url(for name: String) -> URL {
        Storage.projects.appendingPathComponent(Storage.safeFileName(name) + ".wdproj")
    }

    private static func loadProject(named name: String) -> Project? {
        Storage.read(Project.self, from: url(for: name))
    }

    private static func newProjectValue(named name: String) -> Project {
        var p = Project(name: name)
        p.coord.startMHz = RegionProfile.southAfrica.defaultStartMHz
        p.coord.stopMHz = RegionProfile.southAfrica.defaultStopMHz
        return p
    }

    func refreshProjectNames() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.projects, includingPropertiesForKeys: nil)) ?? []
        var names = files.filter { $0.pathExtension == "wdproj" }.map { $0.deletingPathExtension().lastPathComponent }
        if !names.contains(Storage.safeFileName(project.name)) { names.append(Storage.safeFileName(project.name)) }
        projectNames = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Builds devices and overlays for `project` and starts talking to the hardware.
    private func activateProject() {
        devices.forEach { $0.stop() }
        devices = project.devices.map { cfg in let d = Device.make(cfg); attach(d); return d }
        devices.forEach { $0.start() }
        proposals = [:]
        coordMessage = ""
        analyzer.imported = []
        for id in project.overlayScanIDs { if let s = library.scan(id) { analyzer.showOverlay(s) } }
        UserDefaults.standard.set(project.name, forKey: "wavedesk.lastProject")
        recomputeMarkers()
    }

    func openProject(_ name: String) {
        saveNow()
        guard let p = Self.loadProject(named: name) else { return }
        project = p
        activateProject()
        refreshProjectNames()
    }

    func newProject(_ name: String, venue: String) {
        saveNow()
        var p = Self.newProjectValue(named: name)
        p.venue = venue
        p.regionID = project.regionID
        let r = RegionProfile.byID(p.regionID)
        p.coord.startMHz = r.defaultStartMHz
        p.coord.stopMHz = r.defaultStopMHz
        project = p
        activateProject()
        saveNow()
        refreshProjectNames()
    }

    /// Copies the current project (devices, groups, settings) under a new name.
    func duplicateProject(as name: String) {
        saveNow()
        project.name = name
        saveNow()
        UserDefaults.standard.set(name, forKey: "wavedesk.lastProject")
        refreshProjectNames()
    }

    func deleteProject(_ name: String) {
        guard name != Storage.safeFileName(project.name) else { return }
        try? FileManager.default.removeItem(at: Self.url(for: name))
        refreshProjectNames()
    }

    func exportProjectData() -> Data? {
        var p = project
        p.devices = devices.map(\.config)
        return try? Storage.encoder.encode(p)
    }

    func importProject(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var p = try Storage.decoder.decode(Project.self, from: data)
        if projectNames.contains(Storage.safeFileName(p.name)) { p.name += " (imported)" }
        saveNow()
        project = p
        activateProject()
        saveNow()
        refreshProjectNames()
    }

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        savePending = false
        var p = project
        p.devices = devices.map(\.config)
        Storage.write(p, to: Self.url(for: p.name))
    }
}

enum GroupColors {
    static let count = 8
}

enum LocalNetwork {
    /// "192.168.1" style prefixes of the Mac's active IPv4 interfaces.
    static func ipv4Prefixes() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(host.count)
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, len, nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            if !out.contains(prefix) { out.append(prefix) }
        }
        return out
    }
}
