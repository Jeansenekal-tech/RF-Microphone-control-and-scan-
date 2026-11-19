import Foundation
import Combine

struct ChannelState: Identifiable, Equatable {
    var idx: Int
    var id: Int { idx }
    var name = ""
    var freqKHz: Int?
    var rfA: Int?          // dBm
    var rfB: Int?          // dBm
    var antenna = ""
    var audio: Int?        // dBFS
    var battBars: Int?     // 0...5
    var battMin: Int?
    var mute: Bool?
    var gain: Int?         // dB
    var txType = ""
}

enum ChannelField: Hashable { case name, frequency, gain, mute }

enum SetValue {
    case name(String), frequency(Int), gain(Int), mute(Bool)
}

enum DeviceKind: String, Codable, CaseIterable, Identifiable {
    case shure, sennheiserG4, sennheiserEWDX, sennheiserSSC, demo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shure: return "Shure (ULX-D, QLX-D, SLX-D, Axient Digital)"
        case .sennheiserG4: return "Sennheiser ew G3 / G4 / 2000 / 9000"
        case .sennheiserEWDX: return "Sennheiser EW-DX EM 2 / EM 4 (SSCv2, experimental)"
        case .sennheiserSSC: return "Sennheiser Digital 6000 (SSC, experimental)"
        case .demo: return "Demo receiver (no hardware)"
        }
    }

    var short: String {
        switch self {
        case .shure: return "Shure"
        case .sennheiserG4: return "Sennheiser G3/G4"
        case .sennheiserEWDX: return "Sennheiser EW-DX"
        case .sennheiserSSC: return "Sennheiser SSC"
        case .demo: return "Demo"
        }
    }

    var supported: Set<ChannelField> {
        switch self {
        case .shure, .sennheiserG4, .demo: return [.name, .frequency, .gain, .mute]
        case .sennheiserSSC, .sennheiserEWDX: return [.name, .frequency, .mute]
        }
    }

    var needsHost: Bool { self != .demo }
    var needsPassword: Bool { self == .sennheiserEWDX }
}

struct DeviceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: DeviceKind
    var host: String
    var nickname: String
    var password: String? = nil     // EW-DX SSCv2 password
}

/// Base class for one physical receiver. All state changes happen on the main thread
/// (network callbacks are delivered on DispatchQueue.main).
class Device: ObservableObject, Identifiable {
    let id: UUID
    let kind: DeviceKind
    let host: String
    @Published var nickname: String
    @Published var channels: [ChannelState]
    @Published var online = false
    @Published var status = "Idle"
    @Published var model = ""

    /// Called when a channel's name or frequency changes (spectrum markers, conflict check).
    var onIdentityChange: (() -> Void)?
    var stopped = true

    init(config: DeviceConfig, channelCount: Int = 1) {
        id = config.id
        kind = config.kind
        host = config.host
        nickname = config.nickname
        password = config.password
        channels = (1...max(1, channelCount)).map { ChannelState(idx: $0) }
    }

    var password: String?
    var config: DeviceConfig { DeviceConfig(id: id, kind: kind, host: host, nickname: nickname, password: password) }
    var displayName: String {
        if !nickname.isEmpty { return nickname }
        if !model.isEmpty { return model }
        return kind.needsHost ? host : kind.short
    }

    func start() { stopped = false }
    func stop() { stopped = true; online = false; status = "Stopped" }
    func set(_ value: SetValue, channel: Int) {}

    func channel(_ idx: Int) -> ChannelState? { channels.first { $0.idx == idx } }

    func update(_ idx: Int, _ body: (inout ChannelState) -> Void) {
        guard idx >= 1 && idx <= 16 else { return }
        var i = channels.firstIndex { $0.idx == idx }
        if i == nil {
            channels.append(ChannelState(idx: idx))
            channels.sort { $0.idx < $1.idx }
            i = channels.firstIndex { $0.idx == idx }
        }
        guard let k = i else { return }
        var c = channels[k]
        let oldName = c.name, oldFreq = c.freqKHz
        body(&c)
        if c != channels[k] { channels[k] = c }
        if oldName != c.name || oldFreq != c.freqKHz { onIdentityChange?() }
    }

    static func make(_ config: DeviceConfig) -> Device {
        switch config.kind {
        case .shure: return ShureDevice(config: config)
        case .sennheiserG4: return SennheiserG4Device(config: config)
        case .sennheiserEWDX: return EWDXDevice(config: config)
        case .sennheiserSSC: return SennheiserSSCDevice(config: config)
        case .demo: return DemoDevice(config: config)
        }
    }
}
