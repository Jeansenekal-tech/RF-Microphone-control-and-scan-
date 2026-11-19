import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Palette {
    static let groups: [Color] = [.blue, .orange, .purple, .pink, .teal, .yellow, .mint, .indigo]
    static func group(_ i: Int) -> Color { groups[((i % groups.count) + groups.count) % groups.count] }
    static let overlays: [Color] = [.purple, .pink, .teal, .indigo, .brown]
    static func severity(_ s: Severity) -> Color {
        switch s { case .critical: return .red; case .warning: return .orange; case .info: return .secondary }
    }
}

func fmtMHz(_ kHz: Int?) -> String {
    guard let k = kHz else { return "—" }
    return String(format: "%.3f MHz", Double(k) / 1000)
}

/// Horizontal level meter.
struct MeterBar: View {
    var label: String
    var value: Int?
    var lo: Double
    var hi: Double
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                    if let v = value {
                        let f = max(0, min(1, (Double(v) - lo) / (hi - lo)))
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: g.size.width * f)
                    }
                }
            }
            .frame(height: 7)
            Text(value.map { "\($0)" } ?? "—").font(.caption2.monospacedDigit()).frame(width: 30, alignment: .trailing)
        }
    }
}

struct BatteryView: View {
    var bars: Int?
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(fill(i))
                    .frame(width: 5, height: 10)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary.opacity(0.6), lineWidth: 1))
        .help(bars.map { "\($0)/5 bars" } ?? "No battery data")
    }

    private func fill(_ i: Int) -> Color {
        guard let b = bars else { return Color.secondary.opacity(0.15) }
        guard i < b else { return Color.secondary.opacity(0.15) }
        return b <= 1 ? .red : b == 2 ? .orange : .green
    }
}

enum Panels {
    static func save(_ data: Data, suggestedName: String, types: [UTType]) {
        let p = NSSavePanel()
        p.nameFieldStringValue = suggestedName
        p.allowedContentTypes = types
        p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url {
            do { try data.write(to: url, options: .atomic) } catch { alert("Could not save", error.localizedDescription) }
        }
    }

    static func open(types: [UTType], multiple: Bool = false) -> [URL] {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.allowsMultipleSelection = multiple
        p.canChooseDirectories = false
        return p.runModal() == .OK ? p.urls : []
    }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// Simple text prompt; returns nil on cancel.
    static func prompt(_ title: String, _ message: String = "", default value: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        a.accessoryView = field
        a.window.initialFirstResponder = field
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static let scanTypes: [UTType] = [.commaSeparatedText, .plainText, .tabSeparatedText, .text]
    static let projectType: UTType = UTType(filenameExtension: "wdproj") ?? .json
}

/// A titled box used on the inspector panels.
struct SectionBox<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            Text(title).font(.headline)
        }
    }
}
