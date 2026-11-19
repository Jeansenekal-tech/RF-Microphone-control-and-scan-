import SwiftUI
import AppKit

struct InventoryView: View {
    @ObservedObject var inventory: InventoryStore
    @State private var selection = Set<UUID>()
    @State private var search = ""
    @State private var editing: InventoryItem?
    @State private var showLog = false

    private var filtered: [InventoryItem] {
        guard !search.isEmpty else { return inventory.items }
        return inventory.items.filter { i in
            [i.category, i.make, i.model, i.serial, i.label, i.band, i.holder, i.notes, i.status.rawValue]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { editing = InventoryItem() } label: { Label("Add", systemImage: "plus") }
                Button("Edit") {
                    if let id = selection.first, let i = inventory.items.first(where: { $0.id == id }) { editing = i }
                }
                .disabled(selection.count != 1)
                Divider().frame(height: 18)
                Button("Check out…") {
                    if let who = Panels.prompt("Check out \(selection.count) item(s)", "Who is taking them?"), !who.isEmpty {
                        inventory.checkOut(selection, to: who)
                    }
                }
                .disabled(selection.isEmpty)
                Button("Check in") { inventory.checkIn(selection) }.disabled(selection.isEmpty)
                Menu("Mark as") {
                    ForEach(ItemStatus.allCases) { s in Button(s.rawValue) { inventory.setStatus(selection, s) } }
                }
                .fixedSize()
                .disabled(selection.isEmpty)
                Button(role: .destructive) { inventory.delete(selection); selection = [] } label: { Image(systemName: "trash") }
                    .disabled(selection.isEmpty)
                Spacer()
                TextField("Search", text: $search).frame(width: 200)
                Toggle("Log", isOn: $showLog).toggleStyle(.button)
                Button("Export CSV…") {
                    Panels.save(Data(inventory.csv().utf8), suggestedName: "inventory.csv", types: [.commaSeparatedText])
                }
            }
            .padding(8)

            HSplitView {
                Table(filtered, selection: $selection) {
                    TableColumn("Label / tag") { i in Text(i.label) }
                    TableColumn("Category") { i in Text(i.category) }
                    TableColumn("Make") { i in Text(i.make) }
                    TableColumn("Model") { i in Text(i.model) }
                    TableColumn("Serial") { i in Text(i.serial) }
                    TableColumn("Band") { i in Text(i.band) }
                    TableColumn("Status") { i in
                        Text(i.status.rawValue).foregroundColor(i.status == .available ? .green
                                                                : i.status == .checkedOut ? .orange : .red)
                    }
                    TableColumn("With") { i in Text(i.holder) }
                }
                .frame(minWidth: 600)

                List {
                    Section("Totals") {
                        ForEach(inventory.summary) { s in
                            HStack { Text(s.name).lineLimit(1); Spacer(); Text("\(s.available)/\(s.total)").monospacedDigit() }
                        }
                        if inventory.items.isEmpty { Text("No equipment yet").foregroundStyle(.secondary) }
                    }
                    if showLog {
                        Section("Check-out log") {
                            ForEach(inventory.log.prefix(300)) { e in
                                VStack(alignment: .leading) {
                                    Text("\(e.action): \(e.itemName)").font(.caption.bold())
                                    Text("\(e.person.isEmpty ? "" : e.person + " · ")\(e.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 240, idealWidth: 280)
            }
        }
        .sheet(item: $editing) { item in
            InventoryEditor(item: item) { inventory.upsert($0) }
        }
    }
}

struct InventoryEditor: View {
    @State var item: InventoryItem
    var onSave: (InventoryItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Picker("Category", selection: $item.category) {
                ForEach(InventoryStore.categories, id: \.self) { Text($0).tag($0) }
            }
            TextField("Make", text: $item.make)
            TextField("Model", text: $item.model)
            TextField("Serial number", text: $item.serial)
            TextField("Label / asset tag", text: $item.label)
            TextField("Frequency band", text: $item.band)
            Picker("Status", selection: $item.status) {
                ForEach(ItemStatus.allCases) { Text($0.rawValue).tag($0) }
            }
            if item.status == .checkedOut { TextField("Checked out to", text: $item.holder) }
            TextField("Notes", text: $item.notes, axis: .vertical).lineLimit(2...5)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(item); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
