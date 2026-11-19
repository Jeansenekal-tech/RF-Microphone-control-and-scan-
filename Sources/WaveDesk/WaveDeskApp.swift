import SwiftUI
import AppKit

enum AppInfo {
    /// The name shown to users. (Internally the project, bundle ID and data folder are still "WaveDesk".)
    static let name = "Unique AV RF Scan Co-ord"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) so a real window + Dock icon appear.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WaveDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 720)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    state.saveNow()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { state.updater.check(userInitiated: true) }
            }
            CommandMenu("Scan") {
                Button(state.analyzer.scanning ? "Stop scan" : "Start scan") {
                    if state.analyzer.scanning { state.analyzer.stopScan() } else { state.analyzer.startScan() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Connect analyzer") { state.analyzer.connect() }
                Button("Clear peak hold") { state.analyzer.clearPeak() }
            }
            CommandMenu("Coordination") {
                Button("Find frequencies") { state.runCoordination() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Apply all proposals") { state.applyAllProposals() }
                    .disabled(state.proposals.isEmpty)
            }
        }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case timeline = "Timeline"
    case health = "Health check"
    case groups = "Time of use"
    case library = "Scan library"
    case devices = "Devices"
    case inventory = "Inventory"
    case remote = "Remote & Companion"
    case project = "Project"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "waveform.path.ecg.rectangle"
        case .timeline: return "chart.xyaxis.line"
        case .health: return "heart.text.square"
        case .groups: return "calendar.day.timeline.left"
        case .library: return "books.vertical"
        case .devices: return "antenna.radiowaves.left.and.right"
        case .inventory: return "shippingbox"
        case .remote: return "qrcode"
        case .project: return "folder"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var screen: Screen? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                Section {
                    ForEach(Screen.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon)
                            .badge(s == .health ? state.health.active.count : 0)
                            .tag(s)
                    }
                } header: {
                    BrandHeader().padding(.bottom, 6)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch screen ?? .dashboard {
            case .dashboard: DashboardView()
            case .timeline: TelemetryTimelineView(telemetry: state.telemetry)
            case .health: HealthView(health: state.health)
            case .groups: GroupsView()
            case .library: LibraryView(library: state.library)
            case .devices: DevicesView()
            case .inventory: InventoryView(inventory: state.inventory)
            case .remote: RemoteView(remote: state.remote, updater: state.updater)
            case .project: ProjectView()
            }
        }
        .navigationTitle(state.project.name)
        .navigationSubtitle(state.project.venue.isEmpty ? state.region.name : "\(state.project.venue) · \(state.region.name)")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(state.projectNames, id: \.self) { n in Button(n) { state.openProject(n) } }
                    Divider()
                    Button("Manage projects…") { screen = .project }
                } label: {
                    Label("Project", systemImage: "folder")
                }
                UpdateToolbarButton(updater: state.updater)
                AnalyzerToolbarButton(analyzer: state.analyzer)
                Button { screen = .health } label: {
                    let n = state.health.active.count
                    let crit = state.health.active.contains { $0.severity == .critical }
                    Label("\(n)", systemImage: n == 0 ? "checkmark.seal" : "exclamationmark.triangle.fill")
                        .foregroundColor(n == 0 ? .green : crit ? .red : .orange)
                }
                .help("Health check")
            }
        }
    }
}

struct UpdateToolbarButton: View {
    @ObservedObject var updater: Updater
    var body: some View {
        if let r = updater.available {
            Button { updater.offer(r) } label: {
                Label("Update to \(r.version)", systemImage: "arrow.down.circle.fill").foregroundColor(.accentColor)
            }
            .help("\(AppInfo.name) \(r.version) is available")
        }
    }
}

struct AnalyzerToolbarButton: View {
    @ObservedObject var analyzer: AnalyzerController
    var body: some View {
        Button {
            if analyzer.scanning { analyzer.stopScan() }
            else if analyzer.connected { analyzer.startScan() }
            else { analyzer.connect() }
        } label: {
            Label(analyzer.scanning ? "Stop scan" : analyzer.connected ? "Scan" : "Connect analyzer",
                  systemImage: analyzer.scanning ? "stop.circle.fill" : analyzer.connected ? "play.circle" : "cable.connector")
        }
        .help(analyzer.status)
    }
}

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HSplitView {
            VSplitView {
                SpectrumView(analyzer: state.analyzer).frame(minHeight: 280, idealHeight: 380)
                ChannelGrid().frame(minHeight: 220)
            }
            .frame(minWidth: 640)
            InspectorPanel().frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
        }
    }
}

/// Logo + name at the top of the sidebar.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("UNIQUE AV").font(.system(size: 13, weight: .heavy)).foregroundColor(.primary)
                Text("RF SCAN CO-ORD").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }
}
