import Foundation

/// IPv4 helpers for the Network page: subnet checks and the address list used by receiver discovery.
public enum IPv4 {
    public static func parse(_ s: String) -> UInt32? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let b = UInt32(p), b <= 255, !p.isEmpty, p.count <= 3 else { return nil }
            v = v << 8 | b
        }
        return v
    }

    public static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)"
    }

    public static func mask(prefix: Int) -> UInt32 {
        prefix <= 0 ? 0 : prefix >= 32 ? UInt32.max : UInt32.max << UInt32(32 - prefix)
    }

    /// "255.255.255.0" -> 24 (nil if the mask isn't contiguous).
    public static func prefixLength(mask: String) -> Int? {
        guard let m = parse(mask) else { return nil }
        let n = m.nonzeroBitCount
        return Self.mask(prefix: n) == m ? n : nil
    }

    public static func sameSubnet(_ a: String, _ b: String, prefix: Int) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        let m = mask(prefix: prefix)
        return x & m == y & m
    }

    /// "192.168.1.0/24"
    public static func subnet(_ ip: String, prefix: Int) -> String? {
        guard let v = parse(ip) else { return nil }
        return "\(format(v & mask(prefix: prefix)))/\(prefix)"
    }

    /// 169.254.x.x – the address a device gives itself when there's no DHCP server on the network.
    public static func isLinkLocal(_ ip: String) -> Bool { ip.hasPrefix("169.254.") }

    /// Every usable self-assigned address (169.254.1.0 – 169.254.254.255, RFC 3927), minus `excluding`.
    public static func linkLocalHosts(excluding: Set<String> = []) -> [String] {
        var out: [String] = []
        out.reserveCapacity(254 * 256)
        for a in 1...254 { for b in 0...255 {
            let ip = "169.254.\(a).\(b)"
            if !excluding.contains(ip) { out.append(ip) }
        } }
        return out
    }

    /// IPv4 addresses from `arp -an` output (optionally only those seen on one interface).
    /// Lines look like: "? (169.254.12.34) at 0:e:dd:1:2:3 on en5 ifscope [ethernet]".
    public static func parseARP(_ output: String, interface: String? = nil) -> [String] {
        var out: [String] = []
        for line in output.split(whereSeparator: { $0.isNewline }) {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close else { continue }
            let ip = String(line[line.index(after: open)..<close])
            guard parse(ip) != nil, !line.contains("incomplete") else { continue }
            if let i = interface, !line.contains(" on \(i) ") && !line.hasSuffix(" on \(i)") { continue }
            if ip.hasSuffix(".255") || ip.hasPrefix("224.") || ip.hasPrefix("239.") { continue }
            if !out.contains(ip) { out.append(ip) }
        }
        return out
    }

    /// Every host address in the subnet of `ip` (excluding network, broadcast and `ip` itself).
    /// Subnets with more than `limit` hosts fall back to the /24 around `ip`.
    public static func hosts(around ip: String, prefix: Int, limit: Int = 1022) -> [String] {
        guard let v = parse(ip) else { return [] }
        var p = max(0, min(32, prefix))
        if p < 32, (1 << (32 - p)) - 2 > limit { p = 24 }
        guard p <= 30 else { return [] }
        let m = mask(prefix: p)
        let net = v & m
        let size = UInt32(1) << UInt32(32 - p)
        return (1..<(size - 1)).compactMap { h in
            let a = net | h
            return a == v ? nil : format(a)
        }
    }
}
