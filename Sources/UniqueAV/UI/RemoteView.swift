import SwiftUI
import AppKit

/// Web monitor (QR code), Bitfocus Companion / HTTP API settings, and software updates.
struct RemoteView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var remote: RemoteController
    @ObservedObject var updater: Updater
    @ObservedObject private var net = NetworkManager.shared

    var body: some View {
        let phone = net.phoneInterface
        let url = phone.map { remote.monitorURL(ip: $0.ipv4) }
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionBox(title: "Phone / tablet monitor") {
                        Toggle("Web server enabled", isOn: $remote.enabled)
                        HStack {
                            Text("Port")
                            TextField("", value: $remote.port, format: .number.grouping(.never)).frame(width: 70)
                            Text(remote.status).font(.caption).foregroundStyle(.secondary)
                        }
                        if remote.enabled {
                            if let url, let phone {
                                HStack(alignment: .top, spacing: 16) {
                                    if let img = RemoteController.qrCode(url) {
                                        Image(nsImage: img).interpolation(.none).resizable()
                                            .frame(width: 200, height: 200)
                                            .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Scan with the phone's camera").font(.headline)
                                        Text("The phone must be on the same network (Wi-Fi) as this Mac. The monitor shows every channel live: frequency, RF, audio, battery, alerts and the spectrum.")
                                            .font(.caption).foregroundStyle(.secondary)
                                        PhoneNetworkPicker(net: net)
                                        Text("Using \(phone.displayName) (\(phone.ipv4))").font(.caption)
                                        Text(url).font(.caption.monospaced()).textSelection(.enabled)
                                        HStack {
                                            Button("Copy link") {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(url, forType: .string)
                                            }
                                            Button("Open in browser") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                                        }
                                    }
                                }
                            } else {
                                Text("No network connection found.").foregroundColor(.orange)
                            }
                        }
                    }

                    SectionBox(title: "Access") {
                        HStack {
                            Text("Access key")
                            Text(remote.key).font(.body.monospaced()).textSelection(.enabled)
                            Button("New key") { remote.regenerateKey() }
                                .help("Old QR codes and Companion buttons stop working")
                        }
                        Toggle("Allow control (mute, gain, scan, apply frequencies)", isOn: $remote.allowControl)
                        Text("Off = the monitor and API are read-only. Anyone with the key on your network can use what's allowed here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Requests served: \(remote.requests)").font(.caption2).foregroundStyle(.secondary)
                    }

                    SectionBox(title: "Software update") {
                        HStack {
                            Text("\(AppInfo.name) \(Updater.currentVersion)")
                            Spacer()
                            Button(updater.busy ? "Checking…" : "Check now") { updater.check(userInitiated: true) }
                                .disabled(updater.busy)
                        }
                        Toggle("Check for updates automatically", isOn: $updater.autoCheck)
                        if let r = updater.available {
                            HStack {
                                Text("Version \(r.version) is available").foregroundColor(.accentColor)
                                Button("Install…") { updater.offer(r) }
                            }
                        }
                        if !updater.status.isEmpty { Text(updater.status).font(.caption).foregroundStyle(.secondary) }
                        if !updater.canInstall {
                            Text("Running outside an app bundle (swift run / Xcode): updates open the download page instead.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
            }
            .frame(minWidth: 460)

            CompanionGuide(base: phone.map { remote.baseURL(ip: $0.ipv4) } ?? "http://<mac-ip>:\(remote.port)", key: remote.key)
                .frame(minWidth: 380, idealWidth: 460)
        }
    }
}

/// Cheat-sheet for setting up Bitfocus Companion buttons (Generic HTTP module).
struct CompanionGuide: View {
    @EnvironmentObject var state: AppState
    let base: String
    let key: String

    private func url(_ path: String) -> String { "\(base)\(path)?key=\(key)" }

    var body: some View {
        let list = state.remote.channelList(state)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bitfocus Companion / Stream Deck").font(.title3.bold())
                Text("In Companion add a **Generic: HTTP Requests** connection. Use **GET** actions with the URLs below on your buttons. Read-only URLs return plain text, so they can feed Companion variables / feedbacks (e.g. a battery or mute indicator).")
                    .font(.callout)

                GroupBox("Actions (needs “Allow control”)") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Toggle mute ch 1", url("/api/ch/1/mute/toggle"))
                        row("Mute / unmute ch 1", url("/api/ch/1/mute/on") + "  ·  …/mute/off")
                        row("Gain up / down ch 1", url("/api/ch/1/gain/up") + "  ·  …/gain/down")
                        row("Start / stop / toggle scan", url("/api/scan/toggle"))
                        row("Find frequencies", url("/api/coordinate"))
                        row("Apply proposed frequencies", url("/api/apply"))
                    }
                }
                GroupBox("Values (plain text)") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Name / frequency", url("/api/ch/1/name") + "  ·  …/freq")
                        row("Battery bars / minutes", url("/api/ch/1/battery") + "  ·  …/batterymin")
                        row("RF dBm (best antenna) / audio dBFS", url("/api/ch/1/rf") + "  ·  …/audio")
                        row("Muted (1/0) / online (1/0)", url("/api/ch/1/mute") + "  ·  …/online")
                        row("Active alerts (all / channel)", url("/api/alerts/count") + "  ·  /api/ch/1/alerts")
                        row("Everything as JSON", url("/api/state"))
                    }
                }
                GroupBox("Channel numbers") {
                    VStack(alignment: .leading, spacing: 2) {
                        if list.isEmpty { Text("Add receivers to see their numbers.").foregroundStyle(.secondary) }
                        ForEach(list, id: \.n) { item in
                            HStack {
                                Text("\(item.n)").font(.body.monospacedDigit()).frame(width: 28, alignment: .trailing)
                                Text(state.label(item.device, item.channel))
                                Spacer()
                                Text(item.device.displayName).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                        Text("Numbers follow the order of receivers in the project; they change if you remove a receiver.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.bold())
            Text(value).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
        }
    }
}
