import Foundation
import Network
import WaveDeskCore

/// Shure receiver over TCP 2202. Reconnects automatically.
final class ShureDevice: Device {
    private var conn: NWConnection?
    private var buffer = ""
    private var pollTimer: Timer?
    private var retry: DispatchWorkItem?
    private var tick = 0

    override func start() {
        super.start()
        connect()
    }

    override func stop() {
        super.stop()
        teardown()
        retry?.cancel()
    }

    private func connect() {
        guard !stopped, let port = NWEndpoint.Port(rawValue: ShureProtocol.port) else { return }
        status = "Connecting to \(host)…"
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self, self.conn === c else { return }
            switch st {
            case .ready:
                self.online = true
                self.status = "Connected"
                self.send(ShureProtocol.getAll())
                self.send(ShureProtocol.frame("GET MODEL"))
                self.receive(on: c)
                self.startPolling()
            case .waiting(let e):
                self.online = false
                self.status = "Waiting: \(e.localizedDescription)"
            case .failed(let e):
                self.fail(e.localizedDescription)
            default:
                break
            }
        }
        c.start(queue: .main)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty {
                self.buffer += String(decoding: data, as: UTF8.self)
                for f in ShureProtocol.extractFrames(&self.buffer) { self.handle(f) }
            }
            if done || err != nil {
                self.fail(err?.localizedDescription ?? "Connection closed")
            } else {
                self.receive(on: c)
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        tick = 0
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            // (Re)arm metering every 10 s for each known channel and refresh everything.
            if self.tick % 5 == 0 {
                for c in self.channels { self.send(ShureProtocol.meterRate(c.idx, ms: 200)) }
                if self.tick > 0 { self.send(ShureProtocol.getAll()) }
            }
            self.tick += 1
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        for c in channels { send(ShureProtocol.meterRate(c.idx, ms: 200)) }
    }

    private func fail(_ msg: String) {
        online = false
        status = "Offline: \(msg)"
        teardown()
        guard !stopped else { return }
        let w = DispatchWorkItem { [weak self] in self?.connect() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        conn = nil
        buffer = ""
    }

    private func send(_ s: String) {
        conn?.send(content: s.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func handle(_ body: String) {
        guard let msg = ShureProtocol.parse(body) else { return }
        applyShure(msg)
    }

    override func set(_ value: SetValue, channel: Int) {
        switch value {
        case .name(let n): send(ShureProtocol.setName(channel, n))
        case .frequency(let f): send(ShureProtocol.setFrequency(channel, kHz: f))
        case .gain(let g): send(ShureProtocol.setGain(channel, dB: g))
        case .mute(let m): send(ShureProtocol.setMute(channel, m))
        }
        send(ShureProtocol.getAll(channel))
    }
}

extension Device {
    /// Applies a parsed Shure REP/REPORT/SAMPLE message (shared by ULX-D-family and UHF-R drivers).
    /// - Parameter gainOffset: raw AUDIO_GAIN value that equals 0 dB (18 on ULX-D/QLX-D/Axient).
    func applyShure(_ msg: ShureProtocol.Message, gainOffset: Int = 18) {
        switch msg {
        case .rep(nil, let key, let values):
            let v = values.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if key == "MODEL" { model = v }
            if key == "DEVICE_ID", nickname.isEmpty { nickname = v }
        case .rep(.some(let ch), let key, let values):
            guard ch >= 1 else { return }
            let v = values.first?.trimmingCharacters(in: .whitespaces) ?? ""
            update(ch) { c in
                switch key {
                case "CHAN_NAME": c.name = v
                case "FREQUENCY": if let f = Int(v), f > 0 { c.freqKHz = f }
                case "AUDIO_GAIN": if let g = Int(v) { c.gain = g - gainOffset }
                case "BATT_BARS", "TX_BAT": if let b = Int(v) { c.battBars = b <= 5 ? b : nil }
                case "BATT_RUN_TIME": if let m = Int(v) { c.battMin = m < 65000 ? m : nil }
                case "AUDIO_MUTE", "RX_MUTE": c.mute = v.uppercased() == "ON"
                case "TX_TYPE": c.txType = ["UNKNOWN", "UNKN"].contains(v.uppercased()) ? "" : v
                default: break
                }
            }
        case let .sample(ch, values):
            guard ch >= 1 && ch <= 8 else { return }
            let s = ShureProtocol.decodeSample(values)
            update(ch) { c in
                c.antenna = s.antenna
                let a = s.antenna.contains("A") || s.antenna.isEmpty
                c.rfA = a ? s.rfDBm : nil
                c.rfB = s.antenna.contains("B") ? s.rfDBm : nil
                c.audio = s.audioDBFS
            }
        }
    }
}
