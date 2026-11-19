import Foundation
import CryptoKit

/// A Keygen "machine file": a signed snapshot of this Mac's activation that works offline.
///
///     -----BEGIN MACHINE FILE-----
///     base64({"enc": base64(json), "sig": base64(ed25519 signature), "alg": "base64+ed25519"})
///     -----END MACHINE FILE-----
///
/// The signature covers the string "machine/" + enc and is checked with the account's
/// Ed25519 public verify key (hex), which is compiled into the app.
public struct MachineFile: Equatable {
    public var issued: Date
    public var expiry: Date            // must check in online before this (offline grace period)
    public var fingerprint: String
    public var machineName: String?
    public var licenseKey: String?
    public var licenseName: String?
    public var licenseExpiry: Date?    // trial / subscription end, nil = perpetual
    public var licenseStatus: String?  // ACTIVE, EXPIRED, SUSPENDED, BANNED…
    public var isTrial: Bool

    public init(issued: Date, expiry: Date, fingerprint: String, machineName: String? = nil, licenseKey: String? = nil,
                licenseName: String? = nil, licenseExpiry: Date? = nil, licenseStatus: String? = nil, isTrial: Bool = false) {
        self.issued = issued; self.expiry = expiry; self.fingerprint = fingerprint; self.machineName = machineName
        self.licenseKey = licenseKey; self.licenseName = licenseName; self.licenseExpiry = licenseExpiry
        self.licenseStatus = licenseStatus; self.isTrial = isTrial
    }
}

public enum LicenseFileError: Error, Equatable {
    case malformed(String)
    case unsupportedAlgorithm(String)
    case badSignature
    case badPublicKey
}

public enum LicenseFiles {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoNoFraction = ISO8601DateFormatter()

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoNoFraction.date(from: s)
    }

    /// Verifies the signature and decodes a machine file certificate.
    public static func verify(certificate: String, publicKeyHex: String) throws -> MachineFile {
        guard let keyData = Data(hex: publicKeyHex), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw LicenseFileError.badPublicKey
        }
        let body = certificate
            .replacingOccurrences(of: "-----BEGIN MACHINE FILE-----", with: "")
            .replacingOccurrences(of: "-----END MACHINE FILE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let outer = Data(base64Encoded: body),
              let obj = try? JSONSerialization.jsonObject(with: outer) as? [String: Any],
              let enc = obj["enc"] as? String, let sigB64 = obj["sig"] as? String, let alg = obj["alg"] as? String else {
            throw LicenseFileError.malformed("not a machine file")
        }
        guard alg == "base64+ed25519" else { throw LicenseFileError.unsupportedAlgorithm(alg) }
        guard let sig = Data(base64Encoded: sigB64),
              key.isValidSignature(sig, for: Data("machine/\(enc)".utf8)) else {
            throw LicenseFileError.badSignature
        }
        guard let inner = Data(base64Encoded: enc),
              let payload = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] else {
            throw LicenseFileError.malformed("payload")
        }
        return try decode(payload)
    }

    static func decode(_ p: [String: Any]) throws -> MachineFile {
        let meta = p["meta"] as? [String: Any] ?? [:]
        let data = p["data"] as? [String: Any] ?? [:]
        let attrs = data["attributes"] as? [String: Any] ?? [:]
        guard let issued = date(meta["issued"]), let expiry = date(meta["expiry"]),
              let fp = attrs["fingerprint"] as? String else {
            throw LicenseFileError.malformed("missing issued/expiry/fingerprint")
        }
        let included = p["included"] as? [[String: Any]] ?? []
        let lic = included.first { ($0["type"] as? String) == "licenses" }?["attributes"] as? [String: Any] ?? [:]
        let md = lic["metadata"] as? [String: Any] ?? [:]
        let trial = (md["trial"] as? Bool) ?? ((md["trial"] as? String) == "true")
        return MachineFile(issued: issued, expiry: expiry, fingerprint: fp, machineName: attrs["name"] as? String,
                           licenseKey: lic["key"] as? String, licenseName: lic["name"] as? String,
                           licenseExpiry: date(lic["expiry"]), licenseStatus: lic["status"] as? String, isTrial: trial)
    }
}

/// What the app should do, decided offline from the cached machine file.
public enum LicenseVerdict: Equatable {
    case valid(MachineFile)
    case noLicence
    case wrongMachine
    case checkInRequired(lastChecked: Date)   // offline longer than the grace period
    case expired(trial: Bool)
    case suspended
    case clockTampered

    public var unlocks: Bool { if case .valid = self { return true } else { return false } }
}

public enum LicensePolicy {
    /// Allowed backwards clock movement before we assume someone wound the clock back.
    public static let clockSkew: TimeInterval = 48 * 3600

    public static func evaluate(_ file: MachineFile?, fingerprint: String, now: Date, lastSeen: Date?) -> LicenseVerdict {
        if let last = lastSeen, now < last.addingTimeInterval(-clockSkew) { return .clockTampered }
        guard let f = file else { return .noLicence }
        if f.fingerprint != fingerprint { return .wrongMachine }
        if now < f.issued.addingTimeInterval(-clockSkew) { return .clockTampered }
        if let s = f.licenseStatus?.uppercased(), s == "SUSPENDED" || s == "BANNED" { return .suspended }
        if let e = f.licenseExpiry, now > e { return .expired(trial: f.isTrial) }
        if now > f.expiry { return .checkInRequired(lastChecked: f.issued) }
        return .valid(f)
    }

    /// Whole days left before `date` (rounded up), never negative.
    public static func daysLeft(until date: Date, now: Date) -> Int {
        max(0, Int((date.timeIntervalSince(now) / 86400).rounded(.up)))
    }
}

extension Data {
    init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0 else { return nil }
        var d = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }
}
