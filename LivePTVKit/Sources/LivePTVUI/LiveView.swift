import CameraKit
import Pipeline
import PTVCore
import SwiftUI

/// 🐱 Live frame (display layer, camera rate) with the analysis overlay on top (heatmap, vectors, particles, ROI).
struct LiveView: View {
    @ObservedObject var model: AppModel
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VideoLayerView(display: model.videoDisplay)
                OverlayView(live: model.live, display: model.display, mmPerPixel: model.settings.effectiveMMPerPixel,
                            previewRunning: model.previewRunning)
                if let a = dragStart, let b = dragNow {
                    Rectangle().stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: abs(b.x - a.x), height: abs(b.y - a.y))
                        .offset(x: min(a.x, b.x), y: min(a.y, b.y))
                }
                if model.editingROI {
                    Text(model.editTarget.hint)
                        .font(.caption).padding(6).background(.yellow.opacity(0.85), in: Capsule()).foregroundStyle(.black)
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .gesture(roiGesture(viewSize: geo.size), including: model.editingROI ? .all : .subviews)
        }
        .clipped()
    }

    private func roiGesture(viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if dragStart == nil { dragStart = v.startLocation }
                dragNow = v.location
            }
            .onEnded { v in
                defer { dragStart = nil; dragNow = nil }
                let imageSize = model.live.videoSize ?? model.live.overlay?.imageSize ?? CGSize(width: 1920, height: 1080)
                let fit = FitTransform(image: imageSize, view: viewSize)
                let a = fit.toImage(v.startLocation), b = fit.toImage(v.location)
                let x0 = max(0, min(a.x, b.x)), y0 = max(0, min(a.y, b.y))
                let x1 = min(imageSize.width, max(a.x, b.x)), y1 = min(imageSize.height, max(a.y, b.y))
                guard x1 - x0 >= 16, y1 - y0 >= 16 else { return }
                let r = PixelROI(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0))
                switch model.editTarget {
                case .shakeReference: model.setShakeReference(r)
                case .analysisRegion: model.setROI(r)
                case .container: model.setContainerOutline(r, frameSize: imageSize)
                case .exclusion: model.addExclusion(r)
                }
                model.editingROI = false
            }
    }
}

/// 🐱 Only this view re-renders when a new analysis result arrives.
struct OverlayView: View {
    @ObservedObject var live: LiveOverlayModel
    let display: DisplayOptions
    let mmPerPixel: Double?
    let previewRunning: Bool

