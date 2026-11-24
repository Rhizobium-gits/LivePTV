import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PTVCore

/// 🐱 Publication-style figures (PNG for viewing, PDF vector graphics for papers) from the time-averaged field.
/// 🐱 Coordinates follow the camera image: x to the right, y downward (as in PIVlab); axes in mm when calibrated.
enum FigureRenderer {
    struct FieldData {
        let grid: GridGeometry
        /// 🐱 px/s, nil where the cell is not valid
        let u: [Double?]
        let v: [Double?]
        let vorticity: [Double?]
        let divergence: [Double?]
        let speedUnit: SpeedUnit
        /// 🐱 length per px for the axes (mm when calibrated)
        let lengthPerPixel: Double
        let lengthUnit: String

        init(cells: [CellStatistics], grid: GridGeometry, speedUnit: SpeedUnit, mmPerPixel: Double?) {
            self.grid = grid
            u = cells.map { $0.valid ? $0.meanU : nil }
            v = cells.map { $0.valid ? $0.meanV : nil }
            vorticity = cells.map(\.vorticity)
            divergence = cells.map(\.divergence)
            self.speedUnit = speedUnit
            lengthPerPixel = mmPerPixel ?? 1
            lengthUnit = mmPerPixel == nil ? "px" : "mm"
        }

        var speed: [Double?] { zip(u, v).map { a, b in a.flatMap { x in b.map { y in hypot(x, y) * speedUnit.factor } } } }
        var extent: CGRect {
            CGRect(x: grid.originX, y: grid.originY, width: Double(grid.columns) * grid.cellSize, height: Double(grid.rows) * grid.cellSize)
        }

        /// 🐱 Bilinear interpolation of (u, v) px/s at an image point; nil outside data.
        func velocity(atX x: Double, y: Double) -> (Double, Double)? {
            let fx = (x - grid.originX) / grid.cellSize - 0.5, fy = (y - grid.originY) / grid.cellSize - 0.5
            guard fx >= -0.5, fy >= -0.5, fx <= Double(grid.columns) - 0.5, fy <= Double(grid.rows) - 0.5 else { return nil }
            let cx = max(0, min(Double(grid.columns - 1), fx)), cy = max(0, min(Double(grid.rows - 1), fy))
            let i0 = Int(cx), j0 = Int(cy), i1 = min(grid.columns - 1, i0 + 1), j1 = min(grid.rows - 1, j0 + 1)
            let tx = cx - Double(i0), ty = cy - Double(j0)
            var su = 0.0, sv = 0.0, sw = 0.0
            for (i, j, w) in [(i0, j0, (1 - tx) * (1 - ty)), (i1, j0, tx * (1 - ty)), (i0, j1, (1 - tx) * ty), (i1, j1, tx * ty)] where w > 0 {
                let k = j * grid.columns + i
                guard let a = u[k], let b = v[k] else { continue }
                su += w * a; sv += w * b; sw += w
            }
            return sw > 0.5 ? (su / sw, sv / sw) : nil
        }
    }

    struct Output { let png: Data; let pdf: Data }

    // 🐱 MARK: figures

    /// 🐱 (a) speed + vectors, (b) streamlines, (c) vorticity, (d) divergence.
    static func summary(_ f: FieldData, title: String) -> Output? {
        let panelW: CGFloat = 250
        let ext = f.extent
        let aspect = CGFloat(ext.height / max(ext.width, 1))
        let panelH = panelW * aspect
        let cellW = panelW + 120, cellH = panelH + 70
        let size = CGSize(width: 2 * cellW + 20, height: 2 * cellH + 40)
        return render(size: size) { ctx in
            text(ctx, title, at: CGPoint(x: 20, y: 22), size: 12, bold: true)
            let speed = f.speed
            let rSpeed = range(speed, symmetric: false)
            let panels: [(String, (CGRect) -> Void)] = [
                ("(a) Velocity magnitude and vectors", { r in
                    colorField(ctx, f, values: speed, in: r, cmap: .viridis, lo: rSpeed.0, hi: rSpeed.1)
                    quiver(ctx, f, in: r)
                    colorbar(ctx, at: r, cmap: .viridis, lo: rSpeed.0, hi: rSpeed.1, label: "speed (\(f.speedUnit.label))")
                }),
                ("(b) Streamlines (coloured by speed)", { r in
                    ctx.setFillColor(CGColor(gray: 0.97, alpha: 1)); ctx.fill(r)
                    streamlines(ctx, f, in: r, lo: rSpeed.0, hi: rSpeed.1)
                    colorbar(ctx, at: r, cmap: .viridis, lo: rSpeed.0, hi: rSpeed.1, label: "speed (\(f.speedUnit.label))")
                }),
                ("(c) Vorticity ω (counter-clockwise +)", { r in
                    let rv = range(f.vorticity, symmetric: true)
                    colorField(ctx, f, values: f.vorticity, in: r, cmap: .coolwarm, lo: rv.0, hi: rv.1)
                    colorbar(ctx, at: r, cmap: .coolwarm, lo: rv.0, hi: rv.1, label: "ω (1/s)")
                }),
                (divergenceTitle(f), { r in
                    let rd = range(f.divergence, symmetric: true)
                    colorField(ctx, f, values: f.divergence, in: r, cmap: .coolwarm, lo: rd.0, hi: rd.1)
                    colorbar(ctx, at: r, cmap: .coolwarm, lo: rd.0, hi: rd.1, label: "∇·u (1/s)")
                }),
            ]
            for (n, p) in panels.enumerated() {
                let ox = 20 + CGFloat(n % 2) * cellW + 45, oy = 40 + CGFloat(n / 2) * cellH + 22
                let r = CGRect(x: ox, y: oy, width: panelW, height: panelH)
                text(ctx, p.0, at: CGPoint(x: ox - 40, y: oy - 8), size: 10, bold: true)
                p.1(r)
                axes(ctx, f, in: r)
            }
        }
    }

