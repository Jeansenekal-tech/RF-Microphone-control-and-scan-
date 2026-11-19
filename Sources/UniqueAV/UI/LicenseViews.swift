import SwiftUI
import AppKit
import UniqueAVCore

/// Shown at launch until the app has a valid licence or trial.
struct LicenseGateView: View {
    @EnvironmentObject var license: LicenseManager
    @ObservedObject var updater: Updater
    @State private var key = ""
    @State private var showKeyField = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.18), Color(red: 0.09, green: 0.05, blue: 0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 120, height: 120)
                VStack(spacing: 2) {
                    Text("UNIQUE AV").font(.system(size: 30, weight: .heavy)).foregroundColor(.white)
                    Text("RF SCAN CO-ORD").font(.system(size: 13, weight: .semibold)).tracking(4)
                        .foregroundColor(.white.opacity(0.65))
                }
                card
                    .frame(width: 460)
                HStack(spacing: 16) {
                    Button("Check for updates") { updater.check(userInitiated: true) }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.link)
                .foregroundColor(.white.opacity(0.7))
                Text("This Mac: \(license.machineName)").font(.caption).foregroundColor(.white.opacity(0.45))
            }
            .padding(30)
        }
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch license.phase {
            case .checking, .developer, .licensed:
                HStack { ProgressView().controlSize(.small); Text("Checking licence…") }
            case .locked(let reason):
                Text(title(reason)).font(.title3.bold())
                Text(detail(reason)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions(reason)
            }
            if !license.message.isEmpty {
                Text(license.message).font(.callout).foregroundColor(.orange)
            }
            if license.busy { ProgressView().controlSize(.small) }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
    }

    @ViewBuilder private func actions(_ reason: LicenseManager.Reason) -> some View {
        switch reason {
        case .activeElsewhere:
            Button { license.moveHere() } label: { Label("Move licence to this Mac", systemImage: "arrow.right.circle.fill") }
                .buttonStyle(.borderedProminent).disabled(license.busy)
            keyEntry(label: "Use a different licence key")
        case .needsCheckIn, .offline, .clock, .wrongMachine:
            Button("Try again") { license.refresh() }.buttonStyle(.borderedProminent).disabled(license.busy)
            keyEntry(label: "Enter a licence key")
        case .suspended:
            buy
            keyEntry(label: "Enter a different licence key")
        case .expired:
            buy
            keyEntry(label: "I've bought a licence – enter key")
        case .none, .invalidKey, .error:
            if !BuildConfig.trialURL.isEmpty {
                Button { license.startTrial() } label: { Label("Start 60-day free trial", systemImage: "clock.badge.checkmark") }
                    .buttonStyle(.borderedProminent).disabled(license.busy)
            }
            keyEntry(label: "I have a licence key")
            buy
        }
    }

    @ViewBuilder private var buy: some View {
        if let url = URL(string: BuildConfig.purchaseURL), !BuildConfig.purchaseURL.isEmpty {
            Button { NSWorkspace.shared.open(url) } label: { Label("Buy a licence", systemImage: "cart") }
        }
    }

    @ViewBuilder private func keyEntry(label: String) -> some View {
        if showKeyField {
            HStack {
                TextField("Licence key", text: $key).textFieldStyle(.roundedBorder)
                Button("Activate") { license.activate(key: key) }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || license.busy)
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            Button(label) { showKeyField = true }.buttonStyle(.link)
        }
    }

    private func title(_ r: LicenseManager.Reason) -> String {
        switch r {
        case .none: return "Welcome"
        case .expired(let trial): return trial ? "Your 60-day trial has ended" : "Your licence has expired"
        case .activeElsewhere: return "Licence in use on another Mac"
        case .needsCheckIn: return "Licence check needed"
        case .offline: return "Can't reach the licence server"
        case .suspended: return "Licence suspended"
        case .invalidKey: return "Licence key not recognised"
        case .clock: return "Check your Mac's date and time"
        case .wrongMachine: return "Licence belongs to another Mac"
        case .error: return "Licence problem"
        }
    }

    private func detail(_ r: LicenseManager.Reason) -> String {
        switch r {
        case .none:
            return "Start a free 60-day trial (internet needed once), or activate your licence key. A licence works on one Mac at a time."
        case .expired(let trial):
            return trial ? "Thanks for trying the app! Buy a licence to keep using it on this Mac."
                         : "Renew your licence to keep using the app."
        case .activeElsewhere(let m):
            return "This licence is activated on \(m.map { "“\($0)”" } ?? "another Mac"). If that Mac is lost, broken or you've replaced it, move the licence here – the other Mac will be locked the next time it checks in (or after \(LicenseManager.offlineDays) days offline)."
        case .needsCheckIn:
            return "The app works offline for \(LicenseManager.offlineDays) days at a time. Connect this Mac to the internet so the licence can be verified."
        case .offline:
            return "Connect to the internet and try again."
        case .suspended:
            return "This licence has been suspended. Please contact Unique AV."
        case .invalidKey:
            return "Check the key in your purchase email and try again."
        case .clock:
            return "The clock seems to have been set back. Turn on “Set time and date automatically” in System Settings › General › Date & Time, then try again."
        case .wrongMachine:
            return "The saved licence file is for a different Mac. Try again to activate this Mac."
        case .error(let e):
            return e
        }
    }
}

