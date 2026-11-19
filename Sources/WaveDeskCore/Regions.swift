import Foundation

/// A band to draw on the spectrum and (optionally) keep frequencies out of.
public struct RestrictedBand: Equatable, Identifiable {
    public var id: String { "\(lowMHz)-\(highMHz)" }
    public var lowMHz: Double
    public var highMHz: Double
    public var label: String
}

public struct TVChannel: Equatable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var lowMHz: Double
    public var highMHz: Double
}

/// Regional spectrum data. Spectrum rules change and vary by licence class -
/// always confirm with the local regulator (FCC, Ofcom/CEPT administrations, ICASA...).
public struct RegionProfile: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var channelWidthMHz: Double
    public var firstChannel: Int
    public var firstChannelLowMHz: Double
    public var lastChannel: Int
    public var defaultStartMHz: Double
    public var defaultStopMHz: Double
    public var restricted: [RestrictedBand]
    public var notes: String

    public var tvChannels: [TVChannel] {
        guard hasChannels else { return [] }
        return (firstChannel...lastChannel).map { n in
            let lo = firstChannelLowMHz + Double(n - firstChannel) * channelWidthMHz
            return TVChannel(number: n, lowMHz: lo, highMHz: lo + channelWidthMHz)
        }
    }

    public func tvChannel(containingMHz f: Double) -> TVChannel? {
        tvChannels.first { f >= $0.lowMHz && f < $0.highMHz }
    }

    public static let southAfrica = RegionProfile(
        id: "za", name: "South Africa",
        channelWidthMHz: 8, firstChannel: 21, firstChannelLowMHz: 470, lastChannel: 69,
        defaultStartMHz: 470, defaultStopMHz: 694,
        restricted: [
            RestrictedBand(lowMHz: 703, highMHz: 733, label: "IMT700 uplink (mobile)"),
            RestrictedBand(lowMHz: 758, highMHz: 788, label: "IMT700 downlink (mobile)"),
            RestrictedBand(lowMHz: 791, highMHz: 821, label: "IMT800 downlink (mobile)"),
            RestrictedBand(lowMHz: 832, highMHz: 862, label: "IMT800 uplink (mobile)"),
        ],
        notes: """
        UHF TV uses 8 MHz channels (Ch21 = 470-478 MHz). After the digital migration, \
        DTT (DVB-T2) stays below 694 MHz and the 700/800 MHz bands were auctioned to mobile \
        operators in 2022, so plan mics in 470-694 MHz around the DTT multiplexes active at \
        your venue (scan first). Gaps 733-758 and 821-832 MHz and the 863-865 MHz SRD band \
        are shown but not marked as usable - confirm current ICASA rules and licensing \
        before using them.
        """)

    public static let unitedStates = RegionProfile(
        id: "us", name: "United States",
        channelWidthMHz: 6, firstChannel: 14, firstChannelLowMHz: 470, lastChannel: 36,
        defaultStartMHz: 470, defaultStopMHz: 608,
        restricted: [
            RestrictedBand(lowMHz: 608, highMHz: 614, label: "Ch37 radio astronomy"),
            RestrictedBand(lowMHz: 617, highMHz: 652, label: "600 MHz mobile downlink"),
            RestrictedBand(lowMHz: 663, highMHz: 698, label: "600 MHz mobile uplink"),
        ],
        notes: "TV Ch14-36 (470-608 MHz). 614-616 and 653-657 MHz have special rules for mics.")

    public static let europe = RegionProfile(
        id: "eu", name: "Europe (CEPT)",
        channelWidthMHz: 8, firstChannel: 21, firstChannelLowMHz: 470, lastChannel: 48,
        defaultStartMHz: 470, defaultStopMHz: 694,
        restricted: [
            RestrictedBand(lowMHz: 703, highMHz: 733, label: "700 MHz mobile uplink"),
            RestrictedBand(lowMHz: 758, highMHz: 788, label: "700 MHz mobile downlink"),
            RestrictedBand(lowMHz: 791, highMHz: 821, label: "800 MHz mobile downlink"),
            RestrictedBand(lowMHz: 832, highMHz: 862, label: "800 MHz mobile uplink"),
        ],
        notes: "TV Ch21-48 (470-694 MHz). Duplex gaps and 863-865 MHz depend on the country.")

    public static let none = RegionProfile(
        id: "none", name: "No region overlay",
        channelWidthMHz: 8, firstChannel: 0, firstChannelLowMHz: 0, lastChannel: -1,
        defaultStartMHz: 470, defaultStopMHz: 608, restricted: [], notes: "")

    public var hasChannels: Bool { lastChannel >= firstChannel }

    public static let all: [RegionProfile] = [.southAfrica, .unitedStates, .europe, .none]

    public static func byID(_ id: String) -> RegionProfile {
        all.first { $0.id == id } ?? .southAfrica
    }
}