    /// 🐱 Divergence should be small in planar incompressible flow; say how small next to the vorticity.
    private static func divergenceTitle(_ f: FieldData) -> String {
        let d = f.divergence.compactMap { $0 }.map(abs), w = f.vorticity.compactMap { $0 }.map(abs)
        guard !d.isEmpty, !w.isEmpty, w.reduce(0, +) > 0 else { return "(d) Divergence" }
        let ratio = d.reduce(0, +) / Double(d.count) / (w.reduce(0, +) / Double(w.count))
        return String(format: "(d) Divergence (mean magnitude %.0f %% of the vorticity's)", ratio * 100)
    }

    /// 🐱 u along the vertical centre line and v along the horizontal centre line, with ±2 SE error bars.
    static func profiles(cells: [CellStatistics], grid: GridGeometry, unit: SpeedUnit, mmPerPixel: Double?) -> (Output, String)? {
        let mid = grid.columns / 2, midRow = grid.rows / 2
        let colCells = (0..<grid.rows).map { cells[$0 * grid.columns + mid] }.filter(\.valid)
        let rowCells = (0..<grid.columns).map { cells[midRow * grid.columns + $0] }.filter(\.valid)
        guard colCells.count >= 2 || rowCells.count >= 2 else { return nil }
        let L = mmPerPixel ?? 1, lu = mmPerPixel == nil ? "px" : "mm"
        let a = colCells.map { (Double($0.y) * L, $0.meanU * unit.factor, 2 * $0.standardErrorU * unit.factor, $0.stdU * unit.factor) }
        let b = rowCells.map { (Double($0.x) * L, $0.meanV * unit.factor, 2 * $0.standardErrorV * unit.factor, $0.stdV * unit.factor) }
        var csv = "profile,position_\(lu),mean_\(unit.label.replacingOccurrences(of: "/", with: "_")),two_se,std,samples\n"
        for (c, p) in zip(colCells, a) { csv += String(format: "u_at_x=%.4g,%.6g,%.6g,%.6g,%.6g,%d\n", Double(c.x) * L, p.0, p.1, p.2, p.3, c.count) }
        for (c, p) in zip(rowCells, b) { csv += String(format: "v_at_y=%.4g,%.6g,%.6g,%.6g,%.6g,%d\n", Double(c.y) * L, p.0, p.1, p.2, p.3, c.count) }
        let xC = (colCells.first?.x ?? 0) * L, yC = (rowCells.first?.y ?? 0) * L
        guard let out = render(size: CGSize(width: 640, height: 280), draw: { ctx in
            linePlot(ctx, in: CGRect(x: 60, y: 40, width: 230, height: 180), points: a,
                     title: String(format: "(a) u along x = %.3g %@", xC, lu), xLabel: "y (\(lu))", yLabel: "u (\(unit.label))")
            linePlot(ctx, in: CGRect(x: 380, y: 40, width: 230, height: 180), points: b,
                     title: String(format: "(b) v along y = %.3g %@", yC, lu), xLabel: "x (\(lu))", yLabel: "v (\(unit.label))")
            text(ctx, "Points: time-averaged cell means; bars: ±2 standard errors; band: ±1 standard deviation (fluctuations).",
                 at: CGPoint(x: 60, y: 266), size: 8, gray: 0.35)
        }) else { return nil }
        return (out, csv)
    }

