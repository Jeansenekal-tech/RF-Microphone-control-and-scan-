import Foundation
import AppKit
import CryptoKit
import IOKit
import Security
import WaveDeskCore

/// Licensing via Keygen (keygen.sh):
/// * one Mac per licence (machine activation bound to a hardware fingerprint)
/// * 60-day trial issued by the trial worker (licensing/trial-worker), one per Mac
/// * a signed machine file lets the app run offline for up to 30 days between check-ins
/// * a licence can be moved to a new Mac from the app ("Move licence to this Mac"),
///   which also covers lost or broken computers; the old Mac stops at its next check-in
final class LicenseManager: ObservableObject {
    enum Phase: Equatable {
        case developer                      // no licensing configured (dev / CI builds)
        case checking
        case licensed
        case locked(Reason)
    }
    enum Reason: Equatable {
        case none, needsCheckIn, expired(trial: Bool), suspended, invalidKey, clock, offline, wrongMachine
        case activeElsewhere(machine: String?)
        case error(String)
    }

    static let offlineDays = 30
    static var enabled: Bool { !BuildConfig.keygenAccountID.isEmpty && !BuildConfig.keygenPublicKey.isEmpty }

    @Published private(set) var phase: Phase = .checking
    /// Becomes true once the app is unlocked in this session. The app is only gated at launch, so a
    /// licence problem found while running never stops a show – it locks on the next launch.
    @Published private(set) var sessionUnlocked = false
    @Published private(set) var file: MachineFile?
    @Published private(set) var busy = false
    @Published var message = ""

    let fingerprint: String
    let machineName: String
    private var timer: Timer?

