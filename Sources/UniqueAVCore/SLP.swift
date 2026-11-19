import Foundation

/// Service Location Protocol v2 (RFC 2608) – what Shure Discovery uses (multicast 239.255.254.253:8427,
/// the same discovery Wireless Workbench, Shure Update Utility and Designer use).
/// We only need devices to *answer*: the sender address of any reply is a Shure device.
public enum SLP {
    public static let shureGroup = "239.255.254.253"
    public static let shurePort: UInt16 = 8427
    public static let standardGroup = "239.255.255.253"
    public static let standardPort: UInt16 = 427

    public enum Function: UInt8 { case srvRqst = 1, srvRply = 2, srvReg = 3, saAdvert = 11, srvTypeRqst = 9, srvTypeRply = 10 }

    /// Service Request, e.g. for "service:service-agent" (every SLP service agent must answer that).
    public static func serviceRequest(xid: UInt16, serviceType: String, scope: String = "", lang: String = "en") -> Data {
        var body = Data()
        body.appendString16("")              // previous responder list
        body.appendString16(serviceType)
        body.appendString16(scope)
        body.appendString16("")              // predicate
        body.appendString16("")              // SLP SPI
        return message(.srvRqst, xid: xid, lang: lang, body: body)
    }

    /// Service Type Request for every naming authority.
    public static func serviceTypeRequest(xid: UInt16, scope: String = "", lang: String = "en") -> Data {
        var body = Data()
        body.appendString16("")              // previous responder list
        body.appendUInt16(0xFFFF)            // all naming authorities
        body.appendString16(scope)
        return message(.srvTypeRqst, xid: xid, lang: lang, body: body)
    }

    static func message(_ f: Function, xid: UInt16, lang: String, body: Data) -> Data {
        let langBytes = Data(lang.utf8)
        let length = 14 + langBytes.count + body.count
        var d = Data([2, f.rawValue])                          // version 2, function
        d.append(contentsOf: [UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        d.appendUInt16(0x2000)                                 // flags: R = request multicast
        d.append(contentsOf: [0, 0, 0])                        // next extension offset
        d.appendUInt16(xid)
        d.appendUInt16(UInt16(langBytes.count))
        d.append(langBytes)
        d.append(body)
        return d
    }

    /// Function id of an SLP message (nil if it isn't SLPv2).
    public static func function(of data: Data) -> UInt8? {
        let b = [UInt8](data.prefix(2))
        return b.count == 2 && b[0] == 2 ? b[1] : nil
    }

    /// Readable "service:…" strings in a reply, e.g. "service:shure.ulxd4q://169.254.20.5" – used as a model hint.
    public static func serviceStrings(in data: Data) -> [String] {
        let text = String(decoding: data.map { $0 >= 32 && $0 < 127 ? $0 : 32 }, as: UTF8.self)
        var out: [String] = []
        var rest = Substring(text)
        while let r = rest.range(of: "service:") {
            let tail = rest[r.lowerBound...]
            let end = tail.firstIndex(where: { $0 == " " || $0 == "," }) ?? tail.endIndex
            let s = String(tail[..<end])
            if s.count > 8, !out.contains(s) { out.append(s) }
            rest = tail[end...]
        }
        return out
    }
}

extension IPv4 {
    /// Directed broadcast address of the subnet, e.g. 192.168.1.20/24 -> 192.168.1.255.
    public static func broadcast(_ ip: String, prefix: Int) -> String? {
        guard let v = parse(ip) else { return nil }
        return format(v | ~mask(prefix: prefix))
    }
}

extension Data {
    mutating func appendUInt16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func appendString16(_ s: String) {
        let b = Data(s.utf8)
        appendUInt16(UInt16(b.count))
        append(b)
    }
}
