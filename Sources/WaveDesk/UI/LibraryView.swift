import SwiftUI
import AppKit
import WaveDeskCore

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var library: ScanLibrary
    @State private var venue = "All venues"
    @State private var selection: UUID?
    @State private var draft: LibraryScan?

    private var filtered: [LibraryScan] {
        venue == "All venues" ? library.scans : library.scans.filter { $0.venue == venue }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Venue", selection: $venue) {
                        Text("All venues").tag("All venues")
                        ForEach(library.venues, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 260)
                    Spacer()
                    Button("Import scan file…") {
                        for url in Panels.open(types: Panels.scanTypes, multiple: true) {
                            do { try state.importScanFile(url) } catch { Panels.alert("Import failed", error.localizedDescription) }
                        }
                    }
                }
                .padding(8)
                Table(filtered, selection: $selection) {
                    TableColumn("Date") { s in Text(s.date.formatted(date: .abbreviated, time: .shortened)) }
                    TableColumn("Venue") { s in Text(s.venue) }
                    TableColumn("Title") { s in Text(s.title) }
                    TableColumn("Range") { s in Text(String(format: "%.1f–%.1f MHz", s.startMHz, s.stopMHz)) }
                    TableColumn("Source") { s in Text(s.source) }
                    TableColumn("Points") { s in Text("\(s.kHz.count)") }
                }
            }
            .frame(minWidth: 520)

            VStack(alignment: .leading, spacing: 10) {
                if let d = Binding($draft) {
                    Text("Scan details").font(.headline)
                    TextField("Venue", text: d.venue)
                    TextField("Title", text: d.title)
                    TextField("Notes", text: d.notes, axis: .vertical).lineLimit(3...6)
                    Text("Region: \(RegionProfile.byID(d.wrappedValue.regionID).name)").font(.caption)
                    HStack {
                        Button("Save") { library.update(d.wrappedValue) }
                        Button("Show on spectrum") { state.showOverlay(d.wrappedValue) }
                            .buttonStyle(.borderedProminent)
                    }
                    HStack {
                        Button("Export CSV…") {
                            let s = d.wrappedValue
                            let csv = s.points.map { String(format: "%.3f,%.1f", $0.kHz / 1000, $0.dBm) }.joined(separator: "\n")
                            Panels.save(Data(csv.utf8), suggestedName: "\(s.venue) \(s.title).csv", types: [.commaSeparatedText])
                        }
                        Button("Delete", role: .destructive) {
                            library.delete(d.wrappedValue)
                            draft = nil
                            selection = nil
                        }
                    }
                } else {
                    Text("Venue scan library").font(.headline)
                    Text("Every scan you save or import is kept here, tagged with the venue from the Project page. When you come back to a venue, show its old scans on the spectrum to compare, and use them as reference scans for coordination.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .frame(minWidth: 280, idealWidth: 320)
        }
        .onChange(of: selection) { id in draft = id.flatMap { library.scan($0) } }
    }
}