/// Licence details on the Project page.
struct LicenseSection: View {
    @EnvironmentObject var license: LicenseManager

    var body: some View {
        Section("Licence") {
            switch license.phase {
            case .developer:
                Text("Developer build – licensing is not enabled.").foregroundStyle(.secondary)
            default:
                if license.isTrial, let d = license.daysLeft {
                    LabeledContent("Status", value: "Trial – \(d) day\(d == 1 ? "" : "s") left")
                } else {
                    LabeledContent("Status", value: statusText)
                }
                LabeledContent("Key", value: license.maskedKey)
                LabeledContent("This Mac", value: license.machineName)
                if let until = license.offlineUntil {
                    LabeledContent("Works offline until", value: until.formatted(date: .abbreviated, time: .omitted))
                }
                HStack {
                    Button("Check now") { license.refresh() }.disabled(license.busy)
                    if license.isTrial, let url = URL(string: BuildConfig.purchaseURL), !BuildConfig.purchaseURL.isEmpty {
                        Button("Buy a licence") { NSWorkspace.shared.open(url) }
                    }
                    Spacer()
                    Button("Deactivate this Mac…", role: .destructive) { confirmDeactivate() }.disabled(license.busy)
                }
                Text("Moving to a new Mac? Deactivate here first – or, if this Mac is lost or broken, choose “Move licence to this Mac” on the new one.")
                    .font(.caption).foregroundStyle(.secondary)
                if !license.message.isEmpty { Text(license.message).font(.caption).foregroundColor(.orange) }
            }
        }
    }

    private var statusText: String {
        switch license.phase {
        case .licensed: return "Licensed"
        case .checking: return "Checking…"
        case .locked: return "Problem – will lock on next launch"
        case .developer: return "Developer build"
        }
    }

    private func confirmDeactivate() {
        let a = NSAlert()
        a.messageText = "Deactivate this Mac?"
        a.informativeText = "The licence is released so you can activate it on another Mac. This app will lock the next time it starts."
        a.addButton(withTitle: "Deactivate")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { license.deactivate { _ in } }
    }
}

/// Toolbar badge during the trial.
struct TrialBadge: View {
    @ObservedObject var license: LicenseManager
    var body: some View {
        if license.isTrial, let d = license.daysLeft {
            Button {
                if let url = URL(string: BuildConfig.purchaseURL), !BuildConfig.purchaseURL.isEmpty { NSWorkspace.shared.open(url) }
            } label: {
                Label("Trial: \(d) day\(d == 1 ? "" : "s") left", systemImage: "clock")
                    .foregroundColor(d <= 7 ? .orange : .secondary)
            }
            .help("Buy a licence")
        }
    }
}
