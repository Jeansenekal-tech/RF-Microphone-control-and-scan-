import SwiftUI
import AppKit

struct TelemetryTimelineView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var telemetry: TelemetryStore
    @State private var window: TimeInterval = 300
    @State private var filter = ""
    @State private var hoverT: TimeInterval?
    @State private var paused = false
    @State private var frozenEnd: TimeInterval = 0

    private let windows: [(String, TimeInterval)] = [("1 min", 60), ("5 min", 300), ("15 min", 900),
                                                     ("1 hour", 3600), ("4 hours", 14400), ("12 hours", 43200)]

    var body: some View {
        let _ = telemetry.revision   // redraw every second
        let end = paused ? frozenEnd : Date().timeIntervalSince1970
        let keys = telemetry.labels.keys
            .filter { filter.isEmpty || (telemetry.labels[$0] ?? "").localizedCaseInsensitiveContains(filter) }
            .sorted { (telemetry.labels[$0] ?? "") < (telemetry.labels[$1] ?? "") }

        VStack(spacing: 0) {
            HStack {
                Picker("Window", selection: $window) {
                    ForEach(windows.indices, id: \.self) { i in Text(windows[i].0).tag(windows[i].1) }
                }
                .frame(width: 180)
                Toggle("Pause", isOn: Binding(get: { paused }, set: { paused = $0; frozenEnd = Date().timeIntervalSince1970 }))
                    .toggleStyle(.button)
                TextField("Filter channels", text: $filter).frame(width: 180)
                Spacer()
                HStack(spacing: 10) {
                    Label("RF", systemImage: "circle.fill").foregroundColor(.blue)
                    Label("Audio", systemImage: "circle.fill").foregroundColor(.green)
                    Label("Offline", systemImage: "square.fill").foregroundColor(.red.opacity(0.5))
                    Label("Event", systemImage: "line.diagonal").foregroundColor(.orange)
                }
                .font(.caption)
                Button("Export CSV…") {
                    Panels.save(Data(telemetry.csv().utf8), suggestedName: "\(state.project.name) telemetry.csv",
                                types: [.commaSeparatedText])
                }
                Button("Clear") { telemetry.clear() }
            }
            .padding(8)
            Divider()
            if keys.isEmpty {
                Text("Telemetry is recorded every second once receivers are connected.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(keys, id: \.self) { key in
                            TelemetryRow(label: telemetry.labels[key] ?? key,
                                         samples: telemetry.series[key] ?? [],
                                         events: telemetry.events.filter { $0.key == key }.map { $0.t },
                                         start: end - window, end: end, hoverT: $hoverT)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }
}

struct TelemetryRow: View {
    let label: String
    let samples: [TelemetrySample]
    let events: [TimeInterval]
    let start: TimeInterval
    let end: TimeInterval
    @Binding var hoverT: TimeInterval?

    private static let tf: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.bold()).lineLimit(1)
                if let t = hoverT, let s = sample(at: t) {
                    Text(Self.tf.string(from: Date(timeIntervalSince1970: s.t))).font(.caption2.monospacedDigit())
                    Text("RF \(s.rf == TelemetryStore.none ? "—" : "\(s.rf) dBm")").font(.caption2)
                    Text("AF \(s.audio == TelemetryStore.none ? "—" : "\(s.audio) dBFS")").font(.caption2)
                    Text("Batt \(s.batt < 0 ? "—" : "\(s.batt)/5")").font(.caption2)
                } else if let s = samples.last {
                    Text("Batt \(s.batt < 0 ? "—" : "\(s.batt)/5")").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)

            GeometryReader { g in
                Canvas { ctx, size in draw(ctx, size) }
                    .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 6))
                    .onContinuousHover { phase in
                        if case .active(let p) = phase, g.size.width > 0 {
                            hoverT = start + Double(p.x / g.size.width) * (end - start)
                        } else {
                            hoverT = nil
                        }
                    }
            }
            .frame(height: 70)
        }
    }

    private func firstIndex(atOrAfter t: TimeInterval) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < t { lo = m + 1 } else { hi = m } }
        return lo
    }

    private func sample(at t: TimeInterval) -> TelemetrySample? {
        let i = firstIndex(atOrAfter: t)
        let c = [i - 1, i].filter { $0 >= 0 && $0 < samples.count }
        guard let best = c.min(by: { abs(samples[$0].t - t) < abs(samples[$1].t - t) }),
              abs(samples[best].t - t) < 5 else { return nil }
        return samples[best]
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let span = max(1, end - start)
        func x(_ t: TimeInterval) -> CGFloat { CGFloat((t - start) / span) * size.width }
        func yRF(_ v: Int16) -> CGFloat { size.height * (1 - CGFloat((Double(v) + 100) / 80).clamped()) }
        func yAF(_ v: Int16) -> CGFloat { size.height * (1 - CGFloat((Double(v) + 50) / 50).clamped()) }

        let i0 = max(0, firstIndex(atOrAfter: start) - 1)
        let visible = i0 < samples.count ? Array(samples[i0...]) : []
        let stride = max(1, visible.count / max(1, Int(size.width)))

        // offline shading
        for s in visible where !s.online {
            ctx.fill(Path(CGRect(x: x(s.t), y: 0, width: max(1, size.width / CGFloat(span)), height: size.height)),
                     with: .color(.red.opacity(0.35)))
        }
        var rf = Path(), af = Path()
        var rfOn = false, afOn = false
        var i = 0
        while i < visible.count {
            // take min RF / max audio within the stride so dropouts and peaks stay visible
            let chunk = visible[i..<min(visible.count, i + stride)]
            let t = chunk.first!.t
            let rfs = chunk.map(\.rf).filter { $0 != TelemetryStore.none }
            let afs = chunk.map(\.audio).filter { $0 != TelemetryStore.none }
            if let v = rfs.min() {
                let p = CGPoint(x: x(t), y: yRF(v))
                if rfOn { rf.addLine(to: p) } else { rf.move(to: p); rfOn = true }
            } else { rfOn = false }
            if let v = afs.max() {
                let p = CGPoint(x: x(t), y: yAF(v))
                if afOn { af.addLine(to: p) } else { af.move(to: p); afOn = true }
            } else { afOn = false }
            i += stride
        }
        ctx.stroke(af, with: .color(.green.opacity(0.8)), lineWidth: 1)
        ctx.stroke(rf, with: .color(.blue), lineWidth: 1.3)

        for t in events where t >= start && t <= end {
            ctx.stroke(Path { $0.move(to: CGPoint(x: x(t), y: 0)); $0.addLine(to: CGPoint(x: x(t), y: size.height)) },
                       with: .color(.orange), lineWidth: 1.5)
        }
        if let h = hoverT {
            ctx.stroke(Path { $0.move(to: CGPoint(x: x(h), y: 0)); $0.addLine(to: CGPoint(x: x(h), y: size.height)) },
                       with: .color(.white.opacity(0.6)), lineWidth: 1)
        }
    }
}

private extension CGFloat {
    func clamped() -> CGFloat { Swift.max(0, Swift.min(1, self)) }
}
