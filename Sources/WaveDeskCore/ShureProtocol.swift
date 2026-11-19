import Foundation

/// Shure networked receivers (ULX-D, QLX-D, SLX-D, Axient Digital, MXW...) speak ASCII
/// "command strings" over TCP port 2202:
///
///     < GET 1 CHAN_NAME >          ->  < REP 1 CHAN_NAME {Lead Vox} >
///     < SET 1 FREQUENCY 578350 >       (kHz, 6 digits)
///     < SET 1 METER_RATE 00200 >   ->  < SAMPLE 1 ALL AX 098 035 >   (antenna, RF, audio)
public enum ShureProtocol {
    public static let port: UInt16 = 2202

    public enum Message: Equatable {
        /// `channel` is nil for device-level reports such as MODEL or DEVICE_ID.
        case rep(channel: Int?, key: String, values: [String])
        case sample(channel: Int, values: [String])
    }

    public struct Sample: Equatable {
        public var antenna: String      // "A", "B", "AB" or ""
        public var rfDBm: Int?
        public var audioDBFS: Int?
    }

    /// Pulls complete `< ... >` frames out of `buffer`, leaving any partial frame behind.
    public static func extractFrames(_ buffer: inout String) -> [String] {
        var frames: [String] = []
        while let open = buffer.firstIndex(of: "<"),
              let close = buffer[open...].firstIndex(of: ">") {
            let body = buffer[buffer.index(after: open)..<close]
            frames.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
            buffer.removeSubrange(buffer.startIndex...close)
        }
        if let open = buffer.firstIndex(of: "<") {
            buffer.removeSubrange(buffer.startIndex..<open)
        } else {
            buffer = ""
        }
        if buffer.count > 8192 { buffer = "" }
        return frames
    }

    /// Splits on whitespace; `{braced values}` become one token without the braces.
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inBrace = false
        for ch in s {
            if inBrace {
                if ch == "}" {
                    inBrace = false
                    out.append(cur)
                    cur = ""
                } else {
                    cur.append(ch)
                }
                continue
            }
            if ch == "{" {
                if !cur.isEmpty { out.append(cur); cur = "" }
                inBrace = true
            } else if ch.isWhitespace {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func parse(_ body: String) -> Message? {
        let t = tokens(body)
        guard t.count >= 2 else { return nil }
        switch t[0].uppercased() {
        case "REP", "REPORT":   // UHF-R answers with REPORT
            if let ch = Int(t[1]) {
                guard t.count >= 3 else { return nil }
                return .rep(channel: ch, key: t[2].uppercased(), values: Array(t.dropFirst(3)))
            }
            return .rep(channel: nil, key: t[1].uppercased(), values: Array(t.dropFirst(2)))
        case "SAMPLE":
            guard let ch = Int(t[1]) else { return nil }
            return .sample(channel: ch, values: t.dropFirst(2).filter { $0.uppercased() != "ALL" })
        default:
            return nil
        }
    }

    /// Decodes the ULX-D / QLX-D / SLX-D sample layout: `<diversity> <rf 0-115> <audio 0-50>`.
    /// RF dBm = value - 128, audio dBFS = value - 50.
    public static func decodeSample(_ values: [String]) -> Sample {
        let ant = values.first { Int($0) == nil } ?? ""
        let nums = values.compactMap { Int($0) }
        let antenna = String(ant.uppercased().filter { $0 == "A" || $0 == "B" })
        return Sample(antenna: antenna,
                      rfDBm: nums.count >= 1 ? nums[0] - 128 : nil,
                      audioDBFS: nums.count >= 2 ? nums[1] - 50 : nil)
    }

    // MARK: UHF-R dialect
    //
    // UHF-R receivers (UR4S, UR4D) use the same command words over UDP port 2202, but frames
    // are delimited with asterisks:   * GET 1 CHAN_NAME *   ->   * REPORT 1 CHAN_NAME {Vox} *

    /// Frames in one UHF-R datagram, e.g. "* REPORT 1 FREQUENCY 578350 *".
    public static func extractStarFrames(_ text: String) -> [String] {
        var frames: [String] = []
        var cur = ""
        var inFrame = false
        var inBrace = false
        for ch in text {
            if inFrame && ch == "{" { inBrace = true }
            if inFrame && ch == "}" { inBrace = false }
            if ch == "*" && !inBrace {
                if inFrame {
                    let f = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !f.isEmpty { frames.append(f) }
                    cur = ""
                }
                inFrame.toggle()
            } else if inFrame {
                cur.append(ch)
            }
        }
        return frames
    }

    /// Converts a command built for the modern dialect ("< SET 1 ... >") to UHF-R ("* SET 1 ... *").
    public static func uhfr(_ command: String) -> String {
        var s = command.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<") { s.removeFirst() }
        if s.hasSuffix(">") { s.removeLast() }
        return "* \(s.trimmingCharacters(in: .whitespaces)) *"
    }

    // MARK: Commands

    public static func frame(_ s: String) -> String { "< \(s) >" }

    public static func getAll(_ channel: Int = 0) -> String { frame("GET \(channel) ALL") }

    public static func setName(_ channel: Int, _ name: String) -> String {
        let clean = String(name.filter { !"{}<>".contains($0) }.prefix(31))
        return frame("SET \(channel) CHAN_NAME {\(clean)}")
    }

    public static func setFrequency(_ channel: Int, kHz: Int) -> String {
        frame("SET \(channel) FREQUENCY \(String(format: "%06d", kHz))")
    }

    /// Gain in dB; Shure encodes AUDIO_GAIN with a +18 offset (0 = -18 dB).
    public static func setGain(_ channel: Int, dB: Int) -> String {
        frame("SET \(channel) AUDIO_GAIN \(String(format: "%03d", max(0, dB + 18)))")
    }

    public static func setMute(_ channel: Int, _ on: Bool) -> String {
        frame("SET \(channel) AUDIO_MUTE \(on ? "ON" : "OFF")")
    }

    public static func meterRate(_ channel: Int, ms: Int) -> String {
        frame("SET \(channel) METER_RATE \(String(format: "%05d", ms))")
    }
}
