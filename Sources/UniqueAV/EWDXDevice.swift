import Foundation

/// Sennheiser EW-DX EM 2 / EM 4 (and other SSCv2 devices) over HTTPS REST.
///
/// SSCv2 must be enabled on the receiver with a password (via Sennheiser Control Cockpit or
/// the WSM/SoundBase "third-party access" setting). Auth is HTTP Basic, user "api".
/// The receiver uses a self-signed certificate, which is accepted for this host only.
///
/// EXPERIMENTAL: written against Sennheiser's public SSCv2 docs, not yet tested on hardware.
/// All endpoint paths are in `Path` so they're easy to adjust.
final class EWDXDevice: Device {
    enum Path {
        static let identity = "/api/device/identity"
        static func name(_ i: Int) -> String { "/api/rx\(i)/name" }
        static func frequency(_ i: Int) -> String { "/api/rx\(i)/frequency" }   // kHz
        static func mute(_ i: Int) -> String { "/api/rx\(i)/mute" }
        static func rssi(_ i: Int) -> String { "/api/rx\(i)/rssi" }
    }

    private let sscPassword: String
    private var session: URLSession?
    private var timer: Timer?
    private var failures = 0
    private var maxRx = 4
    private let trust = TrustDelegate()

    init(config: DeviceConfig) {
        sscPassword = config.password ?? ""
        super.init(config: config, channelCount: 1)
    }

    override func start() {
        super.start()
        trust.host = host
        session = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: .main)
        status = "Contacting \(host)…"
        poll()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func stop() {
        super.stop()
        timer?.invalidate()
        timer = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func request(_ path: String, method: String = "GET", body: Any? = nil,
                         done: @escaping (Int, Any?) -> Void) {
        guard let session, let url = URL(string: "https://\(host)\(path)") else { return }
        var r = URLRequest(url: url, timeoutInterval: 4)
        r.httpMethod = method
        let token = Data("api:\(sscPassword)".utf8).base64EncodedString()
        r.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        }
        session.dataTask(with: r) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? (err == nil ? 0 : -1)
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            done(code, json)
        }.resume()
    }

    private func poll() {
        guard !stopped else { return }
        request(Path.identity) { [weak self] code, json in
            guard let self else { return }
            switch code {
            case 200..<300:
                self.failures = 0
                if !self.online { self.online = true; self.status = "Connected (SSCv2)" }
                if let d = json as? [String: Any], let p = d["product"] as? String { self.model = p }
            case 401, 403:
                self.online = false
                self.status = "Wrong SSCv2 password (user “api”)"
            default:
                self.failures += 1
                if self.failures >= 2 { self.online = false; self.status = "No reply from \(self.host)" }
            }
        }
        for i in 1...maxRx {
            request(Path.name(i)) { [weak self] code, json in
                guard let self else { return }
                if code == 404 { if i > 1 { self.maxRx = min(self.maxRx, i - 1) }; return }
                if let n = json as? String { self.update(i) { $0.name = n } }
            }
            request(Path.frequency(i)) { [weak self] _, json in
                if let f = json as? NSNumber, f.intValue > 0 { self?.update(i) { $0.freqKHz = f.intValue } }
            }
            request(Path.mute(i)) { [weak self] _, json in
                if let m = json as? Bool { self?.update(i) { $0.mute = m } }
            }
            request(Path.rssi(i)) { [weak self] _, json in
                if let r = json as? NSNumber { self?.update(i) { $0.rfA = r.intValue } }
            }
        }
    }

    override func set(_ value: SetValue, channel: Int) {
        let refresh: (Int, Any?) -> Void = { [weak self] code, _ in
            if !(200..<300).contains(code) { self?.status = "Set failed (HTTP \(code))" }
            self?.poll()
        }
        switch value {
        case .name(let n): request(Path.name(channel), method: "PUT", body: String(n.prefix(16)), done: refresh)
        case .frequency(let f): request(Path.frequency(channel), method: "PUT", body: f, done: refresh)
        case .mute(let m): request(Path.mute(channel), method: "PUT", body: m, done: refresh)
        case .gain: break
        }
    }
}

/// Accepts the receiver's self-signed certificate, but only for the configured host.
final class TrustDelegate: NSObject, URLSessionDelegate {
    var host = ""
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host, let t = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: t))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
