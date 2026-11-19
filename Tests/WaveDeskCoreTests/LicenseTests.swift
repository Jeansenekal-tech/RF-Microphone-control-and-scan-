import XCTest
import CryptoKit
@testable import WaveDeskCore

final class LicenseTests: XCTestCase {
    let key = Curve25519.Signing.PrivateKey()
    var publicHex: String { key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined() }

    /// Builds a certificate exactly like Keygen's base64+ed25519 machine files.
    func certificate(fingerprint: String = "fp1", issued: String = "2026-01-01T00:00:00.000Z",
                     expiry: String = "2026-01-31T00:00:00.000Z", licenseExpiry: String? = nil,
                     status: String = "ACTIVE", trial: Bool = false, tamper: Bool = false) throws -> String {
        var lic: [String: Any] = ["name": "Test", "key": "KEY-123", "status": status,
                                  "metadata": ["trial": trial]]
        if let e = licenseExpiry { lic["expiry"] = e } else { lic["expiry"] = NSNull() }
        let payload: [String: Any] = [
            "meta": ["issued": issued, "expiry": expiry, "ttl": 2_592_000],
            "data": ["type": "machines", "id": "m1", "attributes": ["fingerprint": fingerprint, "name": "Studio Mac"]],
            "included": [["type": "licenses", "id": "l1", "attributes": lic]],
        ]
        var enc = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
        let sig = try key.signature(for: Data("machine/\(enc)".utf8)).base64EncodedString()
        if tamper { enc = try JSONSerialization.data(withJSONObject: ["meta": [:]]).base64EncodedString() }
        let outer = try JSONSerialization.data(withJSONObject: ["enc": enc, "sig": sig, "alg": "base64+ed25519"])
        let b64 = outer.base64EncodedString()
        let lines = stride(from: 0, to: b64.count, by: 64).map { i -> String in
            let a = b64.index(b64.startIndex, offsetBy: i)
            return String(b64[a..<(b64.index(a, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex)])
        }
        return "-----BEGIN MACHINE FILE-----\n" + lines.joined(separator: "\n") + "\n-----END MACHINE FILE-----\n"
    }

    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testVerifiesAndDecodes() throws {
        let f = try LicenseFiles.verify(certificate: certificate(licenseExpiry: "2026-03-01T00:00:00Z", trial: true),
                                        publicKeyHex: publicHex)
        XCTAssertEqual(f.fingerprint, "fp1")
        XCTAssertEqual(f.machineName, "Studio Mac")
        XCTAssertEqual(f.licenseKey, "KEY-123")
        XCTAssertTrue(f.isTrial)
        XCTAssertEqual(f.expiry, d("2026-01-31T00:00:00Z"))
        XCTAssertEqual(f.licenseExpiry, d("2026-03-01T00:00:00Z"))
    }

    func testRejectsTamperingAndWrongKey() throws {
        XCTAssertThrowsError(try LicenseFiles.verify(certificate: certificate(tamper: true), publicKeyHex: publicHex)) {
            XCTAssertEqual($0 as? LicenseFileError, .badSignature)
        }
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try LicenseFiles.verify(certificate: certificate(), publicKeyHex: other))
        XCTAssertThrowsError(try LicenseFiles.verify(certificate: "garbage", publicKeyHex: publicHex))
    }

    func testVerdicts() throws {
        let f = try LicenseFiles.verify(certificate: certificate(licenseExpiry: "2026-03-01T00:00:00Z"), publicKeyHex: publicHex)
        let mid = d("2026-01-15T00:00:00Z")
        XCTAssertTrue(LicensePolicy.evaluate(f, fingerprint: "fp1", now: mid, lastSeen: nil).unlocks)
        XCTAssertEqual(LicensePolicy.evaluate(nil, fingerprint: "fp1", now: mid, lastSeen: nil), .noLicence)
        XCTAssertEqual(LicensePolicy.evaluate(f, fingerprint: "other", now: mid, lastSeen: nil), .wrongMachine)
        // Offline past the machine file expiry (30-day grace) -> must check in.
        XCTAssertEqual(LicensePolicy.evaluate(f, fingerprint: "fp1", now: d("2026-02-05T00:00:00Z"), lastSeen: nil),
                       .checkInRequired(lastChecked: f.issued))
        // Licence (e.g. trial) itself expired.
        XCTAssertEqual(LicensePolicy.evaluate(f, fingerprint: "fp1", now: d("2026-03-02T00:00:00Z"), lastSeen: nil),
                       .expired(trial: false))
        // Clock wound back more than 48 h behind the last time we saw.
        XCTAssertEqual(LicensePolicy.evaluate(f, fingerprint: "fp1", now: mid, lastSeen: d("2026-01-20T00:00:00Z")),
                       .clockTampered)
        let s = try LicenseFiles.verify(certificate: certificate(status: "SUSPENDED"), publicKeyHex: publicHex)
        XCTAssertEqual(LicensePolicy.evaluate(s, fingerprint: "fp1", now: mid, lastSeen: nil), .suspended)
        XCTAssertEqual(LicensePolicy.daysLeft(until: d("2026-01-20T12:00:00Z"), now: mid), 6)
    }
}
