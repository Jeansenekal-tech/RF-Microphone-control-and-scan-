import Foundation
import Network

/// Shared UDP plumbing: one "connected" UDP flow to the receiver, periodic polling,
/// online/offline based on whether replies arrive.
class UDPDevice: Device {
    var udpPort: UInt16 { 0 }
    var pollInterval: TimeInterval { 2 }
    private var conn: NWConnection?
    private var timer: Timer?
    private var lastRx = Date.distantPast

    override func start() {
        super.start()
        open()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    override func stop() {
        super.stop()
        timer?.invalidate()
        timer = nil
        conn?.cancel()
        conn = nil
    }

    private func open() {
        guard let port = NWEndpoint.Port(rawValue: udpPort) else { return }
        status = "Contacting \(host)…"
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self, self.conn === c else { return }
            if case .failed(let e) = st {
                self.online = false
                self.status = "Error: \(e.localizedDescription)"
                self.conn = nil   // tick() reopens
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self, self.conn === c, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.lastRx = Date()
                if !self.online { self.online = true; self.status = "Connected" }
                self.handle(data)
            }
            if err == nil { self.receive(on: c) }
        }
    }

    private func tick() {
        if conn == nil { open() }
        poll()
        if Date().timeIntervalSince(lastRx) > 3 * pollInterval + 1 {
            online = false
            status = "No reply from \(host)"
        }
    }

    func sendData(_ d: Data) {
        conn?.send(content: d, completion: .contentProcessed { _ in })
    }

    // Subclass hooks
    func poll() {}
    func handle(_ data: Data) {}
}

/// Sennheiser evolution wireless G3 / G4, 2000 and 9000 series: ASCII over UDP 53212.
/// e.g. "Name\r" -> "Name VOX1", "Frequency 518200\r" (kHz), "Push 60 100 0\r" subscribes to meters.
final class SennheiserG4Device: UDPDevice {
    override var udpPort: UInt16 { 53212 }
    private var n = 0

    private func cmd(_ s: String) { sendData(Data((s + "\r").utf8)) }

    override func poll() {
        if n % 10 == 0 { cmd("Push 60 100 0") }
        if n % 3 == 0 { ["Name", "Frequency", "Mute", "AfOut", "Bat", "Config"].forEach(cmd) }
        n += 1
    }

    override func handle(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: " ").map(String.init)
            guard let key = parts.first?.lowercased() else { continue }
            let args = Array(parts.dropFirst())
            let a0 = args.first ?? ""
            let num = Double(a0).map { Int($0) }
            if key == "config" { model = args.joined(separator: " "); continue }
            update(1) { c in
                switch key {
                case "name": c.name = args.joined(separator: " ")
                case "frequency": if let f = num, f > 0 { c.freqKHz = f }
                case "mute": c.mute = !(a0 == "0" || a0.isEmpty)
                case "afout": c.gain = num
                // RF/AF are reported as 0-100 % of scale; mapped approximately to dBm / dBFS.
                case "rf1", "rf": c.rfA = num.map { -100 + $0 * 8 / 10 }
                case "rf2": c.rfB = num.map { -100 + $0 * 8 / 10 }
                case "af": c.audio = num.map { -50 + $0 / 2 }
                case "bat", "battery": c.battBars = num.map { min(5, Int((Double($0) * 5 / 3).rounded())) }
                default: break
                }
                if let a = c.rfA, let b = c.rfB { c.antenna = a >= b ? "A" : "B" }
            }
        }
    }

    override func set(_ value: SetValue, channel: Int) {
        switch value {
        case .name(let s):
            let clean = String(s.uppercased().filter { $0.isASCII && !$0.isNewline }.prefix(8))
            cmd("Name \(clean)"); cmd("Name")
        case .frequency(let f): cmd("Frequency \(f)"); cmd("Frequency")
        case .mute(let m): cmd("Mute \(m ? 1 : 0)"); cmd("Mute")
        case .gain(let g): cmd("AfOut \(g)"); cmd("AfOut")
        }
    }
}

/// Sennheiser Sound Control Protocol v1: JSON over UDP 45 (Digital 6000 EM 6000).
/// Experimental - property names differ between products and firmware.
final class SennheiserSSCDevice: UDPDevice {
    override var udpPort: UInt16 { 45 }
    override var pollInterval: TimeInterval { 1 }

    init(config: DeviceConfig) { super.init(config: config, channelCount: 2) }

    private func send(_ obj: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: obj) { sendData(d) }
    }

    override func poll() {
        var q: [String: Any] = ["device": ["identity": ["product": NSNull()]]]
        var mm: [String: Any] = [:]
        for c in channels {
            q["rx\(c.idx)"] = ["name": NSNull(), "frequency": NSNull(), "mute": NSNull()]
            mm["rx\(c.idx)"] = NSNull()
        }
        send(q)
        send(["mm": mm])
    }

    override func handle(_ data: Data) {
        guard let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let dev = msg["device"] as? [String: Any], let id = dev["identity"] as? [String: Any],
           let p = id["product"] as? String { model = p }
        for (key, value) in msg {
            guard key.hasPrefix("rx"), let i = Int(key.dropFirst(2)), let sub = value as? [String: Any] else { continue }
            update(i) { c in
                if let n = sub["name"] as? String { c.name = n }
                if let f = sub["frequency"] as? NSNumber, f.intValue > 0 { c.freqKHz = f.intValue }
                if let m = sub["mute"] as? Bool { c.mute = m }
            }
        }
        if let mm = msg["mm"] as? [String: Any] {
            for (key, value) in mm {
                guard key.hasPrefix("rx"), let i = Int(key.dropFirst(2)), let sub = value as? [String: Any] else { continue }
                update(i) { c in
                    if let r = (sub["rsqi"] ?? sub["rssi"] ?? sub["rf"]) as? NSNumber {
                        let v = r.intValue
                        c.rfA = v < 0 ? v : -100 + v * 8 / 10
                    }
                    if let a = sub["af"] as? NSNumber { c.audio = a.intValue }
                }
            }
        }
    }

    override func set(_ value: SetValue, channel: Int) {
        let rx = "rx\(channel)"
        switch value {
        case .name(let s): send([rx: ["name": String(s.prefix(16))]])
        case .frequency(let f): send([rx: ["frequency": f]])
        case .mute(let m): send([rx: ["mute": m]])
        case .gain: break
        }
    }
}
