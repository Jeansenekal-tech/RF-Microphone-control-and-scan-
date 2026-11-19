import SwiftUI
import AppKit

struct DevicesView: View {
    @EnvironmentObject var state: AppState
    @State private var kind: DeviceKind = .shure
    @State private var host = ""
    @State private var nickname = ""
    @State private var password = ""

    var body: some View {
        HSplitView {
            List {
                Section("Receivers in this project") {
                    if state.devices.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(state.devices) { d in DeviceRow(device: d) }
                }
            }
            .frame(minWidth: 420)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionBox(title: "Add receiver") {
                        Picker("Type", selection: $kind) {
                            ForEach(DeviceKind.allCases) { Text($0.title).tag($0) }
                        }
                        if kind.needsHost {
                            TextField("IP address (e.g. 192.168.1.50)", text: $host)
                        }
                        TextField("Nickname (optional)", text: $nickname)
                        if kind.needsPassword {
                            SecureField("SSCv2 password", text: $password)
                            Text("Enable third-party / SSCv2 access on the EW-DX receiver and set this password first.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Add") {
                            state.addDevice(kind: kind, host: host, nickname: nickname,
                                            password: kind.needsPassword ? password : nil)
                            host = ""; nickname = ""; password = ""
                        }
                        .disabled(kind.needsHost && host.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                        Text(help(kind)).font(.caption).foregroundStyle(.secondary)
                    }

                    SectionBox(title: "Find Shure receivers on this network") {
                        HStack {
                            Button(state.discovering ? "Searching…" : "Search") { state.discoverShure() }
                                .disabled(state.discovering)
                            if state.discovering { ProgressView().controlSize(.small) }
                        }
                        ForEach(state.discovered, id: \.self) { ip in
                            HStack {
                                Text(ip).font(.body.monospacedDigit())
                                Spacer()
                                Button("Add") { state.addDevice(kind: .shure, host: ip, nickname: "") }
                            }
                        }
                        if !state.discovering && state.discovered.isEmpty {
                            Text("Checks every address on your local subnet for Shure's control port (TCP 2202). Sennheiser receivers need their IP entered manually (see the receiver's network menu).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    SectionBox(title: "Network tips") {
                        Text("""
                        • Put the Mac on the same wired network/subnet as the receivers (a dedicated switch is best).
                        • Give receivers fixed IPs, or note the DHCP addresses from their front panel.
                        • The first time, macOS asks to allow WaveDesk to find devices on your local network – click Allow \
                        (System Settings › Privacy & Security › Local Network).
                        """)
                        .font(.caption)
                    }
                }
                .padding(12)
            }
            .frame(minWidth: 340, idealWidth: 380)
        }
    }

    private func help(_ k: DeviceKind) -> String {
        switch k {
        case .shure: return "ULX-D, QLX-D, SLX-D, Axient Digital (and other Shure receivers using command strings on TCP 2202). Name, frequency, gain, mute, RF/audio meters, battery."
        case .sennheiserG4: return "ew G3 / G4, 2000 and 9000 series over UDP 53212. Name, frequency, mute, AF out, RF/AF meters, battery."
        case .sennheiserEWDX: return "EW-DX EM 2 / EM 4 via Sennheiser's SSCv2 API (HTTPS). Experimental – please report what works."
        case .sennheiserSSC: return "Digital 6000 via SSC (JSON over UDP 45). Experimental."
        case .demo: return "A simulated 4-channel receiver for trying the app without hardware."
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var device: Device
    @State private var nick = ""

    var body: some View {
        HStack(alignment: .top) {
            Circle().fill(device.online ? Color.green : Color.red).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Nickname", text: $nick, onCommit: { state.rename(device, nickname: nick) })
                    .textFieldStyle(.plain).font(.headline)
                Text("\(device.kind.short)\(device.model.isEmpty ? "" : " · \(device.model)")\(device.kind.needsHost ? " · \(device.host)" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(device.status).font(.caption2).foregroundStyle(device.online ? Color.secondary : Color.red)
                Text("\(device.channels.count) channel(s)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) { state.remove(device) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove from project")
        }
        .padding(.vertical, 4)
        .onAppear { nick = device.displayName }
    }
}
