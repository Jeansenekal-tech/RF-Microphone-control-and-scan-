import Foundation
import AppKit

/// Checks GitHub Releases for a newer WaveDesk, downloads `WaveDesk.zip`, swaps the app bundle
/// and relaunches. Releases are produced by .github/workflows/release.yml when a `v*` tag is pushed.
final class Updater: ObservableObject {
    static let repo = "Jeansenekal-tech/rf-microphone-control-and-scan-"
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }

    struct Release: Decodable {
        struct Asset: Decodable { var name: String; var browser_download_url: URL; var size: Int }
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: URL
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var zip: Asset? { assets.first { $0.name.hasSuffix(".zip") && $0.name.lowercased().contains("wavedesk") } }
    }

    @Published var autoCheck: Bool { didSet { UserDefaults.standard.set(autoCheck, forKey: "update.auto") } }
    @Published private(set) var available: Release?
    @Published private(set) var status = ""
    @Published private(set) var busy = false

    /// True when running as a real .app (updates can't replace a `swift run` binary).
    var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true
    }

    func checkOnLaunch() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: "update.lastCheck")
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.check(userInitiated: false) }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).prefix(4).map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        status = "Checking for updates…"
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WaveDesk-Updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                self.busy = false
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "update.lastCheck")
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code == 200, let data,
                      let r = try? JSONDecoder().decode(Release.self, from: data) else {
                    self.status = code == 404 ? "No releases published yet" : "Could not check for updates"
                    if userInitiated { Panels.alert("Software update", self.status) }
                    return
                }
                if !r.draft && !r.prerelease && Self.isNewer(r.version, than: Self.currentVersion) {
                    self.available = r
                    self.status = "WaveDesk \(r.version) is available"
                    if userInitiated { self.offer(r) }
                } else {
                    self.available = nil
                    self.status = "You're up to date (\(Self.currentVersion))"
                    if userInitiated { Panels.alert("Software update", self.status) }
                }
            }
        }.resume()
    }

    func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = "WaveDesk \(r.version) is available"
        a.informativeText = "You have \(Self.currentVersion).\n\n" + String((r.body ?? "").prefix(1200))
        a.addButton(withTitle: canInstall && r.zip != nil ? "Install and Relaunch" : "Open Download Page")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if canInstall, r.zip != nil { install(r) } else { NSWorkspace.shared.open(r.html_url) }
    }

    func install(_ r: Release) {
        guard let asset = r.zip, canInstall, !busy else { return }
        busy = true
        status = "Downloading \(asset.name)…"
        URLSession.shared.downloadTask(with: asset.browser_download_url) { tmp, _, err in
            // Move the download before this callback returns (the temp file is deleted afterwards).
            var zipURL: URL?
            if let tmp {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("WaveDesk-update-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil { zipURL = dest }
            }
            DispatchQueue.main.async {
                guard err == nil, let zipURL else { self.fail("Download failed", r); return }
                self.unpackAndSwap(zipURL, r)
            }
        }.resume()
    }

    private func unpackAndSwap(_ zip: URL, _ r: Release) {
        status = "Installing…"
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("WaveDesk-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, work.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0,
                  let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                fail("The downloaded update isn't a valid WaveDesk app", r); return
            }
            // Downloads made by the app aren't quarantined, but clear the flag just in case.
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-dr", "com.apple.quarantine", newApp.path]
            try? x.run(); x.waitUntilExit()

            let current = Bundle.main.bundleURL
            var trashed: NSURL?
            try fm.trashItem(at: current, resultingItemURL: &trashed)
            do {
                try fm.moveItem(at: newApp, to: current)
            } catch {
                if let t = trashed as URL? { try? fm.moveItem(at: t, to: current) }   // put the old app back
                throw error
            }
            relaunch(current)
        } catch {
            fail("Could not replace the app: \(error.localizedDescription)", r)
        }
    }

    private func relaunch(_ app: URL) {
        status = "Restarting…"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func fail(_ msg: String, _ r: Release) {
        busy = false
        status = msg
        let a = NSAlert()
        a.messageText = "Update failed"
        a.informativeText = "\(msg)\n\nYou can download the new version manually."
        a.addButton(withTitle: "Open Download Page")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.html_url) }
    }
}
