import Foundation

/// 4-channel simulated receiver so the app can be explored without hardware.
final class DemoDevice: Device {
    private var timer: Timer?
    private var t: Double = 0

    init(config: DeviceConfig) {
        super.init(config: config, channelCount: 4)
        let base = 470_000 + Int.random(in: 0..<150) * 1000
        for i in 1...4 {
            update(i) { c in
                c.name = "DEMO \(i)"
                c.freqKHz = base + i * 1625
                c.gain = 12; c.mute = false; c.battBars = 5 - (i % 3); c.battMin = 300 + i * 40
                c.txType = "DEMO"
            }
        }
    }

    override func start() {
        super.start()
        model = "DEMO-4CH"
        online = true
        status = "Simulated"
        let tm = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    override func stop() {
        super.stop()
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        t += 0.2
        for i in 1...channels.count {
            let d = Double(i)
            update(i) { c in
                let a = Int(-55 + 8 * sin(t / 3 + d) + Double.random(in: -3...3))
                let b = Int(-60 + 8 * cos(t / 4 + d) + Double.random(in: -3...3))
                c.rfA = a; c.rfB = b
                c.antenna = a > b ? "A" : "B"
                c.audio = c.mute == true ? -50 : Int(-30 + 22 * abs(sin(t * (1 + d / 3))) + Double.random(in: -4...4))
            }
        }
    }

    override func set(_ value: SetValue, channel: Int) {
        update(channel) { c in
            switch value {
            case .name(let n): c.name = String(n.prefix(16))
            case .frequency(let f): c.freqKHz = f
            case .gain(let g): c.gain = g
            case .mute(let m): c.mute = m
            }
        }
    }
}
