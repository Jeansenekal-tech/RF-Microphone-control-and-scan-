import Foundation

/// Files live in ~/Library/Application Support/Unique AV RF Scan Co-ord/{Projects,Scans,inventory.json}.
enum Storage {
    static let folderName = "Unique AV RF Scan Co-ord"
    static let projectExtension = "uavproj"

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ensure(base.appendingPathComponent(folderName, isDirectory: true))
    }
    static var projects: URL { ensure(root.appendingPathComponent("Projects", isDirectory: true)) }
    static var scans: URL { ensure(root.appendingPathComponent("Scans", isDirectory: true)) }
    static var inventoryFile: URL { root.appendingPathComponent("inventory.json") }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("UniqueAV: failed to save \(url.lastPathComponent): \(error)")
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))
    }
}