    var body: some View {
        GeometryReader { geo in
            if live.videoSize == nil && live.overlay == nil {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text(previewRunning ? "Waiting for the first frame…" : "No preview. Choose a source and start the preview.")
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.gray)
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let imageSize = live.videoSize ?? live.overlay?.imageSize ?? CGSize(width: 1920, height: 1080)
                let fit = FitTransform(image: imageSize, view: geo.size)
                Canvas { ctx, _ in
                    if let o = live.overlay { draw(ctx, fit, o) }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: GraphicsContext, _ fit: FitTransform, _ o: OverlayData) {
        // 🐱 what the analysis ignores (tinted), the container outline and its usable fluid, exclusions
        if display.showMask, let m = o.maskImage {
            let a = fit.toView(o.maskRect.origin)
            ctx.draw(Image(decorative: m, scale: 1).interpolation(.medium),
                     in: CGRect(x: a.x, y: a.y, width: o.maskRect.width * fit.scale, height: o.maskRect.height * fit.scale))
        }
        if let c = o.containerOutline {
            let tl = fit.toView(CGPoint(x: c.x, y: c.y))
            let rect = CGRect(x: tl.x, y: tl.y, width: CGFloat(c.width) * fit.scale, height: CGFloat(c.height) * fit.scale)
            ctx.stroke(Path(rect), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [8, 4]))
            if let u = o.usableLateral {
                var p = Path()
                for l in [u.0, u.1] {
                    if o.containerVertical {
                        let x = fit.toView(CGPoint(x: l, y: 0)).x
                        p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    } else {
                        let y = fit.toView(CGPoint(x: 0, y: l)).y
                        p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                ctx.stroke(p, with: .color(.green.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
            ctx.draw(Text(o.containerLabel).font(.caption2).foregroundColor(.white), at: CGPoint(x: rect.minX + 4, y: rect.minY - 8), anchor: .leading)
        }
        for e in o.exclusions {
            let tl = fit.toView(CGPoint(x: e.x, y: e.y))
            let rect = CGRect(x: tl.x, y: tl.y, width: CGFloat(e.width) * fit.scale, height: CGFloat(e.height) * fit.scale)
            var p = Path(rect)
            p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            ctx.stroke(p, with: .color(.red.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        }

        // 🐱 ROI
        let r = o.roi
        let tl = fit.toView(CGPoint(x: r.x, y: r.y))
        ctx.stroke(Path(CGRect(x: tl.x, y: tl.y, width: CGFloat(r.width) * fit.scale, height: CGFloat(r.height) * fit.scale)),
                   with: .color(.yellow.opacity(0.8)), lineWidth: 1.5)

        // 🐱 heatmap: one small image (a pixel per cell) drawn smoothed over the grid → contour-like map
        if let img = o.heatmapImage, let h = o.heatmap {
            var c = ctx
            c.opacity = display.heatmapOpacity
            let a = fit.toView(o.heatmapRect.origin)
            let rect = CGRect(x: a.x, y: a.y, width: o.heatmapRect.width * fit.scale, height: o.heatmapRect.height * fit.scale)
            c.draw(Image(decorative: img, scale: 1).interpolation(.high), in: rect)
            drawColorBar(ctx, fit, h)
        }

        if !o.tails.isEmpty {
            var p = Path()
            for tail in o.tails {
                guard let first = tail.first else { continue }
                p.move(to: fit.toView(first))
                for q in tail.dropFirst() { p.addLine(to: fit.toView(q)) }
            }
            ctx.stroke(p, with: .color(.cyan.opacity(0.7)), lineWidth: 1)
        }

        if !o.particles.isEmpty {
            var p = Path()
            let rad: CGFloat = 2.5
            for q in o.particles {
                let v = fit.toView(q)
                p.addEllipse(in: CGRect(x: v.x - rad, y: v.y - rad, width: 2 * rad, height: 2 * rad))
            }
            ctx.stroke(p, with: .color(.green), lineWidth: 1)
        }

        if !o.arrows.isEmpty || !o.outliers.isEmpty {
            // 🐱 one path per colour bin: a dozen stroke calls however many arrows
            var paths = [Path](repeating: Path(), count: OverlayData.colorBins)
            for a in o.arrows {
                let start = fit.toView(CGPoint(x: a.x, y: a.y))
                let end = CGPoint(x: start.x + a.ex * fit.scale, y: start.y + a.ey * fit.scale)
                Self.addArrow(&paths[min(OverlayData.colorBins - 1, max(0, a.bin))], from: start, to: end)
            }
            for b in 0..<OverlayData.colorBins where !paths[b].isEmpty {
                ctx.stroke(paths[b], with: .color(OverlayData.binColor(b)), lineWidth: 1.6)
            }
            if !o.outliers.isEmpty {
                var p = Path()
                for q in o.outliers {
                    let v = fit.toView(q)
                    p.addEllipse(in: CGRect(x: v.x - 2, y: v.y - 2, width: 4, height: 4))
                }
                ctx.fill(p, with: .color(.red))
            }
            if !o.arrows.isEmpty { drawLegend(ctx, fit, ref: o.referenceSpeed, seconds: o.arrowSeconds) }
        }

        // 🐱 static reference area for shake compensation
        if let s = o.shakeReference {
            let tl = fit.toView(CGPoint(x: s.x, y: s.y))
            ctx.stroke(Path(CGRect(x: tl.x, y: tl.y, width: CGFloat(s.width) * fit.scale, height: CGFloat(s.height) * fit.scale)),
                       with: .color(.cyan), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            ctx.draw(Text("static reference").font(.caption2).foregroundColor(.cyan), at: CGPoint(x: tl.x + 4, y: tl.y + 10), anchor: .leading)
        }

        // 🐱 what the live analysis is doing
        if !o.status.isEmpty {
            let p = CGPoint(x: fit.origin.x + 10, y: fit.origin.y + fit.drawSize.height - 14)
            let resolved = ctx.resolve(Text(o.status).font(.caption.monospacedDigit()).foregroundColor(.white))
            let size = resolved.measure(in: CGSize(width: fit.drawSize.width, height: 40))
            ctx.fill(Path(roundedRect: CGRect(x: p.x - 6, y: p.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6), cornerRadius: 6),
                     with: .color(.black.opacity(0.55)))
            ctx.draw(resolved, at: p, anchor: .leading)
        }

        if !o.velocityEnabled {
            ctx.draw(Text("Velocities paused: waiting for verified camera timestamps").font(.caption).foregroundColor(.orange),
                     at: CGPoint(x: fit.origin.x + 8, y: fit.origin.y + fit.drawSize.height - 34), anchor: .leading)
        }
    }

    private func drawColorBar(_ ctx: GraphicsContext, _ fit: FitTransform, _ h: HeatmapLayer) {
        let barW: CGFloat = 14, barH = min(260, fit.drawSize.height - 80)
        guard barH > 40 else { return }
        let x = fit.origin.x + fit.drawSize.width - barW - 46, y = fit.origin.y + 40
        let colors = h.barColors.reversed().map { Color(red: $0.r, green: $0.g, blue: $0.b) }
        let rect = CGRect(x: x, y: y, width: barW, height: barH)
        ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: x, y: y), endPoint: CGPoint(x: x, y: y + barH)))
        ctx.stroke(Path(rect), with: .color(.white.opacity(0.8)), lineWidth: 1)
        func label(_ v: Double) -> String {
            let a = abs(v)
            return a == 0 ? "0" : (a >= 1000 || a < 0.01) ? String(format: "%.1e", v) : String(format: a >= 100 ? "%.0f" : a >= 10 ? "%.1f" : "%.2f", v)
        }
        ctx.draw(Text(label(h.hi)).font(.caption2.monospacedDigit()).foregroundColor(.white), at: CGPoint(x: x + barW + 4, y: y), anchor: .leading)
        ctx.draw(Text(label(h.lo)).font(.caption2.monospacedDigit()).foregroundColor(.white), at: CGPoint(x: x + barW + 4, y: y + barH), anchor: .leading)
        ctx.draw(Text("\(h.quantity.title)\n\(h.unit)").font(.caption2).foregroundColor(.white), at: CGPoint(x: x + barW / 2, y: y - 6), anchor: .bottom)
    }

    private func drawLegend(_ ctx: GraphicsContext, _ fit: FitTransform, ref: Double, seconds: Double) {
        // 🐱 Reference arrow: a round speed close to the 95th percentile, in µm/s or mm/s when calibrated.
        let unit = SpeedUnit.choose(mmPerPixel: mmPerPixel, typicalPxPerSecond: ref)
        let shown = ref * unit.factor
        let mag = pow(10, floor(log10(max(shown, 1e-9))))
        let nice = [1.0, 2.0, 5.0, 10.0].map { $0 * mag }.last { $0 <= shown } ?? mag
        let lenImage = nice / unit.factor * seconds
        let start = CGPoint(x: fit.origin.x + 12, y: fit.origin.y + 18)
        let end = CGPoint(x: start.x + lenImage * fit.scale, y: start.y)
        var p = Path()
        Self.addArrow(&p, from: start, to: end)
        ctx.stroke(p, with: .color(.white), lineWidth: 2)
        let label = String(format: nice >= 10 ? "%.0f %@" : "%.2g %@", nice, unit.label)
        ctx.draw(Text(label).font(.caption.bold()).foregroundColor(.white), at: CGPoint(x: end.x + 6, y: end.y), anchor: .leading)
    }

    static func addArrow(_ p: inout Path, from a: CGPoint, to b: CGPoint) {
        p.move(to: a)
        p.addLine(to: b)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 3 else { return }
        let ux = dx / len, uy = dy / len
        let head = min(6, len * 0.35)
        p.move(to: b)
        p.addLine(to: CGPoint(x: b.x - head * (ux - 0.5 * uy), y: b.y - head * (uy + 0.5 * ux)))
        p.move(to: b)
        p.addLine(to: CGPoint(x: b.x - head * (ux + 0.5 * uy), y: b.y - head * (uy - 0.5 * ux)))
    }
}

/// 🐱 The live status line for the settings panel (updates a few times per second, alone).
struct LiveStatusLine: View {
    @ObservedObject var metrics: MetricsModel
    let previewRunning: Bool

    var body: some View {
        if previewRunning && !metrics.status.isEmpty {
            Text(metrics.status).font(.caption)
        }
    }
}

/// 🐱 Live numbers: rates, latency breakdown, drops, counts.
struct MetricsBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var metrics: MetricsModel

    var body: some View {
        let m = metrics.metrics
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                item("Stream", fmt(m.sourceFPS, "%.1f fps"))
                item("Analysis", fmt(m.processingFPS, "%.1f fps"))
                item("Receive→result", fmt(m.receiveToResultMs, "%.0f ms") + (m.receiveToResultP95Ms.map { String(format: " (p95 %.0f)", $0) } ?? ""))
                item("Assembly", fmt(m.assemblyWaitMs, "%.0f ms"))
                item("Decode", fmt(m.decodeLatencyMs, "%.1f ms"))
                item("Analyse", fmt(m.analysisDurationMs, "%.1f ms") + (m.pivDevice.map { " · \($0)" } ?? ""))
                item("Glass→result", fmt(m.glassToResultMs, "%.0f ms"))
                item("Missing frames", "\(m.streamGapFrames)", warn: m.streamGapFrames > 0)
                item("Analysis drops", "\(m.analysisDrops)", warn: m.analysisDrops > 0)
                item("Decode errors", "\(m.decodeErrors)", warn: m.decodeErrors > 0)
                item("Particles", "\(m.particles)")
                item("Tracks", "\(m.activeTracks)")
                item("Vectors", "\(m.samples)")
                item("Timing", m.timestampQuality.isEmpty ? "–" : m.timestampQuality, warn: m.timestampQuality == "hostArrival" || m.timestampQuality == "provisional")
                if let since = model.recordingSince {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        item("● REC", Self.elapsed(ctx.date.timeIntervalSince(since)), warn: true)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func item(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(warn ? .orange : .primary)
        }
    }

    private func fmt(_ v: Double?, _ f: String) -> String { v.map { String(format: f, $0) } ?? "–" }

    static func elapsed(_ s: Double) -> String {
        let t = Int(s)
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }
}
