import Foundation

/// A receiver this app can't talk to (no published control protocol): Wisycom, Sound Devices Astral,
/// Deity THEOS. Channel names and frequencies are typed in and saved with the project, so these
/// receivers still take part in coordination, conflict checks, the spectrum and the monitor.
/// Frequencies chosen by the coordinator have to be set on the receiver by hand.
final class ManualDevice: Device {
    init(config: DeviceConfig) {
        let saved = config.manualChannels ?? []
        super.init(config: config, channelCount: max(1, saved.count))
        model = config.model ?? ""
        for (i, ch) in saved.enumerated() {
            update(i + 1) { c in
                c.name = ch.name
                c.freqKHz = ch.freqKHz
            }
        }
    }

    override func start() {
        super.start()
        online = true
        status = "Manual entry – set frequencies on the receiver"
    }

    override func stop() {
        super.stop()
        status = "Manual entry"
    }

    override var config: DeviceConfig {
        var c = super.config
        c.model = model.isEmpty ? nil : model
        c.manualChannels = channels.map { ManualChannel(name: $0.name, freqKHz: $0.freqKHz) }
        return c
    }

    override func set(_ value: SetValue, channel: Int) {
        update(channel) { c in
            switch value {
            case .name(let n): c.name = n
            case .frequency(let f): c.freqKHz = f
            case .gain, .mute: break
            }
        }
    }

    func addChannel() {
        let next = (channels.map(\.idx).max() ?? 0) + 1
        guard next <= 16 else { return }
        update(next) { _ in }
        onIdentityChange?()
    }

    func removeLastChannel() {
        guard channels.count > 1 else { return }
        channels.removeLast()
        onIdentityChange?()
    }
}
