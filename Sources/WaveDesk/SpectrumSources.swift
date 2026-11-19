import Foundation
import WaveDeskCore

/// Anything that can sweep a frequency range. Called from a background queue.
/// To support another live scanner (e.g. a Shure/Sennheiser unit once its protocol is known),
/// implement this protocol and add it to `SpectrumSourceKind`.
protocol SpectrumSource: AnyObject {
    var name: String { get }
    /// Max points the device returns per sweep.
    var maxPoints: Int { get }
    func prepare(startHz: Double, stopHz: Double, rbwKHz: Int) throws
    func sweep(startHz: Double, stopHz: Double, points: Int) throws -> [(hz: Double, dBm: Double)]
    func close()
}

enum SpectrumSourceKind: String, CaseIterable, Identifiable {
    case tinySA, simulated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tinySA: return "tinySA / tinySA Ultra (USB)"
        case .simulated: return "Simulated analyzer (demo)"
        }
    }
    var needsPort: Bool { self == .tinySA }
}

/// tinySA and tinySA Ultra over USB (shell prompt "ch> ").
final class TinySASource: SpectrumSource {
    private let port: SerialPort
    private(set) var name = "tinySA"
    let maxPoints = TinySAProtocol.maxPoints

    init(path: String) throws {
        port = try SerialPort(path: path)
        _ = try? port.read(timeout: 0.2)          // drain banner
        _ = try? command("", timeout: 1)            // sync to prompt
        if let v = try? command("version", timeout: 2) {
            name = v.split(whereSeparator: \.isNewline).first.map(String.init) ?? name
        }
    }

    func command(_ c: String, timeout: TimeInterval) throws -> String {
        try port.write(c + "\r")
        var buf = Data()
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let chunk = try port.read(timeout: 0.2)
            buf.append(chunk)
            if buf.count >= 4, String(decoding: buf.suffix(4), as: UTF8.self) == TinySAProtocol.prompt {
                return TinySAProtocol.stripResponse(String(decoding: buf, as: UTF8.self), command: c)
            }
        }
        throw SerialError.timeout(c)
    }

    func prepare(startHz: Double, stopHz: Double, rbwKHz: Int) throws {
        if stopHz <= 800e6 { _ = try? command("mode low input", timeout: 2) }
        _ = try command(rbwKHz > 0 ? "rbw \(rbwKHz)" : "rbw auto", timeout: 2)
    }

    func sweep(startHz: Double, stopHz: Double, points: Int) throws -> [(hz: Double, dBm: Double)] {
        let seg = TinySAProtocol.Segment(startHz: startHz, stopHz: stopHz, points: points)
        let out = try command(TinySAProtocol.scanCommand(seg), timeout: 90)
        return TinySAProtocol.parseScan(out)
    }

    func close() { port.close() }
}

/// Synthetic spectrum: noise floor, a few DTT multiplexes and carriers at the demo mics.
final class SimulatedSource: SpectrumSource {
    let name = "Simulated tinySA Ultra"
    let maxPoints = 450
    private let lock = NSLock()
    private var carriersKHz: [Int] = []

    func setCarriers(_ c: [Int]) { lock.lock(); carriersKHz = c; lock.unlock() }

    func prepare(startHz: Double, stopHz: Double, rbwKHz: Int) throws {}

    func sweep(startHz: Double, stopHz: Double, points: Int) throws -> [(hz: Double, dBm: Double)] {
        usleep(120_000)
        lock.lock(); let carriers = carriersKHz; lock.unlock()
        let dtt: [(Double, Double, Double)] = [(482e6, 490e6, -62), (530e6, 538e6, -55), (594e6, 602e6, -68), (642e6, 650e6, -60)]
        return (0..<points).map { i -> (hz: Double, dBm: Double) in
            let f = startHz + (stopHz - startHz) * Double(i) / Double(max(points - 1, 1))
            var lvl = -105 + gauss() * 2
            for (a, b, l) in dtt where f >= a && f <= b { lvl = max(lvl, l + gauss() * 1.5) }
            for c in carriers {
                let d = abs(f - Double(c) * 1e3)
                if d < 300e3 { lvl = max(lvl, -35 - 40 * (d / 300e3).squareRoot() + gauss()) }
            }
            return (hz: f, dBm: (lvl * 10).rounded() / 10)
        }
    }

    private func gauss() -> Double {
        let u = Double.random(in: 1e-9...1), v = Double.random(in: 0...1)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    func close() {}
}