    init() {
        fingerprint = Self.makeFingerprint()
        machineName = Host.current().localizedName ?? "Mac"
        guard Self.enabled else {
            phase = .developer
            sessionUnlocked = true
            return
        }
        // Decide offline first (fast start, works without internet), then refresh online.
        apply(LicensePolicy.evaluate(loadFile(), fingerprint: fingerprint, now: Date(), lastSeen: Keychain.date("lastSeen")))
        if storedKey != nil { refresh() } else if phase != .licensed { phase = .locked(.none) }
        let t = Timer(timeInterval: 12 * 3600, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Status helpers for the UI

    var isTrial: Bool { file?.isTrial ?? false }
    var daysLeft: Int? { file?.licenseExpiry.map { LicensePolicy.daysLeft(until: $0, now: Date()) } }
    var offlineUntil: Date? { file?.expiry }
    var storedKey: String? { Keychain.string("licenceKey") }
    var maskedKey: String {
        guard let k = storedKey, k.count > 8 else { return storedKey ?? "—" }
        return String(k.prefix(4)) + "…" + String(k.suffix(4))
    }

    // MARK: Fingerprint

    /// SHA-256 of the Mac's hardware UUID (stable across reinstalls, never sent in clear).
    static func makeFingerprint() -> String {
        var uuid = "unknown"
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            if let v = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String { uuid = v }
            IOObjectRelease(service)
        }
        let digest = SHA256.hash(data: Data("uniqueav-rfscan|\(uuid)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Actions

    func startTrial() {
        guard let url = URL(string: BuildConfig.trialURL), !BuildConfig.trialURL.isEmpty else {
            message = "Trials aren't set up for this build."; return
        }
        busy = true
        message = "Starting your 60-day trial…"
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["fingerprint": fingerprint, "name": machineName])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                self.busy = false
                if let key = json?["key"] as? String {
                    self.activate(key: key)
                } else {
                    self.message = (json?["error"] as? String) ?? (err == nil ? "Could not start the trial." : "No internet connection.")
                }
            }
        }.resume()
    }

    func activate(key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        Keychain.set(k, "licenceKey")
        refresh()
    }

    /// Validates online and, if needed, activates this Mac and downloads a fresh machine file.
    func refresh() {
        guard Self.enabled, let key = storedKey, !busy else { return }
        busy = true
        if !sessionUnlocked { phase = .checking }
        validate(key) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.finish(offlineError: e)
            case .success(let v):
                switch v.code {
                case "VALID":
                    self.checkOut(key, machineID: nil)
                case "NO_MACHINE", "NO_MACHINES":
                    self.activateMachine(key, licenseID: v.licenseID)
                case "FINGERPRINT_SCOPE_MISMATCH", "TOO_MANY_MACHINES", "MACHINE_SCOPE_MISMATCH":
                    self.lock(.activeElsewhere(machine: nil))
                    self.lookupOtherMachineName(key, licenseID: v.licenseID)
                case "EXPIRED":
                    self.lock(.expired(trial: self.file?.isTrial ?? false))
                case "SUSPENDED", "BANNED":
                    self.lock(.suspended)
                case "NOT_FOUND":
                    Keychain.delete("licenceKey")
                    self.lock(.invalidKey)
                default:
                    self.lock(.error(v.detail ?? v.code))
                }
            }
        }
    }

    /// Moves the licence to this Mac: removes the other activation (lost/broken/old Mac) and activates here.
    func moveHere() {
        guard let key = storedKey else { return }
        busy = true
        message = "Moving licence to this Mac…"
        validate(key) { [weak self] r in
            guard let self, case .success(let v) = r, let lid = v.licenseID else {
                self?.busy = false; self?.message = "Could not reach the licence server."; return
            }
            self.api("GET", "/licenses/\(lid)/machines", key: key) { code, json in
                let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                guard (200..<300).contains(code) else { self.busy = false; self.message = "Could not list activations (\(code))."; return }
                let group = DispatchGroup()
                final class Flag { var failed = false }
                let flag = Flag()
                for id in ids {
                    group.enter()
                    self.api("DELETE", "/machines/\(id)", key: key) { c, _ in
                        if !(200..<300).contains(c) { flag.failed = true }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    self.busy = false
                    if flag.failed { self.message = "Couldn't release the other Mac – contact support to reset it."; return }
                    self.message = ""
                    self.refresh()
                }
            }
        }
    }

    /// Frees the licence so it can be used on another Mac.
    func deactivate(completion: @escaping (Bool) -> Void) {
        guard let key = storedKey else { completion(false); return }
        busy = true
        findMachine(key) { [weak self] mid in
            guard let self else { return }
            guard let mid else {
                self.busy = false; self.message = "This Mac isn't activated, or the licence server can't be reached."
                completion(false); return
            }
            self.api("DELETE", "/machines/\(mid)", key: key) { code, _ in
                self.busy = false
                let ok = (200..<300).contains(code)
                if ok {
                    self.clearLocal()
                    self.message = "This Mac has been deactivated. The licence can now be used on another Mac."
                } else {
                    self.message = "Deactivation failed (\(code))."
                }
                completion(ok)
            }
        }
    }

    func clearLocal() {
        Keychain.delete("licenceKey")
        try? FileManager.default.removeItem(at: Self.fileURL)
        file = nil
        phase = .locked(.none)
    }

    // MARK: Keygen API

    private struct Validation { var code: String; var detail: String?; var licenseID: String? }

    private func validate(_ key: String, done: @escaping (Result<Validation, Error>) -> Void) {
        let body: [String: Any] = ["meta": ["key": key, "scope": ["fingerprint": fingerprint]]]
        apiRaw("POST", "/licenses/actions/validate-key", key: nil, body: body) { _, json, err in
            if let err { done(.failure(err)); return }
            guard let meta = json?["meta"] as? [String: Any] else {
                done(.failure(URLError(.badServerResponse))); return
            }
            let data = json?["data"] as? [String: Any]
            done(.success(Validation(code: meta["code"] as? String ?? "UNKNOWN", detail: meta["detail"] as? String,
                                     licenseID: data?["id"] as? String)))
        }
    }

    /// This Mac's machine id under the licence (nil if not activated here).
    private func findMachine(_ key: String, done: @escaping (String?) -> Void) {
        api("GET", "/machines?fingerprint=\(fingerprint)", key: key) { _, json in
            done((json?["data"] as? [[String: Any]])?.first?["id"] as? String)
        }
    }

    private func activateMachine(_ key: String, licenseID: String?) {
        guard let lid = licenseID else { finish(error: "Licence not found"); return }
        let body: [String: Any] = ["data": [
            "type": "machines",
            "attributes": ["fingerprint": fingerprint, "platform": "macOS", "name": machineName],
            "relationships": ["license": ["data": ["type": "licenses", "id": lid]]],
        ]]
        api("POST", "/machines", key: key, body: body) { [weak self] code, json in
            guard let self else { return }
            if (200..<300).contains(code), let mid = (json?["data"] as? [String: Any])?["id"] as? String {
                self.checkOut(key, machineID: mid)
            } else {
                let errs = json?["errors"] as? [[String: Any]]
                let codeStr = errs?.first?["code"] as? String ?? ""
                if codeStr.contains("MACHINE_LIMIT") || codeStr.contains("TOO_MANY") || codeStr.contains("FINGERPRINT_TAKEN") {
                    self.lock(.activeElsewhere(machine: nil))
                } else {
                    self.finish(error: errs?.first?["detail"] as? String ?? "Activation failed (\(code))")
                }
            }
        }
    }

    /// Looks up this Mac's machine id by fingerprint, then checks out a 30-day machine file.
    private func checkOut(_ key: String, machineID: String?) {
        let go: (String) -> Void = { [weak self] mid in
            guard let self else { return }
            let ttl = Self.offlineDays * 86400
            self.api("POST", "/machines/\(mid)/actions/check-out?ttl=\(ttl)&include=license", key: key) { code, json in
                guard (200..<300).contains(code),
                      let cert = ((json?["data"] as? [String: Any])?["attributes"] as? [String: Any])?["certificate"] as? String
                else { self.finish(error: "Could not download the licence file (\(code))"); return }
                do {
                    let f = try LicenseFiles.verify(certificate: cert, publicKeyHex: BuildConfig.keygenPublicKey)
                    try? cert.write(to: Self.fileURL, atomically: true, encoding: .utf8)
                    self.busy = false
                    self.message = ""
                    self.apply(LicensePolicy.evaluate(f, fingerprint: self.fingerprint, now: Date(),
                                                      lastSeen: Keychain.date("lastSeen")))
                } catch {
                    self.finish(error: "The licence file failed verification.")
                }
            }
        }
        if let mid = machineID { go(mid); return }
        findMachine(key) { [weak self] mid in
            if let mid { go(mid) } else { self?.activateMachineFromKey(key) }
        }
    }

    private func activateMachineFromKey(_ key: String) {
        validate(key) { [weak self] r in
            if case .success(let v) = r { self?.activateMachine(key, licenseID: v.licenseID) }
            else { self?.finish(error: "Licence server unavailable") }
        }
    }

    private func lookupOtherMachineName(_ key: String, licenseID: String?) {
        guard let lid = licenseID else { return }
        api("GET", "/licenses/\(lid)/machines", key: key) { [weak self] _, json in
            let name = ((json?["data"] as? [[String: Any]])?.first?["attributes"] as? [String: Any])?["name"] as? String
            self?.lock(.activeElsewhere(machine: name))
        }
    }

    /// JSON:API request to Keygen. `key` = licence key auth ("Authorization: License …").
    private func api(_ method: String, _ path: String, key: String?, body: [String: Any]? = nil,
                     done: @escaping (Int, [String: Any]?) -> Void) {
        apiRaw(method, path, key: key, body: body) { code, json, _ in done(code, json) }
    }

    private func apiRaw(_ method: String, _ path: String, key: String?, body: [String: Any]? = nil,
                        done: @escaping (Int, [String: Any]?, Error?) -> Void) {
        guard let url = URL(string: "https://api.keygen.sh/v1/accounts/\(BuildConfig.keygenAccountID)\(path)") else {
            done(0, nil, URLError(.badURL)); return
        }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        r.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        if let key { r.setValue("License \(key)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        URLSession.shared.dataTask(with: r) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(code, json, err) }
        }.resume()
    }

    // MARK: State

    private static var fileURL: URL { Storage.root.appendingPathComponent("licence.machine") }

    private func loadFile() -> MachineFile? {
        guard let cert = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return nil }
        return try? LicenseFiles.verify(certificate: cert, publicKeyHex: BuildConfig.keygenPublicKey)
    }

    private func apply(_ v: LicenseVerdict) {
        switch v {
        case .valid(let f):
            file = f
            phase = .licensed
            sessionUnlocked = true
            let now = Date()
            if (Keychain.date("lastSeen") ?? .distantPast) < now { Keychain.setDate(now, "lastSeen") }
        case .noLicence: phase = .locked(.none)
        case .wrongMachine: phase = .locked(.wrongMachine)
        case .checkInRequired: phase = .locked(.needsCheckIn)
        case .expired(let trial): phase = .locked(.expired(trial: trial))
        case .suspended: phase = .locked(.suspended)
        case .clockTampered: phase = .locked(.clock)
        }
    }

    private func lock(_ r: Reason) {
        busy = false
        phase = .locked(r)
    }

    private func finish(error: String) {
        busy = false
        message = error
        if phase == .checking { phase = .locked(.error(error)) }
    }

    /// Network failure: keep whatever the offline machine file allows.
    private func finish(offlineError: Error) {
        busy = false
        let v = LicensePolicy.evaluate(file ?? loadFile(), fingerprint: fingerprint, now: Date(), lastSeen: Keychain.date("lastSeen"))
        if v.unlocks { apply(v) } else if phase == .checking { phase = .locked(.offline) }
    }
}

/// Small Keychain wrapper (generic passwords for this app).
enum Keychain {
    private static let service = "app.wavedesk.licence"

    static func set(_ value: String, _ account: String) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func string(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    static func date(_ account: String) -> Date? { string(account).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
    static func setDate(_ d: Date, _ account: String) { set(String(d.timeIntervalSince1970), account) }
}