    /// 🐱 Spatially averaged speed per second of camera time, ±1 std across the frames in that second.
    static func timeSeries(bins: [Int: (sum: Double, sumSq: Double, n: Int)], unit: SpeedUnit) -> (Output, String)? {
        guard bins.count >= 2 else { return nil }
        let keys = bins.keys.sorted()
        var pts: [(Double, Double, Double, Double)] = []
        var csv = "t_start_s,mean_speed_\(unit.label.replacingOccurrences(of: "/", with: "_")),std,frames\n"
        for k in keys {
            let e = bins[k]!
            let m = e.sum / Double(e.n)
            let sd = e.n > 1 ? sqrt(max(0, (e.sumSq - Double(e.n) * m * m) / Double(e.n - 1))) : 0
            pts.append((Double(k) + 0.5, m * unit.factor, 0, sd * unit.factor))
            csv += String(format: "%d,%.6g,%.6g,%d\n", k, m * unit.factor, sd * unit.factor, e.n)
        }
        guard let out = render(size: CGSize(width: 640, height: 260), draw: { ctx in
            linePlot(ctx, in: CGRect(x: 60, y: 40, width: 550, height: 170), points: pts, title: "Spatially averaged speed over time",
                     xLabel: "time (s)", yLabel: "mean speed (\(unit.label))", markers: false)
            text(ctx, "Use the steady part of the record for time averages (the reference study averaged after the start-up transient).",
                 at: CGPoint(x: 60, y: 248), size: 8, gray: 0.35)
        }) else { return nil }
        return (out, csv)
    }

    // 🐱 MARK: drawing primitives (context is y-down, origin top-left)

    private static func render(size: CGSize, draw: (CGContext) -> Void) -> Output? {
        // 🐱 PNG at 3× for print-like sharpness
        let s: CGFloat = 3
        guard let bmp = CGContext(data: nil, width: Int(size.width * s), height: Int(size.height * s), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bmp.scaleBy(x: s, y: s)
        prepare(bmp, size)
        draw(bmp)
        guard let img = bmp.makeImage() else { return nil }
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let pdf = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData), let pctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        pctx.beginPDFPage(nil)
        prepare(pctx, size)
        draw(pctx)
        pctx.endPDFPage()
        pctx.closePDF()
        return Output(png: png as Data, pdf: pdf as Data)
    }

