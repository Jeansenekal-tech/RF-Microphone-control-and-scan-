import SwiftUI
import AppKit
import UniqueAVCore

struct ChannelGrid: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.devices.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("No receivers yet").font(.headline)
                Text("Add your Shure or Sennheiser receivers under Devices, or try a demo receiver.")
                    .foregroundStyle(.secondary)
                Button("Add demo receiver") { state.addDevice(kind: .demo, host: "", nickname: "Demo rack") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                    ForEach(state.devices) { d in DeviceCards(device: d) }
                }
                .padding(10)
            }
        }
    }
}

struct DeviceCards: View {
    @ObservedObject var device: Device
    var body: some View {
        ForEach(device.channels) { c in ChannelCard(device: device, idx: c.idx) }
    }
}

struct ChannelCard: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var device: Device
    let idx: Int
    @State private var editing = false

    private var key: String { AppState.key(device, idx) }

    var body: some View {
        let c = device.channel(idx) ?? ChannelState(idx: idx)
        let alerts = state.health.activeAlerts(for: key)
        let critical = alerts.contains { $0.severity == .critical }
        let plan = state.plan(device, idx)
        let group = state.group(plan.groupID)
        let supported = device.kind.supported

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(device.online ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(state.label(device, c)).font(.headline).lineLimit(1)
                Spacer()
                if let g = group {
                    Text(g.name).font(.caption2).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.group(g.colorIndex).opacity(0.3), in: Capsule())
                }
                Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("Edit channel")
            }
            Text("\(device.displayName) · \(device.kind.short) ch \(idx)\(c.txType.isEmpty ? "" : " · \(c.txType)")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            Text(fmtMHz(c.freqKHz))
                .font(.system(size: 21, weight: .semibold, design: .monospaced))
                .foregroundColor(state.conflictsFor(state.label(device, c)).isEmpty ? .primary : .red)

            if let p = state.proposals[key] {
                HStack {
                    Text("→ \(fmtMHz(p))").font(.callout.monospacedDigit()).foregroundColor(.accentColor)
                    Spacer()
                    Button(device.kind.isManual ? "Done" : "Apply") { state.applyProposal(key) }
                        .controlSize(.small)
                        .help(device.kind.isManual ? "Set this frequency on the receiver, then click Done" : "Send to the receiver")
                }
                if device.kind.isManual {
                    Text("Set this on the \(device.kind.short) receiver by hand").font(.caption2).foregroundStyle(.orange)
                }
            }
            if device.kind.isManual {
                Label("Manual entry – not network controlled", systemImage: "hand.point.up.left")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            MeterBar(label: "RF A", value: c.rfA, lo: -100, hi: -20, color: c.antenna.contains("A") ? .blue : .blue.opacity(0.5))
            MeterBar(label: "RF B", value: c.rfB, lo: -100, hi: -20, color: c.antenna.contains("B") ? .blue : .blue.opacity(0.5))
            MeterBar(label: "AF", value: c.audio, lo: -50, hi: 0, color: (c.audio ?? -99) >= -3 ? .red : .green)

            HStack(spacing: 8) {
                BatteryView(bars: c.battBars)
                if let m = c.battMin { Text("\(m / 60)h \(m % 60)m").font(.caption.monospacedDigit()) }
                Spacer()
                if supported.contains(.gain), let g = c.gain {
                    Stepper(onIncrement: { device.set(.gain(g + 1), channel: idx) },
                            onDecrement: { device.set(.gain(g - 1), channel: idx) }) {
                        Text("\(g) dB").font(.caption.monospacedDigit())
                    }
                    .controlSize(.small)
                }
                if supported.contains(.mute) {
                    Button {
                        device.set(.mute(!(c.mute ?? false)), channel: idx)
                    } label: {
                        Image(systemName: c.mute == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(c.mute == true ? .red : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(c.mute == true ? "Unmute" : "Mute")
                }
            }

            HStack {
                Toggle("Coordinate", isOn: Binding(
                    get: { state.plan(device, idx).include },
                    set: { var p = state.plan(device, idx); p.include = $0; state.setPlan(device, idx, p) }))
                Toggle("Lock", isOn: Binding(
                    get: { state.plan(device, idx).locked },
                    set: { var p = state.plan(device, idx); p.locked = $0; state.setPlan(device, idx, p) }))
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            ForEach(alerts.prefix(3)) { a in
                Label(a.title, systemImage: a.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(Palette.severity(a.severity))
                    .lineLimit(1)
                    .help(a.detail)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(critical ? Color.red : (state.selectedChannel == key ? Color.accentColor : Color.primary.opacity(0.1)),
                    lineWidth: critical || state.selectedChannel == key ? 2 : 1))
        .onTapGesture { state.selectedChannel = key }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            ChannelEditor(device: device, idx: idx).environmentObject(state)
        }
    }
}

struct ChannelEditor: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var device: Device
    let idx: Int
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var freq = ""
    @State private var groupID: UUID?
    @State private var error = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Frequency (MHz)", text: $freq)
            Picker("Time-of-use group", selection: $groupID) {
                Text("Always on air").tag(UUID?.none)
                ForEach(state.project.groups) { g in Text(g.name).tag(UUID?.some(g.id)) }
            }
            if !error.isEmpty { Text(error).foregroundColor(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            let c = device.channel(idx)
            name = c?.name ?? ""
            freq = c?.freqKHz.map { String(format: "%.3f", Double($0) / 1000) } ?? ""
            groupID = state.plan(device, idx).groupID
        }
    }

    private func apply() {
        let c = device.channel(idx)
        let cleanFreq = freq.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if !cleanFreq.isEmpty {
            guard let mhz = Double(cleanFreq), mhz > 30, mhz < 3000 else { error = "Enter the frequency in MHz, e.g. 538.125"; return }
            let k = Int((mhz * 1000).rounded())
            if k != c?.freqKHz { device.set(.frequency(k), channel: idx) }
        }
        if name != c?.name { device.set(.name(name), channel: idx) }
        var p = state.plan(device, idx)
        p.groupID = groupID
        state.setPlan(device, idx, p)
        dismiss()
    }
}
