import SwiftUI
import AppKit

struct HealthView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var health: HealthMonitor

    var body: some View {
        HSplitView {
            List {
                Section("Active (\(health.active.count))") {
                    if health.active.isEmpty {
                        Label("Everything looks healthy", systemImage: "checkmark.seal.fill").foregroundColor(.green)
                    }
                    ForEach(health.active) { a in AlertRow(alert: a) }
                }
                Section {
                    ForEach(health.history.prefix(200)) { a in AlertRow(alert: a) }
                } header: {
                    HStack {
                        Text("History")
                        Spacer()
                        Button("Clear") { health.clearHistory() }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            .frame(minWidth: 420)

            Form {
                Section("Health check") {
                    Toggle("Enabled", isOn: $state.project.health.enabled)
                    Toggle("Mac notifications", isOn: $state.project.health.notify)
                    Toggle("Beep on critical alerts", isOn: $state.project.health.sound)
                }
                Section("Thresholds") {
                    Stepper("Low RF below \(state.project.health.rfMinDBm) dBm",
                            value: $state.project.health.rfMinDBm, in: -110...(-50))
                    Stepper("Battery warning at \(state.project.health.battBarsWarn) bar(s)",
                            value: $state.project.health.battBarsWarn, in: 0...3)
                    Stepper("…or under \(state.project.health.battMinutesWarn) minutes",
                            value: $state.project.health.battMinutesWarn, in: 0...240, step: 5)
                    Stepper("Audio clip at \(state.project.health.audioClipDBFS) dBFS",
                            value: $state.project.health.audioClipDBFS, in: -12...0)
                    HStack {
                        Text("Interference in reference scan above")
                        Slider(value: $state.project.health.interferenceDBm, in: -110...(-50), step: 1)
                        Text("\(Int(state.project.health.interferenceDBm)) dBm").monospacedDigit().frame(width: 60)
                    }
                }
                Section("What is checked") {
                    Text("""
                    • Receiver offline / not answering
                    • Low RF while a transmitter is on
                    • Low battery (bars or minutes)
                    • Audio clipping
                    • Frequency inside a restricted band for the selected region
                    • Spacing and intermod conflicts (respecting time-of-use groups)
                    • A signal at the channel's frequency in an overlay / reference scan \
                    (take reference scans with your own transmitters switched off)
                    """).font(.caption)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 340, idealWidth: 380)
        }
    }
}

struct AlertRow: View {
    let alert: HealthAlert
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(alert.ended == nil ? Palette.severity(alert.severity) : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.callout.bold())
                Text(alert.detail).font(.caption).foregroundStyle(.secondary)
                if let e = alert.ended {
                    Text("\(alert.since.formatted(date: .omitted, time: .standard)) – \(e.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("since \(alert.since.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
