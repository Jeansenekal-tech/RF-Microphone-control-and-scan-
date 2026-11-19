import SwiftUI
import AppKit
import WaveDeskCore

struct InspectorPanel: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Scan").tag(0)
                Text("Coordinate").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tab == 0 { ScanPanel(analyzer: state.analyzer) } else { CoordPanel() }
                }
                .padding(10)
            }
        }
    }
}

struct ScanPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var analyzer: AnalyzerController

    var body: some View {
        SectionBox(title: "Analyzer") {
            Picker("Source", selection: $analyzer.sourceKind) {
                ForEach(SpectrumSourceKind.allCases) { Text($0.title).tag($0) }
            }
            if analyzer.sourceKind.needsPort {
                HStack {
                    Picker("Port", selection: $analyzer.selectedPort) {
                        if analyzer.ports.isEmpty { Text("No USB device found").tag("") }
                        ForEach(analyzer.ports) { Text($0.name).tag($0.path) }
                    }
                    Button { analyzer.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Rescan USB ports")
                }
            }
            HStack {
                if analyzer.connected {
                    Button("Disconnect") { analyzer.disconnect() }
                } else {
                    Button("Connect") { analyzer.connect() }.keyboardShortcut("k")
                }
                Spacer()
            }
            Text(analyzer.status).font(.caption).foregroundStyle(.secondary)
            Text("Shure AXT600 / receiver scans and Sennheiser WSM scans: export them as CSV from WWB or WSM and import below.")
                .font(.caption2).foregroundStyle(.secondary)
        }

        SectionBox(title: "Sweep") {
            HStack {
                TextField("Start", value: $analyzer.startMHz, format: .number).frame(width: 80)
                Text("–")
                TextField("Stop", value: $analyzer.stopMHz, format: .number).frame(width: 80)
                Text("MHz")
                Menu("Presets") {
                    Button("\(state.region.name) default (\(Int(state.region.defaultStartMHz))–\(Int(state.region.defaultStopMHz)))") {
                        analyzer.startMHz = state.region.defaultStartMHz; analyzer.stopMHz = state.region.defaultStopMHz
                    }
                    Button("Coordination range") {
                        analyzer.startMHz = state.project.coord.startMHz; analyzer.stopMHz = state.project.coord.stopMHz
                    }
                    Divider()
                    Button("470–694 (UHF TV)") { analyzer.startMHz = 470; analyzer.stopMHz = 694 }
                    Button("470–608") { analyzer.startMHz = 470; analyzer.stopMHz = 608 }
                    Button("470–636") { analyzer.startMHz = 470; analyzer.stopMHz = 636 }
                    Button("606–694") { analyzer.startMHz = 606; analyzer.stopMHz = 694 }
                    Button("823–865") { analyzer.startMHz = 823; analyzer.stopMHz = 865 }
                }
                .fixedSize()
            }
            Picker("Step", selection: $analyzer.stepKHz) {
                ForEach([10.0, 25.0, 50.0, 100.0], id: \.self) { Text("\(Int($0)) kHz").tag($0) }
            }
            Picker("RBW", selection: $analyzer.rbwKHz) {
                Text("Auto").tag(0)
                ForEach([3, 10, 30, 100, 300], id: \.self) { Text("\($0) kHz").tag($0) }
            }
            Toggle("Continuous", isOn: $analyzer.continuous)
            HStack {
                if analyzer.scanning {
                    Button { analyzer.stopScan() } label: { Label("Stop", systemImage: "stop.fill") }
                    ProgressView().controlSize(.small)
                } else {
                    Button { analyzer.startScan() } label: { Label("Scan", systemImage: "play.fill") }
                        .disabled(!analyzer.connected)
                        .keyboardShortcut("r")
                }
                Spacer()
                Text("Passes: \(analyzer.passes)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Live", isOn: $analyzer.showLive)
                Toggle("Peak hold", isOn: $analyzer.showPeak)
                Toggle("Waterfall", isOn: $analyzer.showWaterfall)
            }
            .toggleStyle(.checkbox)
            HStack {
                Button("Clear peak") { analyzer.clearPeak() }
                Button("Clear waterfall") { analyzer.clearWaterfall() }
            }
            .controlSize(.small)
        }

        SectionBox(title: "Scan files & library") {
            HStack {
                Button("Import WWB / WSM / CSV…") {
                    for url in Panels.open(types: Panels.scanTypes, multiple: true) {
                        do { try state.importScanFile(url) } catch { Panels.alert("Import failed", error.localizedDescription) }
                    }
                }
                Button("Save to library…") {
                    if let t = Panels.prompt("Save scan to library",
                                             "Venue: \(state.project.venue.isEmpty ? "(set it on the Project page)" : state.project.venue)",
                                             default: "Scan \(Date().formatted(date: .abbreviated, time: .shortened))") {
                        state.saveCurrentScan(title: t, notes: "")
                    }
                }
            }
            Button("Export current trace as CSV…") {
                Panels.save(Data(analyzer.exportCSV().utf8), suggestedName: "scan.csv", types: [.commaSeparatedText])
            }
            if !analyzer.imported.isEmpty {
                Divider()
                Text("Overlays (also used as reference scans for coordination and health check)")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach($analyzer.imported) { $o in
                    HStack {
                        Toggle(isOn: $o.enabled) { Text(o.name).lineLimit(1) }
                        Spacer()
                        Button { state.removeOverlay(o) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

struct CoordPanel: View {
    @EnvironmentObject var state: AppState

    private func intField(_ title: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number).frame(width: 60).multilineTextAlignment(.trailing)
            Text("kHz").foregroundStyle(.secondary)
        }
    }

    var body: some View {
        SectionBox(title: "Range") {
            HStack {
                TextField("Start", value: $state.project.coord.startMHz, format: .number).frame(width: 80)
                Text("–")
                TextField("Stop", value: $state.project.coord.stopMHz, format: .number).frame(width: 80)
                Text("MHz")
            }
            Picker("Grid", selection: $state.project.coord.stepKHz) {
                ForEach([5, 12, 25, 50, 125], id: \.self) { Text("\($0) kHz").tag($0) }
            }
            Toggle("Avoid \(state.region.name) restricted bands", isOn: $state.project.coord.avoidRegionBands)
            TextField("Exclude (MHz), e.g. 530-538, 594-602", text: $state.project.coord.exclusions)
        }

        SectionBox(title: "Compatibility") {
            intField("Carrier spacing", $state.project.coord.spacingKHz)
            intField("2-Tx 3rd order", $state.project.coord.imd3x2KHz)
            Toggle("3-Tx 3rd order", isOn: $state.project.coord.use3Tx)
            if state.project.coord.use3Tx { intField("  spacing", $state.project.coord.imd3x3KHz) }
            Toggle("2-Tx 5th order", isOn: $state.project.coord.use5th)
            if state.project.coord.use5th { intField("  spacing", $state.project.coord.imd5x2KHz) }
            Toggle("Show IMD products on spectrum", isOn: $state.showIMDProducts)
        }

        SectionBox(title: "Scan data") {
            Toggle("Avoid signals from scans", isOn: $state.project.coord.useScan)
            HStack {
                Text("Threshold")
                Slider(value: $state.project.coord.thresholdDBm, in: -110...(-50), step: 1)
                Text("\(Int(state.project.coord.thresholdDBm)) dBm").font(.caption.monospacedDigit()).frame(width: 60)
            }
        }

        SectionBox(title: "Calculate") {
            HStack {
                Button { state.runCoordination() } label: { Label("Find frequencies", systemImage: "wand.and.stars") }
                    .disabled(state.coordinating)
                if state.coordinating { ProgressView().controlSize(.small) }
            }
            if !state.coordMessage.isEmpty { Text(state.coordMessage).font(.caption) }
            if !state.proposals.isEmpty {
                ForEach(state.proposals.keys.sorted(), id: \.self) { key in
                    if let hit = state.lookup(key), let c = hit.0.channel(hit.1), let f = state.proposals[key] {
                        HStack {
                            Text(state.label(hit.0, c)).lineLimit(1)
                            Spacer()
                            Text("\(fmtMHz(c.freqKHz)) → \(fmtMHz(f))").font(.caption.monospacedDigit())
                        }
                    }
                }
                HStack {
                    Button("Apply all to receivers") { state.applyAllProposals() }.buttonStyle(.borderedProminent)
                    Button("Discard") { state.proposals = [:] }
                }
                Text("Remember to re-sync transmitters (IR sync) after changing receiver frequencies.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }

        SectionBox(title: "Conflicts (\(state.conflicts.count))") {
            if state.conflicts.isEmpty {
                Label("All current frequencies are compatible", systemImage: "checkmark.seal.fill").foregroundColor(.green)
            } else {
                ForEach(state.conflicts.prefix(40)) { c in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(c.victim) — \(c.kind)").font(.caption.bold()).foregroundColor(.red)
                        Text("\(c.sources), \(c.offsetKHz) kHz away").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
