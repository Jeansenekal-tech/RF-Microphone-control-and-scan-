import SwiftUI
import AppKit
import WaveDeskCore

struct ProjectView: View {
    @EnvironmentObject var state: AppState
    @State private var newName = ""
    @State private var newVenue = ""

    var body: some View {
        HSplitView {
            Form {
                Section("This project") {
                    LabeledContent("Name", value: state.project.name)
                    TextField("Venue", text: $state.project.venue)
                    TextField("Notes", text: $state.project.notes, axis: .vertical).lineLimit(3...8)
                    HStack {
                        Button("Duplicate as…") {
                            if let n = Panels.prompt("Duplicate project", "New name:", default: state.project.name + " copy"),
                               !n.isEmpty { state.duplicateProject(as: n) }
                        }
                        Button("Export project file…") {
                            if let d = state.exportProjectData() {
                                Panels.save(d, suggestedName: state.project.name + ".wdproj", types: [Panels.projectType])
                            }
                        }
                        Button("Import project file…") {
                            if let url = Panels.open(types: [Panels.projectType, .json]).first {
                                do { try state.importProject(from: url) } catch { Panels.alert("Import failed", error.localizedDescription) }
                            }
                        }
                    }
                }

                Section("Region") {
                    Picker("Country / region", selection: $state.project.regionID) {
                        ForEach(RegionProfile.all) { Text($0.name).tag($0.id) }
                    }
                    let r = state.region
                    if r.hasChannels {
                        LabeledContent("TV channels",
                                       value: "Ch\(r.firstChannel)–\(r.lastChannel), \(Int(r.channelWidthMHz)) MHz wide")
                    }
                    ForEach(r.restricted) { b in
                        LabeledContent(b.label, value: String(format: "%.0f–%.0f MHz", b.lowMHz, b.highMHz))
                    }
                    if !r.notes.isEmpty { Text(r.notes).font(.caption).foregroundStyle(.secondary) }
                    Button("Use \(r.name) default range (\(Int(r.defaultStartMHz))–\(Int(r.defaultStopMHz)) MHz)") {
                        state.project.coord.startMHz = r.defaultStartMHz
                        state.project.coord.stopMHz = r.defaultStopMHz
                        state.analyzer.startMHz = r.defaultStartMHz
                        state.analyzer.stopMHz = r.defaultStopMHz
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 440)

            Form {
                Section("All projects") {
                    ForEach(state.projectNames, id: \.self) { name in
                        HStack {
                            Image(systemName: name == Storage.safeFileName(state.project.name) ? "folder.fill" : "folder")
                            Text(name)
                            Spacer()
                            if name != Storage.safeFileName(state.project.name) {
                                Button("Open") { state.openProject(name) }
                                Button(role: .destructive) {
                                    let a = NSAlert()
                                    a.messageText = "Delete project “\(name)”?"
                                    a.informativeText = "Its scans stay in the scan library."
                                    a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                                    if a.runModal() == .alertFirstButtonReturn { state.deleteProject(name) }
                                } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                            } else {
                                Text("open").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("New project") {
                    TextField("Name", text: $newName)
                    TextField("Venue", text: $newVenue)
                    Button("Create") {
                        state.newProject(newName, venue: newVenue)
                        newName = ""; newVenue = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Text("A new project starts empty. Use Duplicate to keep your receivers and groups.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Where things are saved") {
                    Text(Storage.root.path).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Storage.root]) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 320, idealWidth: 360)
        }
    }
}
