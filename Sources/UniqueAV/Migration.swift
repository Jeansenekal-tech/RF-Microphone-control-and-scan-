import Foundation

/// One-time move from the app's old internal name ("WaveDesk", bundle ID app.wavedesk.WaveDesk)
/// to "Unique AV RF Scan Co-ord" (com.uniqueav.rfscancoord): data folder, project files and settings.
enum Migration {
    private static let doneKey = "uniqueav.migratedFromWaveDesk"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        moveDataFolder()
        copySettings()
        defaults.set(true, forKey: doneKey)
    }

    /// ~/Library/Application Support/WaveDesk -> …/Unique AV RF Scan Co-ord, and *.wdproj -> *.uavproj
    private static func moveDataFolder() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent("WaveDesk", isDirectory: true)
        let new = base.appendingPathComponent(Storage.folderName, isDirectory: true)
        if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            do { try fm.moveItem(at: old, to: new) } catch { NSLog("UniqueAV: could not move old data folder: \(error)") }
        }
        let projects = new.appendingPathComponent("Projects", isDirectory: true)
        for f in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "wdproj" {
            let target = f.deletingPathExtension().appendingPathExtension(Storage.projectExtension)
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: f, to: target) }
        }
    }

    /// Settings saved under the old bundle ID (web server key/port, analyzer range, update prefs, last project).
    private static func copySettings() {
        guard let old = UserDefaults(suiteName: "app.wavedesk.WaveDesk") else { return }
        let new = UserDefaults.standard
        let renamed = ["wavedesk.lastProject": "uniqueav.lastProject"]
        let keys = ["remote.enabled", "remote.port", "remote.control", "remote.key",
                    "an.start", "an.stop", "an.step", "an.rbw", "update.auto", "update.lastCheck", "wavedesk.lastProject"]
        for k in keys {
            let target = renamed[k] ?? k
            if new.object(forKey: target) == nil, let v = old.object(forKey: k) { new.set(v, forKey: target) }
        }
    }
}