    private static func prepare(_ ctx: CGContext, _ size: CGSize) {
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    static func text(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, bold: Bool = false, gray: CGFloat = 0.1, align: CGFloat = 0) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: p.x - CGFloat(width) * align, y: p.y)
        CTLineDraw(line, ctx)
    }

    /// 🐱 Text reading bottom-to-top, centred on a point (axis titles).
    static func verticalText(_ ctx: CGContext, _ s: String, centeredAt p: CGPoint, size: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: -.pi / 2)
        text(ctx, s, at: CGPoint(x: 0, y: 0), size: size, align: 0.5)
        ctx.restoreGState()
    }

    private static func range(_ values: [Double?], symmetric: Bool) -> (Double, Double) {
        let v = values.compactMap { $0 }.filter(\.isFinite)
        guard let mx = v.max(), let mn = v.min() else { return (0, 1) }
        if symmetric { let m = max(abs(mx), abs(mn), 1e-12); return (-m, m) }
        return (0, max(mx, 1e-12))
    }

    private static func toView(_ f: FieldData, _ r: CGRect, _ x: Double, _ y: Double) -> CGPoint {
        let e = f.extent
        return CGPoint(x: r.minX + CGFloat((x - e.minX) / e.width) * r.width, y: r.minY + CGFloat((y - e.minY) / e.height) * r.height)
    }

    /// 🐱 Smooth colour field: bilinear interpolation of cell-centre values (invalid cells left blank).
    private static func colorField(_ ctx: CGContext, _ f: FieldData, values: [Double?], in r: CGRect, cmap: Colormap, lo: Double, hi: Double) {
        ctx.setFillColor(CGColor(gray: 0.93, alpha: 1))
        ctx.fill(r)
        let g = f.grid
        let up = 6
        let W = g.columns * up, H = g.rows * up
        var px = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let fx = (Double(x) + 0.5) / Double(up) - 0.5, fy = (Double(y) + 0.5) / Double(up) - 0.5
                let cx = max(0, min(Double(g.columns - 1), fx)), cy = max(0, min(Double(g.rows - 1), fy))
                let i0 = Int(cx), j0 = Int(cy), i1 = min(g.columns - 1, i0 + 1), j1 = min(g.rows - 1, j0 + 1)
                let tx = cx - Double(i0), ty = cy - Double(j0)
                // 🐱 the pixel's own cell must be valid; neighbours contribute only where valid
                guard values[Int(Double(y) / Double(up)) * g.columns + Int(Double(x) / Double(up))] != nil else { continue }
                var s = 0.0, w = 0.0
                for (i, j, wt) in [(i0, j0, (1 - tx) * (1 - ty)), (i1, j0, tx * (1 - ty)), (i0, j1, (1 - tx) * ty), (i1, j1, tx * ty)] where wt > 0 {
                    if let val = values[j * g.columns + i] { s += wt * val; w += wt }
                }
                guard w > 0 else { continue }
                let c = cmap.rgb((s / w - lo) / (hi - lo))
                let o = (y * W + x) * 4
                px[o] = UInt8(c.r * 255); px[o + 1] = UInt8(c.g * 255); px[o + 2] = UInt8(c.b * 255); px[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        // 🐱 the context is y-down; flip locally so the image is not drawn upside down
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// 🐱 Uniformly scaled arrows on a thinned grid, with a reference arrow.
    private static func quiver(_ ctx: CGContext, _ f: FieldData, in r: CGRect) {
        let g = f.grid
        let stride = max(1, Int(ceil(Double(g.columns) / 22)))
        let speeds = zip(f.u, f.v).compactMap { a, b in a.flatMap { x in b.map { hypot(x, $0) } } }
        guard let maxS = speeds.max(), maxS > 0 else { return }
        let spacing = Double(r.width) / Double(g.columns) * Double(stride)
        let scale = 0.9 * spacing / maxS   // 🐱 view points per (px/s)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
        ctx.setLineWidth(0.7)
        for j in Swift.stride(from: stride / 2, to: g.rows, by: stride) {
            for i in Swift.stride(from: stride / 2, to: g.columns, by: stride) {
                let k = j * g.columns + i
                guard let u = f.u[k], let v = f.v[k] else { continue }
                let c = g.center(k)
                let p = toView(f, r, c.x, c.y)
                arrow(ctx, from: p, to: CGPoint(x: p.x + CGFloat(u * scale), y: p.y + CGFloat(v * scale)))
            }
        }
        ctx.strokePath()
        // 🐱 reference arrow below the panel
        let refValue = niceNumber(maxS * f.speedUnit.factor * 0.5)
        let refLen = CGFloat(refValue / f.speedUnit.factor * scale)
        let p0 = CGPoint(x: r.maxX - refLen - 4, y: r.maxY + 30)
        ctx.setLineWidth(0.9)
        arrow(ctx, from: p0, to: CGPoint(x: p0.x + refLen, y: p0.y))
        ctx.strokePath()
        text(ctx, "\(format(refValue)) \(f.speedUnit.label)", at: CGPoint(x: p0.x - 4, y: p0.y + 3), size: 8, align: 1)
    }

    private static func arrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint) {
        ctx.move(to: a)
        ctx.addLine(to: b)
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        guard len > 1.5 else { return }
        let ux = dx / len, uy = dy / len, h = min(3.5, len * 0.35)
        ctx.move(to: b); ctx.addLine(to: CGPoint(x: b.x - h * (ux - 0.45 * uy), y: b.y - h * (uy + 0.45 * ux)))
        ctx.move(to: b); ctx.addLine(to: CGPoint(x: b.x - h * (ux + 0.45 * uy), y: b.y - h * (uy - 0.45 * ux)))
    }

    /// 🐱 Evenly spaced streamlines (simplified Jobard–Lefer): seeds on a grid, RK2 both ways, stop near other lines.
    private static func streamlines(_ ctx: CGContext, _ f: FieldData, in r: CGRect, lo: Double, hi: Double) {
        let e = f.extent
        let dsep = max(e.width, e.height) / 28
        let dtest = dsep * 0.5
        let step = f.grid.cellSize * 0.25
        let occW = Int(ceil(e.width / dtest)) + 1, occH = Int(ceil(e.height / dtest)) + 1
        var occupied = [Int](repeating: -1, count: occW * occH)
        func occIndex(_ x: Double, _ y: Double) -> Int? {
            let i = Int((x - e.minX) / dtest), j = Int((y - e.minY) / dtest)
            return (i >= 0 && j >= 0 && i < occW && j < occH) ? j * occW + i : nil
        }
        let maxSpeed = max(hi / f.speedUnit.factor, 1e-12)
        var lineID = 0
        var lines: [[(x: Double, y: Double, s: Double)]] = []
        var sy = e.minY + dsep / 2
        while sy < e.maxY {
            var sx = e.minX + dsep / 2
            while sx < e.maxX {
                defer { sx += dsep }
                guard let o = occIndex(sx, sy), occupied[o] < 0, f.velocity(atX: sx, y: sy) != nil else { continue }
                var line: [(Double, Double, Double)] = []
                var closed = false
                for dir in [-1.0, 1.0] where !closed {
                    var x = sx, y = sy
                    var part: [(Double, Double, Double)] = []
                    for n in 0..<600 {
                        guard let v1 = f.velocity(atX: x, y: y) else { break }
                        let s1 = hypot(v1.0, v1.1)
                        guard s1 > maxSpeed * 1e-3 else { break }
                        let mx = x + dir * 0.5 * step * v1.0 / s1, my = y + dir * 0.5 * step * v1.1 / s1
                        guard let v2 = f.velocity(atX: mx, y: my) else { break }
                        let s2 = hypot(v2.0, v2.1)
                        guard s2 > maxSpeed * 1e-3 else { break }
                        x += dir * step * v2.0 / s2; y += dir * step * v2.1 / s2
                        guard let oi = occIndex(x, y) else { break }
                        if occupied[oi] >= 0 && occupied[oi] != lineID { break }
                        part.append((x, y, s2))
                        // 🐱 closed orbit (e.g. around a vortex core): stop instead of retracing the loop
                        if n > 8 && hypot(x - sx, y - sy) < step * 1.5 { closed = true; break }
                    }
                    line = dir < 0 ? part.reversed() + [(sx, sy, hypot(f.velocity(atX: sx, y: sy)!.0, f.velocity(atX: sx, y: sy)!.1))] : line + part
                }
                guard line.count >= 8 else { continue }
                for p in line { if let oi = occIndex(p.0, p.1) { occupied[oi] = lineID } }
                lines.append(line.map { ($0.0, $0.1, $0.2) })
                lineID += 1
            }
            sy += dsep
        }
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setLineWidth(0.9)
        ctx.setLineCap(.round)
        for line in lines {
            for (a, b) in zip(line, line.dropFirst()) {
                let c = Colormap.viridis.rgb((b.s * f.speedUnit.factor - lo) / (hi - lo))
                ctx.setStrokeColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
                ctx.move(to: toView(f, r, a.x, a.y))
                ctx.addLine(to: toView(f, r, b.x, b.y))
                ctx.strokePath()
            }
            // 🐱 direction arrowhead at the middle of each line
            if line.count >= 6 {
                let m = line.count / 2
                let p0 = toView(f, r, line[m - 1].x, line[m - 1].y), p1 = toView(f, r, line[m].x, line[m].y)
                let c = Colormap.viridis.rgb((line[m].s * f.speedUnit.factor - lo) / (hi - lo))
                ctx.setStrokeColor(CGColor(red: c.r * 0.7, green: c.g * 0.7, blue: c.b * 0.7, alpha: 1))
                let dx = p1.x - p0.x, dy = p1.y - p0.y, l = max(hypot(dx, dy), 1e-6)
                let ux = dx / l, uy = dy / l, h: CGFloat = 4
                ctx.move(to: p1); ctx.addLine(to: CGPoint(x: p1.x - h * (ux - 0.5 * uy), y: p1.y - h * (uy + 0.5 * ux)))
                ctx.move(to: p1); ctx.addLine(to: CGPoint(x: p1.x - h * (ux + 0.5 * uy), y: p1.y - h * (uy - 0.5 * ux)))
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    private static func axes(_ ctx: CGContext, _ f: FieldData, in r: CGRect) {
        ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
        ctx.setLineWidth(0.7)
        ctx.stroke(r)
        let e = f.extent, L = f.lengthPerPixel
        for t in ticks(e.minX * L, e.maxX * L) {
            let x = r.minX + CGFloat((t / L - e.minX) / e.width) * r.width
            ctx.move(to: CGPoint(x: x, y: r.maxY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY + 3))
            text(ctx, format(t), at: CGPoint(x: x, y: r.maxY + 12), size: 7.5, align: 0.5)
        }
        for t in ticks(e.minY * L, e.maxY * L) {
            let y = r.minY + CGFloat((t / L - e.minY) / e.height) * r.height
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.minX - 3, y: y))
            text(ctx, format(t), at: CGPoint(x: r.minX - 5, y: y + 2.5), size: 7.5, align: 1)
        }
        ctx.strokePath()
        text(ctx, "x (\(f.lengthUnit))", at: CGPoint(x: r.midX, y: r.maxY + 24), size: 8.5, align: 0.5)
        verticalText(ctx, "y (\(f.lengthUnit))", centeredAt: CGPoint(x: r.minX - 28, y: r.midY), size: 8.5)
    }

    private static func colorbar(_ ctx: CGContext, at r: CGRect, cmap: Colormap, lo: Double, hi: Double, label: String) {
        let bar = CGRect(x: r.maxX + 10, y: r.minY, width: 9, height: r.height)
        let n = 64
        for s in 0..<n {
            let c = cmap.rgb(1 - Double(s) / Double(n - 1))
            ctx.setFillColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: 1))
            ctx.fill(CGRect(x: bar.minX, y: bar.minY + bar.height * CGFloat(s) / CGFloat(n), width: bar.width, height: bar.height / CGFloat(n) + 0.3))
        }
        ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
        ctx.setLineWidth(0.6)
        ctx.stroke(bar)
        for t in ticks(lo, hi) {
            let y = bar.maxY - CGFloat((t - lo) / (hi - lo)) * bar.height
            ctx.move(to: CGPoint(x: bar.maxX, y: y)); ctx.addLine(to: CGPoint(x: bar.maxX + 2.5, y: y))
            text(ctx, format(t), at: CGPoint(x: bar.maxX + 4, y: y + 2.5), size: 7)
        }
        ctx.strokePath()
        text(ctx, label, at: CGPoint(x: bar.minX - 2, y: bar.minY - 6), size: 7.5)
    }

    /// 🐱 Points (x, y, error bar, band half-width) with axes; markers + error bars, or a line with a band.
    private static func linePlot(_ ctx: CGContext, in r: CGRect, points: [(Double, Double, Double, Double)], title: String,
                                 xLabel: String, yLabel: String, markers: Bool = true) {
        guard !points.isEmpty else { return }
        let xs = points.map(\.0), ylo = points.map { $0.1 - max($0.2, $0.3) }, yhi = points.map { $0.1 + max($0.2, $0.3) }
        var x0 = xs.min()!, x1 = xs.max()!, y0 = min(ylo.min()!, 0), y1 = max(yhi.max()!, 0)
        if x1 - x0 < 1e-12 { x0 -= 1; x1 += 1 }
        if y1 - y0 < 1e-12 { y0 -= 1; y1 += 1 }
        let padY = (y1 - y0) * 0.06; y0 -= padY; y1 += padY
        func P(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: r.minX + CGFloat((x - x0) / (x1 - x0)) * r.width, y: r.maxY - CGFloat((y - y0) / (y1 - y0)) * r.height)
        }
        // 🐱 ±std band
        ctx.setFillColor(CGColor(red: 0.27, green: 0.45, blue: 0.75, alpha: 0.15))
        ctx.move(to: P(points[0].0, points[0].1 + points[0].3))
        for p in points.dropFirst() { ctx.addLine(to: P(p.0, p.1 + p.3)) }
        for p in points.reversed() { ctx.addLine(to: P(p.0, p.1 - p.3)) }
        ctx.closePath(); ctx.fillPath()
        // 🐱 zero line
        if y0 < 0 && y1 > 0 {
            ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1)); ctx.setLineWidth(0.5)
            ctx.move(to: P(x0, 0)); ctx.addLine(to: P(x1, 0)); ctx.strokePath()
        }
        ctx.setStrokeColor(CGColor(red: 0.13, green: 0.30, blue: 0.62, alpha: 1))
        ctx.setLineWidth(1)
        ctx.move(to: P(points[0].0, points[0].1))
        for p in points.dropFirst() { ctx.addLine(to: P(p.0, p.1)) }
        ctx.strokePath()
        if markers {
            for p in points {
                let c = P(p.0, p.1)
                ctx.move(to: P(p.0, p.1 - p.2)); ctx.addLine(to: P(p.0, p.1 + p.2))
                ctx.strokePath()
                ctx.setFillColor(CGColor(red: 0.13, green: 0.30, blue: 0.62, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
            }
        }
        ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1)); ctx.setLineWidth(0.7)
        ctx.stroke(r)
        for t in ticks(x0, x1) {
            let p = P(t, y0)
            ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 3))
            text(ctx, format(t), at: CGPoint(x: p.x, y: r.maxY + 12), size: 7.5, align: 0.5)
        }
        for t in ticks(y0, y1) {
            let p = P(x0, t)
            ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x - 3, y: p.y))
            text(ctx, format(t), at: CGPoint(x: r.minX - 5, y: p.y + 2.5), size: 7.5, align: 1)
        }
        ctx.strokePath()
        text(ctx, title, at: CGPoint(x: r.minX, y: r.minY - 10), size: 9.5, bold: true)
        text(ctx, xLabel, at: CGPoint(x: r.midX, y: r.maxY + 26), size: 8.5, align: 0.5)
        verticalText(ctx, yLabel, centeredAt: CGPoint(x: r.minX - 40, y: r.midY), size: 8.5)
    }

    // 🐱 MARK: measurement quality

    struct QualityInputs {
        let background: CGImage?
        let frameSize: CGSize
        let mask: MaskOverlay?
        /// 🐱 cells on the image grid (apparent positions) for the uncertainty map
        let cells: [CellStatistics]
        let grid: GridGeometry
        let unit: SpeedUnit
        let mmPerPixel: Double?
        let subpixel: [Int]?
        let peakLocking: Double?
        let diameterPx: Double?
        let uncertaintyMedianPx: Double?
        let profile: [(apparent: Double, truePosition: Double, magnification: Double)]
        let containerTitle: String?
    }

    /// 🐱 (a) masks over the camera image, (b) random uncertainty of single vectors, (c) sub-pixel histogram (peak
    /// 🐱 locking), (d) container lateral magnification — or, without a container, the share of the measured
    /// 🐱 fluctuation that is measurement noise.
    static func quality(_ q: QualityInputs, title: String) -> Output? {
        let panelW: CGFloat = 250
        let aspect = q.frameSize.width > 0 ? q.frameSize.height / q.frameSize.width : 0.6
        let imgH = panelW * aspect
        let field = FieldData(cells: q.cells, grid: q.grid, speedUnit: q.unit, mmPerPixel: q.mmPerPixel)
        let fieldH = panelW * CGFloat(field.extent.height / max(field.extent.width, 1))
        let topH = max(imgH, fieldH)
        let cellW = panelW + 120
        let size = CGSize(width: 2 * cellW + 20, height: 40 + 22 + topH + 70 + 22 + 190 + 60)
        return render(size: size) { ctx in
            text(ctx, title, at: CGPoint(x: 20, y: 22), size: 12, bold: true)
            // 🐱 (a) masks
            let ra = CGRect(x: 65, y: 62, width: panelW, height: imgH)
            text(ctx, "(a) Excluded from the analysis", at: CGPoint(x: ra.minX - 40, y: ra.minY - 8), size: 10, bold: true)
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(ra)
            if let bg = q.background { drawImage(ctx, bg, in: ra) }
            if let m = q.mask, q.frameSize.width > 0 {
                let sx = ra.width / q.frameSize.width, sy = ra.height / q.frameSize.height
                let mr = CGRect(x: ra.minX + m.rect.minX * sx, y: ra.minY + m.rect.minY * sy, width: m.rect.width * sx, height: m.rect.height * sy)
                ctx.saveGState(); ctx.clip(to: ra); drawImage(ctx, m.image, in: mr); ctx.restoreGState()
            }
            ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1)); ctx.setLineWidth(0.7); ctx.stroke(ra)
            let legend: [((UInt8, UInt8, UInt8, UInt8), String)] = [
                (MaskOverlay.staticColor, "outside fluid / wall band / exclusions"), (MaskOverlay.glareColor, "static glare"),
                (MaskOverlay.glintColor, "moving glints (saturated)"),
            ]
            var ly = ra.maxY + 14
            for (c, label) in legend {
                ctx.setFillColor(CGColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 0.85))
                ctx.fill(CGRect(x: ra.minX, y: ly - 7, width: 9, height: 9))
                text(ctx, label, at: CGPoint(x: ra.minX + 14, y: ly + 1), size: 7.5)
                ly += 12
            }
            if let st = q.mask?.statistics {
                text(ctx, String(format: "masked %.1f %% (static %.1f, glare %.1f, glints %.1f)", st.maskedPercent, st.staticPercent, st.glarePercent, st.saturatedPercent),
                     at: CGPoint(x: ra.minX + 150, y: ra.maxY + 15), size: 7.5)
            } else {
                text(ctx, "nothing masked", at: CGPoint(x: ra.minX + 150, y: ra.maxY + 15), size: 7.5)
            }

            // 🐱 (b) random uncertainty map
            let rb = CGRect(x: 20 + cellW + 45, y: 62, width: panelW, height: fieldH)
            text(ctx, "(b) Random uncertainty of one vector (image positions)", at: CGPoint(x: rb.minX - 40, y: rb.minY - 8), size: 10, bold: true)
            let sig = q.cells.map { c in c.valid ? c.measurementUncertainty.map { $0 * q.unit.factor } : nil }
            if sig.contains(where: { $0 != nil }) {
                let r = range(sig, symmetric: false)
                colorField(ctx, field, values: sig, in: rb, cmap: .viridis, lo: 0, hi: r.1)
                colorbar(ctx, at: rb, cmap: .viridis, lo: 0, hi: r.1, label: "σ (\(q.unit.label))")
                axes(ctx, field, in: rb)
            } else {
                ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(rb)
                text(ctx, "not estimated", at: CGPoint(x: rb.midX, y: rb.midY), size: 9, align: 0.5)
            }

            // 🐱 (c) sub-pixel histogram
            let y2 = 62 + topH + 70 + 22
            let rc = CGRect(x: 65, y: y2, width: panelW, height: 160)
            text(ctx, "(c) Sub-pixel part of the displacements", at: CGPoint(x: rc.minX - 40, y: rc.minY - 8), size: 10, bold: true)
            if let h = q.subpixel, h.reduce(0, +) > 0 {
                let total = Double(h.reduce(0, +)), top = Double(h.max() ?? 1) / total
                let bw = rc.width / CGFloat(h.count)
                for (i, c) in h.enumerated() {
                    let f = Double(c) / total
                    let bh = CGFloat(f / (top * 1.1)) * rc.height
                    let central = i >= 5 && i < 15
                    ctx.setFillColor(central ? CGColor(red: 0.13, green: 0.30, blue: 0.62, alpha: 0.85) : CGColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 0.85))
                    ctx.fill(CGRect(x: rc.minX + CGFloat(i) * bw + 0.5, y: rc.maxY - bh, width: bw - 1, height: bh))
                }
                // 🐱 uniform level
                let u = CGFloat((1 / Double(h.count)) / (top * 1.1)) * rc.height
                ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); ctx.setLineWidth(0.6); ctx.setLineDash(phase: 0, lengths: [3, 2])
                ctx.move(to: CGPoint(x: rc.minX, y: rc.maxY - u)); ctx.addLine(to: CGPoint(x: rc.maxX, y: rc.maxY - u)); ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1)); ctx.stroke(rc)
                for t in [-0.5, -0.25, 0.0, 0.25, 0.5] {
                    let x = rc.minX + CGFloat(t + 0.5) * rc.width
                    text(ctx, format(t), at: CGPoint(x: x, y: rc.maxY + 12), size: 7.5, align: 0.5)
                }
                text(ctx, "displacement − nearest integer (analysed px)", at: CGPoint(x: rc.midX, y: rc.maxY + 24), size: 8.5, align: 0.5)
                var note = q.peakLocking.map { String(format: "peak-locking index %.2f (0 = none, 1 = all locked)", $0) } ?? ""
                if let d = q.diameterPx { note += String(format: "%@particle image ≈ %.1f px", note.isEmpty ? "" : "; ", d) }
                text(ctx, note, at: CGPoint(x: rc.minX, y: rc.minY + 10), size: 7.5)
            } else {
                ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(rc)
                text(ctx, "no PIV vectors", at: CGPoint(x: rc.midX, y: rc.midY), size: 9, align: 0.5)
            }

            // 🐱 (d) container magnification, or noise share of the fluctuations
            let rd = CGRect(x: 20 + cellW + 45, y: y2, width: panelW, height: 160)
            if !q.profile.isEmpty {
                let unit = q.mmPerPixel == nil ? "px" : "mm"
                let pts = q.profile.map { ($0.truePosition, $0.magnification, 0.0, 0.0) }
                linePlot(ctx, in: rd, points: pts, title: "(d) Lateral magnification (true / apparent)",
                         xLabel: "position across the container (\(unit), axis = 0)", yLabel: "magnification", markers: false)
                if let c = q.containerTitle {
                    // 🐱 one clause per line so the description fits under the panel
                    var y = rd.maxY + 40
                    for part in c.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        for chunk in part.split(separator: ",", omittingEmptySubsequences: true).chunked(3) {
                            text(ctx, chunk.joined(separator: ",").trimmingCharacters(in: .whitespaces), at: CGPoint(x: rd.minX, y: y), size: 7, gray: 0.3)
                            y += 9
                        }
                    }
                }
            } else {
                text(ctx, "(d) Share of the fluctuation that is noise", at: CGPoint(x: rd.minX - 40, y: rd.minY - 8), size: 10, bold: true)
                let share = q.cells.map { c -> Double? in
                    guard c.valid, let s = c.measurementUncertainty, c.fluctuationRMS > 0 else { return nil }
                    return min(1, s * s / (c.fluctuationRMS * c.fluctuationRMS))
                }
                if share.contains(where: { $0 != nil }) {
                    let rf = CGRect(x: rd.minX, y: rd.minY, width: rd.width, height: min(rd.height, fieldH))
                    colorField(ctx, field, values: share, in: rf, cmap: .viridis, lo: 0, hi: 1)
                    colorbar(ctx, at: rf, cmap: .viridis, lo: 0, hi: 1, label: "σ² / rms²")
                    ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1)); ctx.stroke(rf)
                } else {
                    ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(rd)
                    text(ctx, "not estimated", at: CGPoint(x: rd.midX, y: rd.midY), size: 9, align: 0.5)
                }
            }
            if let u = q.uncertaintyMedianPx {
                text(ctx, String(format: "median σ of single vectors: %.3f px per pair", u), at: CGPoint(x: 20, y: size.height - 12), size: 8, gray: 0.35)
            }
        }
    }

    /// 🐱 CGImage into a y-down context (flipped locally so it is upright).
    /// 🐱 (helper below splits long captions)
    private static func drawImage(_ ctx: CGContext, _ img: CGImage, in r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    // 🐱 MARK: numbers

    static func niceNumber(_ v: Double) -> Double {
        guard v > 0, v.isFinite else { return 1 }
        let m = pow(10, floor(log10(v)))
        return [1.0, 2.0, 5.0, 10.0].map { $0 * m }.last { $0 <= v } ?? m
    }

    static func ticks(_ lo: Double, _ hi: Double, target: Int = 5) -> [Double] {
        guard hi > lo, (hi - lo).isFinite else { return [] }
        let raw = (hi - lo) / Double(target)
        let m = pow(10, floor(log10(raw)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0].map { $0 * m }.first { $0 >= raw } ?? raw
        var t = ceil(lo / step) * step
        var out: [Double] = []
        while t <= hi + step * 1e-9 && out.count < 20 {
            out.append(abs(t) < step * 1e-9 ? 0 : t)
            t += step
        }
        return out
    }

    static func format(_ v: Double) -> String {
        let a = abs(v)
        if a == 0 { return "0" }
        if a >= 1e4 || a < 1e-3 { return String(format: "%.1e", v) }
        if a >= 100 { return String(format: "%.0f", v) }
        if a >= 10 { return String(format: "%.3g", v) }
        return String(format: "%.3g", v)
    }
}

extension Array {
    /// 🐱 Consecutive groups of at most n elements.
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: Swift.max(1, n)).map { Array(self[$0..<Swift.min(count, $0 + n)]) }
    }
}
