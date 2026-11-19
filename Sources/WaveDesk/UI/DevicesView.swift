import SwiftUI
import AppKit
import WaveDeskCore

struct DevicesView: View {
    @EnvironmentObject var state: AppState
    @State private var kind: DeviceKind = .shure
    @State private var host = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var model = ""
    @State private var channelCount = 2
    @State private var tuneLow = ""
    @State private var tuneHigh = ""
    @State private var tuneStep = ""

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
                        } else if kind.hasWebUI {
                            TextField("IP address (optional – opens the receiver's web app)", text: $host)
                        }
                        if kind.isManual {
                            TextField("Model (e.g. \(modelExample(kind)))", text: $model)
                            Stepper("Channels: \(channelCount)", value: $channelCount, in: 1...16)
                        }
                        TuningFields(low: $tuneLow, high: $tuneHigh, step: $tuneStep)
                        TextField("Nickname (optional)", text: $nickname)
                        if kind.needsPassword {
                            SecureField("SSCv2 password", text: $password)
                            Text("Enable third-party / SSCv2 access on the EW-DX receiver and set this password first.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Add") {
                            state.addDevice(kind: kind, host: host, nickname: nickname,
                                            password: kind.needsPassword ? password : nil,
                                            model: model.isEmpty ? nil : model, channelCount: channelCount,
                                            tuneLowMHz: Double(tuneLow.replacingOccurrences(of: ",", with: ".")),
                                            tuneHighMHz: Double(tuneHigh.replacingOccurrences(of: ",", with: ".")),
                                            tuneStepKHz: Int(tuneStep))
                            host = ""; nickname = ""; password = ""; model = ""
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
                            Text("Checks every address on your local subnet for Shure's control port (TCP 2202). UHF-R and Sennheiser receivers need their IP entered manually (see the receiver's network menu).")
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

    private func modelExample(_ k: DeviceKind) -> String {
        switch k {
        case .wisycom: return "MRK16"
        case .soundDevices: return "A20-Nexus"
        case .deity: return "THEOS D4RX"
        default: return ""
        }
    }

    private func help(_ k: DeviceKind) -> String {
        switch k {
        case .shure: return "ULX-D, QLX-D, SLX-D, Axient Digital (and other Shure receivers using command strings on TCP 2202). Name, frequency, gain, mute, RF/audio meters, battery."
        case .shureUHFR: return "UR4S / UR4D over the rear Ethernet port (UDP 2202, asterisk command strings). Name, frequency, gain, battery, RF/audio meters. Enter the IP shown in the receiver's network menu – UHF-R isn't found by Search."
        case .sennheiserG4: return "ew G3 / G4, 2000 and 9000 series over UDP 53212. Name, frequency, mute, AF out, RF/AF meters, battery."
        case .sennheiserEWDX: return "EW-DX EM 2 / EM 4 via Sennheiser's SSCv2 API (HTTPS). Experimental – please report what works."
        case .sennheiserSSC: return "Digital 6000 via SSC (JSON over UDP 45). Experimental."
        case .wisycom: return "Wisycom doesn't publish a control protocol (its Wisycom Manager software is the only controller), so channels are entered by hand. They're still part of coordination, conflict checks, the spectrum and the monitor – set new frequencies on the receiver yourself."
        case .soundDevices: return "Sound Devices Astral has no public control API. Enter channels by hand; give the IP to open the A20-Nexus web app from WaveDesk. Coordinated frequencies are set on the receiver (or in its web app / Wingman)."
        case .deity: return "Deity THEOS receivers have no network port (control is via Bluetooth in the Sidus Audio app), so channels are entered by hand. Set new frequencies in the app or on the receiver."
        case .demo: return "A simulated 4-channel receiver for trying the app without hardware."
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var device: Device
    @State private var nick = ""
    @State private var editingTuning = false

    private var tuningText: String {
        guard let t = device.tuning else { return "" }
        var parts: [String] = []
        if let l = t.lowKHz, let h = t.highKHz { parts.append(String(format: " · tunes %.3f–%.3f MHz", Double(l) / 1000, Double(h) / 1000)) }
        if let st = t.stepKHz { parts.append(" · \(st) kHz steps") }
        return parts.joined()
    }

    var body: some View {
        HStack(alignment: .top) {
            Circle().fill(device.online ? Color.green : Color.red).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Nickname", text: $nick, onCommit: { state.rename(device, nickname: nick) })
                    .textFieldStyle(.plain).font(.headline)
                Text("\(device.kind.short)\(device.model.isEmpty ? "" : " · \(device.model)")\(device.kind.needsHost ? " · \(device.host)" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(device.status).font(.caption2).foregroundStyle(device.online ? Color.secondary : Color.red)
                Text("\(device.channels.count) channel(s)\(tuningText)").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Tuning range…") { editingTuning = true }
                    if let m = device as? ManualDevice {
                        Button("+ Channel") { m.addChannel() }.disabled(device.channels.count >= 16)
                        Button("− Channel") { m.removeLastChannel() }.disabled(device.channels.count <= 1)
                    }
                    if device.kind.hasWebUI, !device.host.isEmpty, let u = URL(string: "http://\(device.host)") {
                        Button("Open web control") { NSWorkspace.shared.open(u) }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
            Button(role: .destructive) { state.remove(device) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove from project")
        }
        .padding(.vertical, 4)
        .onAppear { nick = device.displayName }
        .popover(isPresented: $editingTuning) { TuningEditor(device: device).environmentObject(state) }
    }
}

/// Optional tuning range + step, so coordination only proposes frequencies the receiver supports.
struct TuningFields: View {
    @Binding var low: String
    @Binding var high: String
    @Binding var step: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tuning range (optional)").font(.caption.bold())
            HStack {
                TextField("from MHz", text: $low).frame(width: 80)
                Text("–")
                TextField("to MHz", text: $high).frame(width: 80)
                TextField("step kHz", text: $step).frame(width: 70)
            }
            Text("e.g. Shure G50 band 470–534, step 25. Leave empty to use the coordination range.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct TuningEditor: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var low = ""
    @State private var high = ""
    @State private var step = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(device.displayName).font(.headline)
            TuningFields(low: $low, high: $high, step: $step)
            HStack {
                Spacer()
                Button("Clear") { low = ""; high = ""; step = "" }
                Button("Save") {
                    state.setTuning(device, low: Double(low.replacingOccurrences(of: ",", with: ".")),
                                    high: Double(high.replacingOccurrences(of: ",", with: ".")), step: Int(step))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            low = device.tuneLowMHz.map { String($0) } ?? ""
            high = device.tuneHighMHz.map { String($0) } ?? ""
            step = device.tuneStepKHz.map { String($0) } ?? ""
        }
    }
}
