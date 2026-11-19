import SwiftUI
import AppKit
import WaveDeskCore

struct SpectrumView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var analyzer: AnalyzerController
    @State private var hover: CGPoint?

    static let leftInset: CGFloat = 44
    static let rightInset: CGFloat = 10
    let dbTop = -20.0
    let dbBottom = -120.0

    /// Frequency range shown: the scanned grid if there is data, otherwise the sweep settings.
    private var range: (lo: Double, hi: Double) {
        if analyzer.live.count > 1 {
            let lo = analyzer.gridStartKHz
            return (lo, lo + Double(analyzer.live.count - 1) * analyzer.gridStepKHz)
        }
        return (analyzer.startMHz * 1000, max(analyzer.startMHz + 1, analyzer.stopMHz) * 1000)
    }

    var body: some View {
        VStack(spacing: 0) {
            Canvas { ctx, size in draw(ctx, size) }
                .background(Color(white: 0.07))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = p
                    case .ended: hover = nil
                    }
                }
            if analyzer.showWaterfall {
                ZStack {
                    Color(white: 0.04)
                    if let img = analyzer.waterfall {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .padding(.leading, Self.leftInset)
                            .padding(.trailing, Self.rightInset)
                    } else {
                        Text("Waterfall appears while scanning").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 110)
            }
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let plot = CGRect(x: Self.leftInset, y: 26, width: max(10, size.width - Self.leftInset - Self.rightInset),
                          height: max(10, size.height - 46))
        let (lo, hi) = range
        func x(_ kHz: Double) -> CGFloat { plot.minX + CGFloat((kHz - lo) / (hi - lo)) * plot.width }
        func y(_ db: Double) -> CGFloat {
            plot.minY + CGFloat((dbTop - max(dbBottom, min(dbTop, db))) / (dbTop - dbBottom)) * plot.height
        }
        let small = Font.system(size: 9)
        let region = state.region

        // TV channels
        for ch in region.tvChannels where ch.highMHz * 1000 > lo && ch.lowMHz * 1000 < hi {
            let r = CGRect(x: x(ch.lowMHz * 1000), y: plot.minY, width: x(ch.highMHz * 1000) - x(ch.lowMHz * 1000),
                           height: plot.height).intersection(plot)
            if ch.number % 2 == 0 { ctx.fill(Path(r), with: .color(.white.opacity(0.035))) }
            ctx.draw(Text("\(ch.number)").font(small).foregroundColor(.gray), at: CGPoint(x: r.midX, y: plot.minY - 18), anchor: .top)
        }
        // Restricted bands (mobile, radio astronomy...)
        for b in region.restricted where b.highMHz * 1000 > lo && b.lowMHz * 1000 < hi {
            let r = CGRect(x: x(b.lowMHz * 1000), y: plot.minY, width: x(b.highMHz * 1000) - x(b.lowMHz * 1000),
                           height: plot.height).intersection(plot)
            ctx.fill(Path(r), with: .color(.red.opacity(0.13)))
            ctx.draw(Text(b.label).font(small).foregroundColor(.red.opacity(0.8)), at: CGPoint(x: r.midX, y: plot.maxY - 4), anchor: .bottom)
        }
        // User exclusions
        for e in state.project.coord.exclusionRangesKHz where Double(e.upperBound) > lo && Double(e.lowerBound) < hi {
            let r = CGRect(x: x(Double(e.lowerBound)), y: plot.minY, width: max(1, x(Double(e.upperBound)) - x(Double(e.lowerBound))),
                           height: plot.height).intersection(plot)
            ctx.fill(Path(r), with: .color(.orange.opacity(0.12)))
        }

        // dB grid
        var db = dbBottom
        while db <= dbTop {
            let yy = y(db)
            ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: yy)); $0.addLine(to: CGPoint(x: plot.maxX, y: yy)) },
                       with: .color(.white.opacity(0.07)), lineWidth: 1)
            ctx.draw(Text("\(Int(db))").font(small).foregroundColor(.gray), at: CGPoint(x: plot.minX - 4, y: yy), anchor: .trailing)
            db += 10
        }
        // Frequency grid
        let spanMHz = (hi - lo) / 1000
        let step = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 25, 50, 100].first { spanMHz / $0 <= 10 } ?? 100
        var f = (lo / 1000 / step).rounded(.up) * step
        while f * 1000 <= hi {
            let xx = x(f * 1000)
            ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: plot.minY)); $0.addLine(to: CGPoint(x: xx, y: plot.maxY)) },
                       with: .color(.white.opacity(0.06)), lineWidth: 1)
            ctx.draw(Text(step < 1 ? String(format: "%.2f", f) : String(format: "%.0f", f)).font(small).foregroundColor(.gray),
                     at: CGPoint(x: xx, y: plot.maxY + 3), anchor: .top)
            f += step
        }

        // Threshold
        let th = y(state.project.coord.thresholdDBm)
        ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: th)); $0.addLine(to: CGPoint(x: plot.maxX, y: th)) },
                   with: .color(.yellow.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // Imported / library overlays
        for (i, o) in analyzer.imported.enumerated() where o.enabled {
            var p = Path()
            var started = false
            for pt in o.points where pt.kHz >= lo && pt.kHz <= hi {
                let q = CGPoint(x: x(pt.kHz), y: y(pt.dBm))
                if started { p.addLine(to: q) } else { p.move(to: q); started = true }
            }
            ctx.stroke(p, with: .color(Palette.overlays[i % Palette.overlays.count].opacity(0.85)), lineWidth: 1)
        }

        // Peak and live traces
        func trace(_ v: [Double]) -> Path {
            var p = Path()
            var started = false
            for (i, d) in v.enumerated() {
                if d.isNaN { started = false; continue }
                let q = CGPoint(x: x(analyzer.gridStartKHz + Double(i) * analyzer.gridStepKHz), y: y(d))
                if started { p.addLine(to: q) } else { p.move(to: q); started = true }
            }
            return p
        }
        if analyzer.showPeak, !analyzer.peak.isEmpty {
            ctx.stroke(trace(analyzer.peak), with: .color(.orange.opacity(0.9)), lineWidth: 1)
        }
        if analyzer.showLive, !analyzer.live.isEmpty {
            ctx.stroke(trace(analyzer.live), with: .color(.green), lineWidth: 1.2)
        }

        // Intermod products of current frequencies
        if state.showIMDProducts {
            for p in state.imdProductsKHz where Double(p) >= lo && Double(p) <= hi {
                let xx = x(Double(p))
                ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: plot.maxY)); $0.addLine(to: CGPoint(x: xx, y: plot.maxY - 14)) },
                           with: .color(.red.opacity(0.8)), lineWidth: 1)
            }
        }

        // Channel markers
        let conflictLabels = Set(state.conflicts.map(\.victim))
        for (i, m) in state.markers.enumerated() where Double(m.kHz) >= lo && Double(m.kHz) <= hi {
            let xx = x(Double(m.kHz))
            let g = state.group(m.groupID)
            let col: Color = conflictLabels.contains(m.label) ? .red : (g.map { Palette.group($0.colorIndex) } ?? .cyan)
            ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: plot.minY)); $0.addLine(to: CGPoint(x: xx, y: plot.maxY)) },
                       with: .color(col.opacity(0.8)), lineWidth: 1)
            let row = CGFloat(i % 3)
            ctx.draw(Text(m.label).font(.system(size: 9, weight: .semibold)).foregroundColor(col),
                     at: CGPoint(x: xx + 2, y: plot.minY + 2 + row * 11), anchor: .topLeading)
        }
        // Proposed (coordinated) frequencies
        for (key, kHz) in state.proposals where Double(kHz) >= lo && Double(kHz) <= hi {
            let xx = x(Double(kHz))
            ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: plot.minY + 36)); $0.addLine(to: CGPoint(x: xx, y: plot.maxY)) },
                       with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let hit = state.lookup(key), let c = hit.0.channel(hit.1) {
                ctx.draw(Text("→ " + state.label(hit.0, c)).font(.system(size: 9)).foregroundColor(.white),
                         at: CGPoint(x: xx + 2, y: plot.minY + 38), anchor: .topLeading)
            }
        }

        // Hover readout
        if let h = hover, plot.contains(h) {
            let kHz = lo + Double((h.x - plot.minX) / plot.width) * (hi - lo)
            ctx.stroke(Path { $0.move(to: CGPoint(x: h.x, y: plot.minY)); $0.addLine(to: CGPoint(x: h.x, y: plot.maxY)) },
                       with: .color(.white.opacity(0.4)), lineWidth: 1)
            var text = String(format: "%.3f MHz", kHz / 1000)
            if let l = analyzer.snapshot.maxLevel(fromKHz: kHz - analyzer.gridStepKHz / 2, toKHz: kHz + analyzer.gridStepKHz / 2) {
                text += String(format: "   %.1f dBm", l)
            }
            if let ch = region.tvChannel(containingMHz: kHz / 1000) { text += "   TV \(ch.number)" }
            let right = h.x > plot.midX
            ctx.draw(Text(text).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundColor(.white),
                     at: CGPoint(x: h.x + (right ? -6 : 6), y: plot.minY + 40), anchor: right ? .topTrailing : .topLeading)
        }
    }
}
