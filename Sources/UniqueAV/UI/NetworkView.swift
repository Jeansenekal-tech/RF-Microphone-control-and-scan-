import SwiftUI
import AppKit
import UniqueAVCore

/// Network page: which connection talks to the receivers, which one the phone monitor uses,
/// whether each receiver's IP is reachable, and a quick connection test.
struct NetworkView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var net = NetworkManager.shared
    @State private var testIP = ""
    @State private var testPort = "2202"
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionBox(title: "Receiver network") {
                    Text("Choose the connection your wireless receivers are plugged into. With Automatic, macOS picks the route by IP address – fine when the Mac is on one network. When it's on Wi-Fi and a show network at the same time, pick the show network here.")
                        .font(.caption).foregroundStyle(.secondary)
                    NetworkRow(title: "Automatic", subtitle: "Let macOS choose by IP address", symbol: "arrow.triangle.branch",
                               selected: net.receiverInterfaceID == nil) { net.receiverInterfaceID = nil }
                    ForEach(net.interfaces) { i in
                        NetworkRow(title: i.displayName, subtitle: "\(i.ipv4) · subnet \(i.subnet) · \(i.bsdName)",
                                   symbol: i.symbol, selected: net.receiverInterfaceID == i.id) {
                            net.receiverInterfaceID = i.id
                        }
                    }
                    if let id = net.receiverInterfaceID, net.receiverInterface == nil {
                        Label("The selected connection (\(id)) isn't connected right now – receivers can't be reached until it is, or choose Automatic.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange).font(.caption)
                    }
                    if net.interfaces.isEmpty {
                        Label("No network connection. Plug in Ethernet or join Wi-Fi.", systemImage: "wifi.slash")
                            .foregroundColor(.orange)
                    }
                    HStack {
                        Button("Refresh") { net.refresh() }
                        Button("Reconnect all receivers") { state.reconnectAll() }
                    }
                }

                SectionBox(title: "Phone monitor & Companion network") {
                    Text("The QR code and Companion URLs use this connection's address – pick the network your phone or Stream Deck computer is on (usually Wi-Fi).")
                        .font(.caption).foregroundStyle(.secondary)
                    PhoneNetworkPicker(net: net)
                }

                SectionBox(title: "Receivers") {
                    let networked = state.devices.filter { $0.kind.needsHost || (!$0.host.isEmpty && $0.kind.hasWebUI) }
                    if networked.isEmpty {
                        Text("No networked receivers in this project.").foregroundStyle(.secondary)
                    }
                    ForEach(networked) { d in ReceiverNetworkRow(device: d, net: net) }
                }

                SectionBox(title: "Test a connection") {
                    HStack {
                        TextField("IP address, e.g. 192.168.1.50", text: $testIP).frame(width: 220)
                        Picker("", selection: $testPort) {
                            Text("Shure (2202)").tag("2202")
                            Text("Web / EW-DX (443)").tag("443")
                            Text("Web (80)").tag("80")
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Button(testing ? "Testing…" : "Test") { runTest() }.disabled(testing || testIP.isEmpty)
                    }
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundColor(r.ok ? .green : .red)
                    }
                    if let i = IPv4.parse(testIP).flatMap({ _ in net.interface(containing: testIP) }) {
                        Text("\(testIP) is on \(i.displayName) (\(i.subnet)).").font(.caption).foregroundStyle(.secondary)
                    } else if IPv4.parse(testIP) != nil {
                        Text("\(testIP) isn't on any network this Mac is connected to – check the Mac's or the receiver's IP settings.")
                            .font(.caption).foregroundColor(.orange)
                    }
                    Text("Sennheiser G3/G4 and Digital 6000 use UDP, which can't be tested this way – check the receiver's status on the Devices page instead.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                SectionBox(title: "Permission") {
                    Text("macOS must allow this app to use the local network: System Settings › Privacy & Security › Local Network › Unique AV RF Scan Co-ord.")
                        .font(.caption)
                    Button("Open Privacy & Security settings") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(u) }
                    }
                }
            }
            .padding(14)
        }
        .onAppear { net.refresh() }
    }

    private func runTest() {
        testing = true
        testResult = nil
        net.test(ip: testIP.trimmingCharacters(in: .whitespaces), port: UInt16(testPort) ?? 2202) { ok, text in
            testing = false
            testResult = (ok, text)
        }
    }
}

struct NetworkRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                Image(systemName: symbol).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(selected ? .semibold : .regular))
                    Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

/// Picker for the phone-monitor network (also used on the Remote & Companion page).
struct PhoneNetworkPicker: View {
    @ObservedObject var net: NetworkManager

    var body: some View {
        if net.interfaces.count > 1 {
            Picker("Phone network", selection: Binding(
                get: { net.phoneInterface?.id ?? "" },
                set: { net.phoneInterfaceID = $0 })) {
                ForEach(net.interfaces) { i in Text("\(i.displayName) – \(i.ipv4)").tag(i.id) }
            }
        } else if let i = net.interfaces.first {
            Text("\(i.displayName) – \(i.ipv4)").font(.callout)
        }
    }
}

struct ReceiverNetworkRow: View {
    @ObservedObject var device: Device
    @ObservedObject var net: NetworkManager

    var body: some View {
        let iface = net.interface(containing: device.host)
        let wrongNet = net.receiverInterface != nil && iface != nil && iface?.id != net.receiverInterface?.id
        HStack(spacing: 8) {
            Circle().fill(device.online ? Color.green : Color.red).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(device.displayName) · \(device.host)").font(.callout)
                Group {
                    if IPv4.parse(device.host) == nil {
                        Text("Not an IP address – enter the receiver's IP (e.g. 192.168.1.50)").foregroundColor(.orange)
                    } else if let i = iface {
                        if wrongNet {
                            Text("On \(i.displayName), but the receiver network is set to \(net.receiverInterface?.displayName ?? "")")
                                .foregroundColor(.orange)
                        } else {
                            Text("On \(i.displayName) (\(i.subnet))").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not on any network this Mac is connected to – check cabling and IP settings")
                            .foregroundColor(.orange)
                    }
                }
                .font(.caption)
            }
            Spacer()
            Text(device.online ? "Connected" : device.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
