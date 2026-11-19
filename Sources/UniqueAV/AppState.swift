import Foundation
import Combine
import Network
import UniqueAVCore

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
    let updater: Updater
    private(set) var remote: RemoteController!

    private var sinks: [AnyCancellable] = []
    private var healthTimer: Timer?
    private var savePending = false
    private var recomputePending = false

    var region: RegionProfile { RegionProfile.byID(project.regionID) }

    init(updater: Updater) {
        self.updater = updater
        let last = UserDefaults.standard.string(forKey: "uniqueav.lastProject") ?? "My first show"
        project = Self.loadProject(named: last) ?? Self.newProjectValue(named: last)
        refreshProjectNames()
        // The analyzer is a separate ObservableObject; forward its changes so markers/overlays redraw.
        sinks.append(analyzer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        sinks.append(health.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        activateProject()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.healthTick() }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
        remote = RemoteController(state: self)
        NetworkManager.shared.onReceiverNetworkChange = { [weak self] in self?.reconnectAll() }
        if CommandLine.arguments.contains("--demo") { startDemo() }
    }

    /// `open "Unique AV RF Scan Co-ord.app" --args --demo`: demo receiver + simulated analyzer, scanning.
    func startDemo() {
        if !devices.contains(where: { $0.kind == .demo }) { addDevice(kind: .demo, host: "", nickname: "Demo rack") }
        analyzer.sourceKind = .simulated
        analyzer.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.analyzer.startScan() }
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

    func addDevice(kind: DeviceKind, host: String, nickname: String, password: String? = nil,
                   model: String? = nil, channelCount: Int = 1,
                   tuneLowMHz: Double? = nil, tuneHighMHz: Double? = nil, tuneStepKHz: Int? = nil) {
        var cfg = DeviceConfig(kind: kind, host: host.trimmingCharacters(in: .whitespaces),
                               nickname: nickname, password: password,
                               tuneLowMHz: tuneLowMHz, tuneHighMHz: tuneHighMHz, tuneStepKHz: tuneStepKHz)
        if kind.isManual {
            cfg.model = model
            cfg.manualChannels = (1...max(1, min(16, channelCount))).map { ManualChannel(name: "CH \($0)", freqKHz: nil) }
        }
        let d = Device.make(cfg)
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

    func setTuning(_ d: Device, low: Double?, high: Double?, step: Int?) {
        d.tuneLowMHz = low
        d.tuneHighMHz = high
        d.tuneStepKHz = step
        scheduleSave()
    }

    func rename(_ d: Device, nickname: String) {
        d.nickname = nickname
        scheduleSave()
        recomputeMarkers()
    }

    private func attach(_ d: Device) {
        let manual = d.kind.isManual
        d.onIdentityChange = { [weak self] in
            self?.scheduleRecompute()
            if manual { self?.scheduleSave() }   // manual channels only live in the project file
        }
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
        let limits: [TuningLimit?] = tgt.map { lookup($0.key)?.0.tuning }
        let snap = analyzer.snapshot
        let s = project.coord, reg = region
        let useScan = s.useScan && !snap.isEmpty
        coordinating = true
        coordMessage = "Calculating…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let freqs = Coordinator.coordinate(
                targets: masks, fixed: fx, segmentCount: segs.count, settings: s, region: reg, limits: limits,
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

    // MARK: Receiver search

    @Published var discovering = false
    @Published private(set) var discovered: [FoundDevice] = []
    @Published var discoveryProgress = ""
    private var discoveryRun = 0
    private var pendingParts = 0

    /// Searches the way Wireless Workbench does (Shure Discovery multicast + UHF-R broadcast) and, at the
    /// same time, knocks on every address of the receiver network. `deep` also sweeps a whole 169.254 network.
    func discoverShure(deep: Bool = false) {
        guard !discovering else { return }
        Self.raiseOpenFileLimit()
        let net = NetworkManager.shared
        let ifaces = net.receiverInterface.map { [$0] } ?? net.interfaces
        guard !ifaces.isEmpty else { coordMessage = "No network connection found"; return }
        discovering = true
        discovered = []
        discoveryRun += 1
        let run = discoveryRun
        pendingParts = 2
        discoveryProgress = "Asking Shure devices to identify themselves…"

        ShureDiscovery.run(interfaces: ifaces, duration: 5, found: { [weak self] ip, kind, hint in
            guard let self, run == self.discoveryRun else { return }
            self.record(ip, kind: kind, source: kind == .shureUHFR ? "UHF-R broadcast" : "Shure Discovery", hint: hint)
        }, done: { [weak self] in
            guard let self, run == self.discoveryRun else { return }
            self.partDone()
        })

        let d = net.discoveryHosts()
        let sweep = d.linkLocal && !deep ? [] : d.sweep
        let hosts = d.known + sweep
        let big = hosts.count > 2000
        probe(hosts, from: 0, batch: big ? 512 : 192, window: big ? 2.0 : 2.5, run: run, firstBatch: d.known.count)
    }

    func stopDiscovery() {
        discoveryRun += 1
        discovering = false
        discoveryProgress = ""
    }

    private func partDone() {
        pendingParts -= 1
        if pendingParts <= 0 {
            discovering = false
            let n = discovered.count
            discoveryProgress = n == 0 ? "" : "Found \(n) device\(n == 1 ? "" : "s")"
        }
    }

    /// Adds or updates a found device, then checks it on the control port and reads its model and name.
    private func record(_ ip: String, kind: DeviceKind, source: String, hint: String = "") {
        let net = NetworkManager.shared
        if let i = discovered.firstIndex(where: { $0.ip == ip }) {
            discovered[i].sources.insert(source)
            if discovered[i].hint.isEmpty { discovered[i].hint = hint }
            if kind == .shureUHFR { discovered[i].kind = .shureUHFR }
            return
        }
        var f = FoundDevice(ip: ip, kind: kind, sources: [source], hint: hint)
        f.onMacNetwork = net.interface(containing: ip) != nil
        if !f.onMacNetwork {
            f.reachable = false
            let ours = net.interfaces.map { "\($0.displayName) \($0.subnet)" }.joined(separator: ", ")
            f.problem = "Answers Shure Discovery, but \(ip) isn't on this Mac's network (\(ours)). Set the receiver's IP mode to Automatic, or give it / the Mac an address in the same range."
        } else if kind == .shureUHFR {
            f.reachable = true
        }
        discovered.append(f)
        discovered.sort { (IPv4.parse($0.ip) ?? 0) < (IPv4.parse($1.ip) ?? 0) }
        guard f.onMacNetwork, kind == .shure else { return }
        ShureDiscovery.identify(ip: ip) { [weak self] ok, model, name, problem in
            guard let self, let i = self.discovered.firstIndex(where: { $0.ip == ip }) else { return }
            self.discovered[i].reachable = ok
            self.discovered[i].model = model
            self.discovered[i].name = name
            self.discovered[i].problem = ok ? "" : problem
        }
    }

    /// Adds a found device to the project (uses the name it reported).
    func addFound(_ f: FoundDevice) {
        guard !devices.contains(where: { $0.host == f.ip }) else { return }
        addDevice(kind: f.kind, host: f.ip, nickname: f.name)
    }

    func addAllFound() {
        for f in discovered where f.reachable == true { addFound(f) }
    }

    private func probe(_ hosts: [String], from start: Int, batch: Int, window: Double, run: Int, firstBatch: Int) {
        guard run == discoveryRun else { return }
        guard start < hosts.count else { partDone(); return }
        let size = (start == 0 && firstBatch > 0) ? min(firstBatch, 512) : batch
        let slice = hosts[start..<min(hosts.count, start + size)]
        let left = Double(hosts.count - start) / Double(batch) * window
        discoveryProgress = "Checked \(start) of \(hosts.count) addresses"
            + (left > 20 ? String(format: " – about %.0f min left", max(1, left / 60)) : "")
        var conns: [NWConnection] = []
        for host in slice {
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = Int(window.rounded(.up))
            let params = NetworkManager.shared.parameters(NWParameters(tls: nil, tcp: tcp))
            let c = NWConnection(host: NWEndpoint.Host(host), port: 2202, using: params)
            c.stateUpdateHandler = { [weak self, weak c] st in
                switch st {
                case .ready:
                    c?.cancel()
                    guard let self, run == self.discoveryRun else { return }
                    self.record(host, kind: .shure, source: "address scan")
                case .waiting(let e), .failed(let e):
                    _ = NetworkManager.shared.explain(e, path: c?.currentPath)   // flags a Local Network denial
                default: break
                }
            }
            c.start(queue: .main)
            conns.append(c)
        }
        let all = conns
        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
            all.forEach { $0.cancel() }
            self?.probe(hosts, from: start + size, batch: batch, window: window, run: run, firstBatch: firstBatch)
        }
    }

    /// Apps start with a low limit on open connections (often 256); the search needs more.
    static func raiseOpenFileLimit() {
        var r = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &r) == 0 else { return }
        let want = min(rlim_t(4096), r.rlim_max)
        if r.rlim_cur < want { r.rlim_cur = want; _ = setrlimit(RLIMIT_NOFILE, &r) }
    }

    /// Reconnects every receiver (after the receiver network changes).
    func reconnectAll() {
        for d in devices { d.stop(); d.start() }
    }

    // MARK: Projects

    private static func url(for name: String) -> URL {
        Storage.projects.appendingPathComponent(Storage.safeFileName(name) + ".\(Storage.projectExtension)")
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
        var names = files.filter { $0.pathExtension == Storage.projectExtension }.map { $0.deletingPathExtension().lastPathComponent }
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
        UserDefaults.standard.set(project.name, forKey: "uniqueav.lastProject")
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
        UserDefaults.standard.set(name, forKey: "uniqueav.lastProject")
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
