import Foundation
import UniqueAVCore

/// Shure UHF-R receivers (UR4S single, UR4D dual) over the rear Ethernet port.
///
/// Protocol (Shure "Command Strings for UHF-R Receivers"): UDP port 2202, ASCII frames
/// delimited with asterisks, e.g.
///     * GET 1 CHAN_NAME *        ->  * REPORT 1 CHAN_NAME {LEAD VOX} *
///     * SET 1 FREQUENCY 578350 *     (kHz, shown on the receiver as 578.350)
///     * SET 1 METER_RATE 00200 * ->  * SAMPLE 1 ALL ... *   (RF / audio metering)
/// The receiver also sends REPORT strings by itself when something changes on the front panel.
///
/// Values not yet verified on hardware are collected in `Tuning` so they are easy to adjust.
final class UHFRDevice: UDPDevice {
    enum Tuning {
        /// Raw AUDIO_GAIN value that corresponds to 0 dB.
        static let gainOffset = 0
        /// Parameters polled for every channel (the UHF-R also pushes REPORTs on change).
        static let polled = ["CHAN_NAME", "FREQUENCY", "AUDIO_GAIN", "TX_BAT", "TX_TYPE", "GROUP_CHAN"]
        static let meterRateMs = 200
    }

    override var udpPort: UInt16 { ShureProtocol.port }   // 2202, UDP on UHF-R
    override var pollInterval: TimeInterval { 2 }
    private var tick = 0

    init(config: DeviceConfig) {
        super.init(config: config, channelCount: 1)
        model = "UHF-R"
    }

    private func send(_ modernCommand: String) {
        sendData(Data(ShureProtocol.uhfr(modernCommand).utf8))
    }

    override func poll() {
        // Ask channel 2 as well: a UR4D answers and gets a second channel card, a UR4S stays silent.
        let chans = Set(channels.map(\.idx)).union([1, 2]).sorted()
        if tick % 5 == 0 {
            for ch in chans { send(ShureProtocol.meterRate(ch, ms: Tuning.meterRateMs)) }
        }
        if tick % 3 == 0 {
            for ch in chans {
                for key in Tuning.polled { send(ShureProtocol.frame("GET \(ch) \(key)")) }
            }
        }
        tick += 1
    }

    override func handle(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        for frame in ShureProtocol.extractStarFrames(text) {
            guard let msg = ShureProtocol.parse(frame) else { continue }
            applyShure(msg, gainOffset: Tuning.gainOffset)
        }
        if channels.contains(where: { $0.idx == 2 }) { model = "UR4D" } else if model == "UHF-R" { model = "UR4S / UHF-R" }
    }

    override func set(_ value: SetValue, channel: Int) {
        switch value {
        case .name(let n):
            // UHF-R channel names are short and upper case on the display.
            send(ShureProtocol.setName(channel, String(n.uppercased().prefix(8))))
            send(ShureProtocol.frame("GET \(channel) CHAN_NAME"))
        case .frequency(let f):
            send(ShureProtocol.setFrequency(channel, kHz: f))
            send(ShureProtocol.frame("GET \(channel) FREQUENCY"))
        case .gain(let g):
            send(ShureProtocol.frame("SET \(channel) AUDIO_GAIN \(String(format: "%02d", max(0, g + Tuning.gainOffset)))"))
            send(ShureProtocol.frame("GET \(channel) AUDIO_GAIN"))
        case .mute:
            break
        }
    }
}
