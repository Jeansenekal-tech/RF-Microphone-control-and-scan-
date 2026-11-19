import Foundation
import AppKit
import UserNotifications
import UniqueAVCore

struct HealthSettings: Codable, Equatable {
    var enabled = true
    var rfMinDBm = -90
    var battBarsWarn = 1
    var battMinutesWarn = 30
    var audioClipDBFS = -1
    var interferenceDBm: Double = -80
    var notify = true
    var sound = true
}

enum Severity: Int, Comparable {
    case info, warning, critical
    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

struct HealthAlert: Identifiable, Equatable {
    var id: String            // rule + channel key; stable while the condition lasts
    var channelKey: String?
    var severity: Severity
    var title: String
    var detail: String
    var since: Date
    var ended: Date?
}

/// Evaluates every channel once per second ("Health Check") and raises alerts.
final class HealthMonitor: ObservableObject {
    @Published private(set) var active: [HealthAlert] = []
    @Published private(set) var history: [HealthAlert] = []
    private var canNotify = false

    init() {
        // UNUserNotificationCenter only works from a bundled .app (not `swift run`).
        if Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
                DispatchQueue.main.async { self.canNotify = ok }
            }
        }
    }

    func activeAlerts(for key: String) -> [HealthAlert] { active.filter { $0.channelKey == key } }

    /// Replaces the set of current conditions; new ones notify, vanished ones go to history.
    func update(_ current: [HealthAlert], settings: HealthSettings, telemetry: TelemetryStore) {
        let now = Date()
        let oldIDs = Set(active.map(\.id))
        let newIDs = Set(current.map(\.id))
        var next: [HealthAlert] = []
        for var a in current {
            if let existing = active.first(where: { $0.id == a.id }) { a.since = existing.since }
            next.append(a)
        }
        let raised = next.filter { !oldIDs.contains($0.id) }
        for var gone in active where !newIDs.contains(gone.id) {
            gone.ended = now
            history.insert(gone, at: 0)
            telemetry.event(gone.channelKey ?? "", "Cleared: \(gone.title)")
        }
        if history.count > 500 { history.removeLast(history.count - 500) }
        next.sort { ($0.severity, $1.since) > ($1.severity, $0.since) }
        if next != active { active = next }
        for a in raised {
            telemetry.event(a.channelKey ?? "", a.title)
            if a.severity >= .warning { announce(a, settings) }
        }
    }

    private func announce(_ a: HealthAlert, _ s: HealthSettings) {
        if s.sound && a.severity == .critical { NSSound.beep() }
        guard s.notify, canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = a.title
        c.body = a.detail
        if a.severity == .critical { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id + "\(a.since.timeIntervalSince1970)",
                                                                     content: c, trigger: nil))
    }

    func clearHistory() { history = [] }
}
