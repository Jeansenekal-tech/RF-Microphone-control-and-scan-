import SwiftUI
import AppKit
import UniqueAVCore

/// Time-of-use: groups of channels that are only on air at certain times.
struct GroupsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Groups that are never on air at the same time can share frequencies. Coordination and the conflict check only compare transmitters whose time slots overlap. Channels without a group are treated as on air all day.")
                    .font(.callout).foregroundStyle(.secondary)

                SectionBox(title: "Schedule") {
                    ScheduleChart(groups: state.project.groups).frame(height: CGFloat(28 + 22 * max(1, state.project.groups.count)))
                }

                SectionBox(title: "Groups") {
                    ForEach($state.project.groups) { $g in GroupRow(group: $g) }
                    Button { state.addGroup(name: "Group \(state.project.groups.count + 1)") } label: {
                        Label("Add group", systemImage: "plus")
                    }
                }

                SectionBox(title: "Assign channels") {
                    if state.devices.isEmpty { Text("Add receivers first.").foregroundStyle(.secondary) }
                    ForEach(state.devices) { d in GroupAssignRows(device: d) }
                }
            }
            .padding(14)
        }
    }
}

struct GroupRow: View {
    @EnvironmentObject var state: AppState
    @Binding var group: UsageGroup
    @State private var slotText = ""
    @State private var bad = false

    var body: some View {
        HStack {
            Menu {
                ForEach(0..<Palette.groups.count, id: \.self) { i in
                    Button { group.colorIndex = i } label: { Text("Colour \(i + 1)") }
                }
            } label: {
                Circle().fill(Palette.group(group.colorIndex)).frame(width: 14, height: 14)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            TextField("Name", text: $group.name).frame(width: 160)
            TextField("Times, e.g. 18:00-19:30, 21:00-23:00 (empty = all day)", text: $slotText, onCommit: commit)
                .foregroundColor(bad ? .red : .primary)
            Button("Set") { commit() }
            Button(role: .destructive) { state.deleteGroup(group.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .onAppear { slotText = Schedule.format(group.slots) }
    }

    private func commit() {
        let trimmed = slotText.trimmingCharacters(in: .whitespaces)
        let slots = Schedule.parseSlots(trimmed)
        bad = !trimmed.isEmpty && slots.isEmpty
        if !bad {
            group.slots = slots
            slotText = Schedule.format(slots)
        }
    }
}

struct GroupAssignRows: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var device: Device

    var body: some View {
        ForEach(device.channels) { c in
            HStack {
                Text(state.label(device, c)).frame(width: 180, alignment: .leading).lineLimit(1)
                Text(fmtMHz(c.freqKHz)).font(.callout.monospacedDigit()).frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(
                    get: { state.plan(device, c.idx).groupID },
                    set: { var p = state.plan(device, c.idx); p.groupID = $0; state.setPlan(device, c.idx, p) })) {
                    Text("Always on air").tag(UUID?.none)
                    ForEach(state.project.groups) { g in Text(g.name).tag(UUID?.some(g.id)) }
                }
                .labelsHidden()
                .frame(width: 200)
                Spacer()
            }
        }
    }
}

/// 24-hour bars for every group, like a show running order.
struct ScheduleChart: View {
    let groups: [UsageGroup]

    var body: some View {
        Canvas { ctx, size in
            let left: CGFloat = 110
            let w = size.width - left - 6
            func x(_ m: Int) -> CGFloat { left + CGFloat(m) / 1440 * w }
            for h in stride(from: 0, through: 24, by: 2) {
                let xx = x(h * 60)
                ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: 0)); $0.addLine(to: CGPoint(x: xx, y: size.height - 14)) },
                           with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                ctx.draw(Text(String(format: "%02d", h % 24)).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: xx, y: size.height - 2), anchor: .bottom)
            }
            for (i, g) in groups.enumerated() {
                let y = 4 + CGFloat(i) * 22
                ctx.draw(Text(g.name).font(.system(size: 11)), at: CGPoint(x: 0, y: y + 8), anchor: .leading)
                let ivs = g.slots.isEmpty ? [0..<1440] : g.slots.flatMap(\.intervals)
                for r in ivs {
                    let rect = CGRect(x: x(r.lowerBound), y: y, width: max(2, x(r.upperBound) - x(r.lowerBound)), height: 16)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                             with: .color(Palette.group(g.colorIndex).opacity(g.slots.isEmpty ? 0.35 : 0.8)))
                }
            }
            if groups.isEmpty {
                ctx.draw(Text("No groups yet").foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: 12))
            }
        }
    }
}
