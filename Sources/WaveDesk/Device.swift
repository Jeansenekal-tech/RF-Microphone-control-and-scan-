import Foundation
import Combine
import WaveDeskCore

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
    case shure, shureUHFR, sennheiserG4, sennheiserEWDX, sennheiserSSC, wisycom, soundDevices, deity, demo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .shure: return "Shure (ULX-D, QLX-D, SLX-D, Axient Digital)"
        case .shureUHFR: return "Shure UHF-R (UR4S / UR4D)"
        case .sennheiserG4: return "Sennheiser ew G3 / G4 / 2000 / 9000"
        case .sennheiserEWDX: return "Sennheiser EW-DX EM 2 / EM 4 (SSCv2, experimental)"
        case .sennheiserSSC: return "Sennheiser Digital 6000 (SSC, experimental)"
        case .wisycom: return "Wisycom (MRK16, MCR54, MRK960… – manual entry)"
        case .soundDevices: return "Sound Devices Astral (A20-Nexus, A20-RX… – manual entry)"
        case .deity: return "Deity THEOS (D2RX, D4RX… – manual entry)"
        case .demo: return "Demo receiver (no hardware)"
        }
    }

    var short: String {
        switch self {
        case .shure: return "Shure"
        case .shureUHFR: return "Shure UHF-R"
        case .sennheiserG4: return "Sennheiser G3/G4"
        case .sennheiserEWDX: return "Sennheiser EW-DX"
        case .sennheiserSSC: return "Sennheiser SSC"
        case .wisycom: return "Wisycom"
        case .soundDevices: return "Sound Devices"
        case .deity: return "Deity"
        case .demo: return "Demo"
        }
    }

    var supported: Set<ChannelField> {
        switch self {
        case .shure, .sennheiserG4, .demo: return [.name, .frequency, .gain, .mute]
        case .sennheiserSSC, .sennheiserEWDX: return [.name, .frequency, .mute]
        case .shureUHFR: return [.name, .frequency, .gain]
        case .wisycom, .soundDevices, .deity: return [.name, .frequency]
        }
    }

    /// No published control protocol: channels are entered by hand and kept in the project.
    var isManual: Bool { self == .wisycom || self == .soundDevices || self == .deity }
    var needsHost: Bool { self != .demo && !isManual }
    /// Sound Devices A20-Nexus has a browser-based control app at its IP address.
    var hasWebUI: Bool { self == .soundDevices }
    var needsPassword: Bool { self == .sennheiserEWDX }
}

struct DeviceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: DeviceKind
    var host: String
    var nickname: String
    var password: String? = nil     // EW-DX SSCv2 password
    // Optional for every kind: what the receiver can tune to (used by coordination).
    var tuneLowMHz: Double? = nil
    var tuneHighMHz: Double? = nil
    var tuneStepKHz: Int? = nil
    // Manual devices (no network control): model and the channels typed in by the user.
    var model: String? = nil
    var manualChannels: [ManualChannel]? = nil
}

struct ManualChannel: Codable, Equatable {
    var name: String
    var freqKHz: Int?
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
        tuneLowMHz = config.tuneLowMHz
        tuneHighMHz = config.tuneHighMHz
        tuneStepKHz = config.tuneStepKHz
        channels = (1...max(1, channelCount)).map { ChannelState(idx: $0) }
    }

    var password: String?
    @Published var tuneLowMHz: Double? = nil
    @Published var tuneHighMHz: Double? = nil
    @Published var tuneStepKHz: Int? = nil

    var config: DeviceConfig {
        DeviceConfig(id: id, kind: kind, host: host, nickname: nickname, password: password,
                     tuneLowMHz: tuneLowMHz, tuneHighMHz: tuneHighMHz, tuneStepKHz: tuneStepKHz)
    }

    /// Tuning range / step limits for coordination (nil = only the global coordination range applies).
    var tuning: TuningLimit? {
        guard tuneLowMHz != nil || tuneHighMHz != nil || tuneStepKHz != nil else { return nil }
        return TuningLimit(lowKHz: tuneLowMHz.map { Int(($0 * 1000).rounded()) },
                           highKHz: tuneHighMHz.map { Int(($0 * 1000).rounded()) },
                           stepKHz: tuneStepKHz)
    }
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
        case .shureUHFR: return UHFRDevice(config: config)
        case .sennheiserG4: return SennheiserG4Device(config: config)
        case .sennheiserEWDX: return EWDXDevice(config: config)
        case .sennheiserSSC: return SennheiserSSCDevice(config: config)
        case .wisycom, .soundDevices, .deity: return ManualDevice(config: config)
        case .demo: return DemoDevice(config: config)
        }
    }
}
