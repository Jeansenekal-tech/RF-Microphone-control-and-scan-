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
