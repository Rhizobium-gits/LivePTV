import Foundation

/// 🐱 Iterative image deformation (Scarano 2002, "WIDIM"): before a correlation pass, both frames are resampled with the
/// 🐱 previous pass's field d(x), frame A at x − d(x)/2 and frame B at x + d(x)/2 (symmetric, central difference).
/// 🐱 Windows are then copied at their nominal integer positions and correlated; the measured residual r is added to
/// 🐱 the predictor at the window centre. Unlike a window shift, the deformed windows follow velocity gradients inside
/// 🐱 them, so the spatial response is no longer that of a plain top-hat average over the window.
/// 🐱
/// 🐱 The CPU and the GPU (`MetalCorrelator`) do exactly the same arithmetic, so their deformed frames are identical:
/// 🐱 the predictor is interpolated in Float with explicit fused multiply-adds in a fixed order, and the Lanczos-4 weights
/// 🐱 come from one shared table (fraction steps of 1/4096 px, at most 1.2·10⁻⁴ px from the exact phase).
public enum ImageDeformation {
    /// 🐱 Fraction steps of the weight table.
    static let tableSteps = 4096

    /// 🐱 Lanczos-4 weights (taps −3 … 4, each row normalised to sum 1) for fractions k / 4096, k = 0 … 4096. Row 4096
    /// 🐱 (fraction 1) puts the whole weight on tap +1, which is the same as the next pixel at fraction 0.
    static let lanczosTable: [Float] = {
        var t = [Float](repeating: 0, count: (tableSteps + 1) * 8)
        let k = CorrelationWork.SubpixelKernel.lanczos4
        for i in 0...tableSteps {
            let w = k.weights(Float(Double(i) / Double(tableSteps)))
            for j in 0..<8 { t[i * 8 + j] = w[j] }
        }
        return t
    }()

    /// 🐱 Node values of a field (own pixel units) as Float pairs, the layout the GPU reads, and the interpolation
    /// 🐱 used for deforming: Keys cubic convolution (a = −0.5) between the nodes, node indices clamped at the grid
    /// 🐱 edges. Bilinear interpolation is not good enough here: between nodes it cuts the curvature of the field, so
    /// 🐱 the deformation removes less than the predictor at the node and the iteration converges to an amplitude
    /// 🐱 above 1 (measured +3 % at λ = 5 windows, as the model cos²(πh/λ) predicts); a cubic interpolant does not.
    struct Grid {
        /// 🐱 Ghost nodes on each side, filled by linear extrapolation of the outermost nodes. Pixels between the outermost
        /// 🐱 window centres and the image edge lie up to ~2 steps outside the grid; holding the field constant there
        /// 🐱 (clamping) makes the deformation of an edge window flat on its outer half, which biased edge vectors in a
        /// 🐱 shear flow by ≈3 px of position. A linear extension follows the gradient instead.
        static let pad = 4
        let cols: Int, rows: Int
        let originX: Float, originY: Float, invStep: Float
        /// 🐱 Padded node values, (cols + 2·pad) × (rows + 2·pad), row-major.
        let dx: [Float], dy: [Float]
        var paddedColumns: Int { cols + 2 * Self.pad }
        var paddedRows: Int { rows + 2 * Self.pad }

        init(_ f: PIVField) {
            cols = f.columns; rows = f.rows
            originX = Float(f.originX); originY = Float(f.originY); invStep = Float(1 / f.step)
            dx = Self.padded(f.dx, cols, rows).map { Float($0) }
            dy = Self.padded(f.dy, cols, rows).map { Float($0) }
        }

        /// 🐱 Linear extrapolation along x for every row, then along y for every (padded) column.
        static func padded(_ v: [Double], _ cols: Int, _ rows: Int) -> [Double] {
            let pc = cols + 2 * pad, pr = rows + 2 * pad
            var out = [Double](repeating: 0, count: pc * pr)
            func ext(_ at: (Int) -> Double, _ n: Int, _ i: Int) -> Double {
                if i >= 0 && i < n { return at(i) }
                guard n >= 2 else { return at(0) }
                return i < 0 ? at(0) + Double(i) * (at(1) - at(0)) : at(n - 1) + Double(i - n + 1) * (at(n - 1) - at(n - 2))
            }
            for j in 0..<rows {
                for i in -pad..<(cols + pad) { out[(j + pad) * pc + i + pad] = ext({ v[j * cols + $0] }, cols, i) }
            }
            for i in 0..<pc {
                for j in -pad..<(rows + pad) where j < 0 || j >= rows {
                    out[(j + pad) * pc + i] = ext({ out[($0 + pad) * pc + i] }, rows, j)
                }
            }
            return out
        }

        /// 🐱 Keys weights of nodes i0−1 … i0+2 at fraction t, written with explicit fused multiply-adds (the GPU does
        /// 🐱 the same operations).
        @inline(__always)
        static func cubic(_ t: Float) -> (Float, Float, Float, Float) {
            let tt = t * t
            let w0 = t * (-0.5 as Float).addingProduct(t, (1 as Float).addingProduct(-0.5, t))
            let w1 = (1 as Float).addingProduct(tt, (-2.5 as Float).addingProduct(1.5, t))
            let w2 = t * (0.5 as Float).addingProduct(t, (2 as Float).addingProduct(-1.5, t))
            let w3 = tt * (-0.5 as Float).addingProduct(0.5, t)
            return (w0, w1, w2, w3)
        }

        /// 🐱 Padded node indices (i0 − 1 … i0 + 2, shifted by `pad`) and weights along one axis at image coordinate i.
        @inline(__always)
        static func axis(_ i: Float, _ origin: Float, _ invStep: Float, _ nodes: Int) -> (Int, Int, Int, Int, (Float, Float, Float, Float)) {
            let p = min(max((i - origin) * invStep, Float(1 - pad)), Float(nodes + pad - 3))
            let fl = p.rounded(.down)
            let i0 = Int(fl) + pad
            return (i0 - 1, i0, i0 + 1, i0 + 2, cubic(p - fl))
        }

        /// 🐱 Σ_r wy_r · Σ_c wx_c · n[r][c], in this order (as on the GPU).
        @inline(__always)
        static func sum(_ n: UnsafePointer<Float>, _ cols: Int, _ cx: (Int, Int, Int, Int), _ wx: (Float, Float, Float, Float),
                        _ ry: (Int, Int, Int, Int), _ wy: (Float, Float, Float, Float)) -> Float {
            @inline(__always) func row(_ r: Int) -> Float {
                let b = n + r * cols
                var h = b[cx.0] * wx.0
                h = h.addingProduct(b[cx.1], wx.1)
                h = h.addingProduct(b[cx.2], wx.2)
                return h.addingProduct(b[cx.3], wx.3)
            }
            var d = row(ry.0) * wy.0
            d = d.addingProduct(row(ry.1), wy.1)
            d = d.addingProduct(row(ry.2), wy.2)
            return d.addingProduct(row(ry.3), wy.3)
        }

        /// 🐱 Interpolated displacement at an image point (the value the deformation used there).
        func value(x: Double, y: Double) -> (dx: Double, dy: Double) {
            let ax = Self.axis(Float(x), originX, invStep, cols), ay = Self.axis(Float(y), originY, invStep, rows)
            let cx = (ax.0, ax.1, ax.2, ax.3), ry = (ay.0, ay.1, ay.2, ay.3), pc = paddedColumns
            let u = dx.withUnsafeBufferPointer { Self.sum($0.baseAddress!, pc, cx, ax.4, ry, ay.4) }
            let v = dy.withUnsafeBufferPointer { Self.sum($0.baseAddress!, pc, cx, ax.4, ry, ay.4) }
            return (Double(u), Double(v))
        }
    }

    /// 🐱 out(x, y) = src(x + sign·d(x, y)), with d interpolated between the field's nodes (`Grid`) and reads outside
    /// 🐱 the image clamped to the border pixel. `sign` is −0.5 for frame A and +0.5 for frame B. `lanczos` false:
    /// 🐱 bilinear resampling.
    public static func deform(_ src: [Float], width W: Int, height H: Int, field: PIVField, sign: Float, lanczos: Bool) -> [Float] {
        precondition(src.count == W * H)
        let g = Grid(field)
        var out = [Float](repeating: 0, count: W * H)
        guard W > 0, H > 0, g.cols > 0, g.rows > 0 else { return src }
        // 🐱 per column / row: nodes and weights (the same arithmetic the GPU does per pixel)
        let colAxis = (0..<W).map { Grid.axis(Float($0), g.originX, g.invStep, g.cols) }
        let rowAxis = (0..<H).map { Grid.axis(Float($0), g.originY, g.invStep, g.rows) }
        let steps = Float(tableSteps)
        src.withUnsafeBufferPointer { sb in
            out.withUnsafeMutableBufferPointer { ob in
                g.dx.withUnsafeBufferPointer { gxb in
                    g.dy.withUnsafeBufferPointer { gyb in
                        lanczosTable.withUnsafeBufferPointer { tb in
                            let S = sb.baseAddress!, O = ob.baseAddress!, GX = gxb.baseAddress!, GY = gyb.baseAddress!
                            let T = tb.baseAddress!
                            let chunks = min(H, 64)
                            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                                colAxis.withUnsafeBufferPointer { cab in
                                    let CA = cab.baseAddress!
                                    var y = c * H / chunks
                                    let end = (c + 1) * H / chunks
                                    let cols = g.paddedColumns, lastX = W - 1, lastY = H - 1
                                    while y < end {
                                        let ay = rowAxis[y]
                                        let ry = (ay.0, ay.1, ay.2, ay.3), wy4 = ay.4
                                        var x = 0
                                        while x < W {
                                            let ax = CA[x]
                                            let cx = (ax.0, ax.1, ax.2, ax.3)
                                            let dxp = Grid.sum(GX, cols, cx, ax.4, ry, wy4), dyp = Grid.sum(GY, cols, cx, ax.4, ry, wy4)
                                            let px = Float(x).addingProduct(sign, dxp), py = Float(y).addingProduct(sign, dyp)
                                            let fxf = px.rounded(.down), fyf = py.rounded(.down)
                                            let ix = Int(fxf), iy = Int(fyf)
                                            let fx = px - fxf, fy = py - fyf
                                            if lanczos {
                                                let half: Float = 0.5
                                                let wx = T + Int(half.addingProduct(fx, steps)) * 8, wy = T + Int(half.addingProduct(fy, steps)) * 8
                                                var acc: Float = 0
                                                if ix >= 3 && ix + 4 <= lastX && iy >= 3 && iy + 4 <= lastY {
                                                    var r = 0
                                                    while r < 8 {
                                                        let row = S + (iy - 3 + r) * W + ix - 3
                                                        var h = row[0] * wx[0]
                                                        var k = 1
                                                        while k < 8 { h = h.addingProduct(row[k], wx[k]); k += 1 }
                                                        acc = r == 0 ? h * wy[0] : acc.addingProduct(h, wy[r])
                                                        r += 1
                                                    }
                                                } else {
                                                    var r = 0
                                                    while r < 8 {
                                                        let row = S + min(max(iy - 3 + r, 0), lastY) * W
                                                        var h = row[min(max(ix - 3, 0), lastX)] * wx[0]
                                                        var k = 1
                                                        while k < 8 { h = h.addingProduct(row[min(max(ix - 3 + k, 0), lastX)], wx[k]); k += 1 }
                                                        acc = r == 0 ? h * wy[0] : acc.addingProduct(h, wy[r])
                                                        r += 1
                                                    }
                                                }
                                                O[y * W + x] = acc
                                            } else {
                                                let x0 = min(max(ix, 0), lastX), x1 = min(max(ix + 1, 0), lastX)
                                                let y0 = min(max(iy, 0), lastY), y1 = min(max(iy + 1, 0), lastY)
                                                let v00 = S[y0 * W + x0], v10 = S[y0 * W + x1], v01 = S[y1 * W + x0], v11 = S[y1 * W + x1]
                                                let top = v00.addingProduct(v10 - v00, fx), bottom = v01.addingProduct(v11 - v01, fx)
                                                O[y * W + x] = top.addingProduct(bottom - top, fy)
                                            }
                                            x += 1
                                        }
                                        y += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// 🐱 Share of valid vectors (among windows that are not masked) below which a pass does not deform: the field
    /// 🐱 would mostly be replaced or filtered noise, and resampling both frames with it destroys more correlation than
    /// 🐱 a single window shift does (very faint, sparse images; use ensemble correlation there).
    static let minValidShare = 0.5

    /// 🐱 The field to deform with, from the previous pass (nil: do not deform this pass, see `minValidShare`).
    /// 🐱
    /// 🐱 Deformation adds the predictor at the window centre to the residual measured over the window, so predictor
    /// 🐱 noise partly propagates: in uniform flow the final error grows with the predictor noise (measured: RMS ×1.2–2
    /// 🐱 with no filter). The filter is therefore noise-adaptive. Both a 3 × 3 binomial (s₁) and its square, ≈ 5 × 5
    /// 🐱 (s₂), are computed; where they differ by no more than noise would explain, the field is locally smooth and
    /// 🐱 s₂ is used (less noise, nothing to resolve); where they differ more, there is structure and s₁ is kept
    /// 🐱 (Schrijer & Scarano 2008 for the need to filter at all). The noise σₙ of the raw field is estimated robustly from
    /// 🐱 the residuals to the neighbour medians. The noise of s₁ − s₂ is ≈ 0.14 σₙ; the blend goes from s₂ at 0.3 σₙ to
    /// 🐱 s₁ at 0.6 σₙ.
    static func predictor(from f: PIVField, smoothing: Bool) -> PIVField? {
        let n = f.count
        guard n > 0 else { return nil }
        var valid = 0, unmasked = 0
        var k = 0
        while k < n {
            if f.status[k] != .masked { unmasked += 1 }
            if f.status[k] == .valid { valid += 1 }
            k += 1
        }
        guard unmasked > 0, Double(valid) >= minValidShare * Double(unmasked) else { return nil }
        let filled = filledEverywhere(f)
        guard smoothing else { return filled }
        let s1 = smoothed(filled), s2 = smoothed(s1)
        guard let sigma = noiseLevel(f), sigma > 0 else { return s1 }
        var out = s1
        k = 0
        while k < n {
            let d = max(abs(s1.dx[k] - s2.dx[k]), abs(s1.dy[k] - s2.dy[k]))
            let a = min(1, max(0, (d - 0.3 * sigma) / (0.3 * sigma)))   // 0: s₂, 1: s₁
            out.dx[k] = s2.dx[k] + a * (s1.dx[k] - s2.dx[k])
            out.dy[k] = s2.dy[k] + a * (s1.dy[k] - s2.dy[k])
            k += 1
        }
        return out
    }

    /// 🐱 Robust noise level of a field (px): 1.4826 × median |u − median of the usable 8-neighbours| over the valid
    /// 🐱 cells (both components), divided by 1.13 for the noise of the neighbours' median itself. Nil without data.
    static func noiseLevel(_ f: PIVField) -> Double? {
        let cols = f.columns, rows = f.rows, n = cols * rows
        var usable = [UInt8](repeating: 0, count: n)
        var k = 0
        while k < n { if f.status[k] == .valid { usable[k] = 1 }; k += 1 }
        let med = GridKernels.neighbourMedians(u: f.dx, v: f.dy, usable: usable, targets: usable, columns: cols, rows: rows)
        var r: [Double] = []
        r.reserveCapacity(2 * n)
        k = 0
        while k < n {
            if med.found[k] != 0 { r.append(abs(f.dx[k] - med.u[k])); r.append(abs(f.dy[k] - med.v[k])) }
            k += 1
        }
        guard let m = GridKernels.median(of: r) else { return nil }
        return 1.4826 * m / 1.13
    }

    /// 🐱 Every cell without a measured value (masked, or invalid and not replaced) gets one: the median of its usable
    /// 🐱 8-neighbours, ring by ring inwards from the measured cells; cells no ring reaches take the median of all
    /// 🐱 measured cells. The deformation interpolates between 4 × 4 nodes, so it reads cells up to two steps away: a
    /// 🐱 masked cell left at 0 (or an invalid one left at its wrong value) would bend the deformation next to a mask
    /// 🐱 (measured: RMS error next to a glare stripe 0.046 → 0.117 px over three iterations). All statuses become valid.
    static func filledEverywhere(_ f: PIVField) -> PIVField {
        let cols = f.columns, rows = f.rows, n = cols * rows
        var g = f
        var have = [UInt8](repeating: 0, count: n)
        var measured: [Double] = [], measuredV: [Double] = []
        var k = 0
        while k < n {
            if f.status[k] == .valid || f.status[k] == .replaced { have[k] = 1; measured.append(f.dx[k]); measuredV.append(f.dy[k]) }
            k += 1
        }
        var missing = n - measured.count
        var ring = 0
        while missing > 0 && ring < max(cols, rows) {
            var targets = [UInt8](repeating: 0, count: n)
            k = 0
            while k < n { targets[k] = have[k] == 0 ? 1 : 0; k += 1 }
            let r = GridKernels.neighbourMedians(u: g.dx, v: g.dy, usable: have, targets: targets, columns: cols, rows: rows,
                                                 minNeighbours: 1)
            var added = 0
            k = 0
            while k < n {
                if r.found[k] != 0 { g.dx[k] = r.u[k]; g.dy[k] = r.v[k]; have[k] = 1; added += 1 }
                k += 1
            }
            if added == 0 { break }
            missing -= added
            ring += 1
        }
        if missing > 0 {
            let mu = GridKernels.median(of: measured) ?? 0, mv = GridKernels.median(of: measuredV) ?? 0
            k = 0
            while k < n { if have[k] == 0 { g.dx[k] = mu; g.dy[k] = mv }; k += 1 }
        }
        k = 0
        while k < n { g.status[k] = .valid; k += 1 }
        return g
    }

    /// 🐱 Predictor filter between passes: 3 × 3 binomial (1-2-1 ⊗ 1-2-1) over the cells that hold a usable value
    /// 🐱 (all of them after `filledEverywhere`), weights renormalised at the grid border.
    /// 🐱 Without it, structures smaller than a window can be amplified from one iteration to the next (Schrijer &
    /// 🐱 Scarano 2008); the residual measured on the deformed frames restores what the filter takes away.
    static func smoothed(_ f: PIVField) -> PIVField {
        let cols = f.columns, rows = f.rows
        var g = f
        guard cols > 1 || rows > 1 else { return f }
        let w1: [Double] = [1, 2, 1]
        var j = 0
        while j < rows {
            var i = 0
            while i < cols {
                var su = 0.0, sv = 0.0, sw = 0.0
                var b = -1
                while b <= 1 {
                    let jj = j + b
                    if jj >= 0 && jj < rows {
                        var a = -1
                        while a <= 1 {
                            let ii = i + a
                            if ii >= 0 && ii < cols {
                                let q = jj * cols + ii
                                if f.status[q] != .invalid {
                                    let w = w1[a + 1] * w1[b + 1]
                                    su += w * f.dx[q]; sv += w * f.dy[q]; sw += w
                                }
                            }
                            a += 1
                        }
                    }
                    b += 1
                }
                let k = j * cols + i
                if sw > 0 { g.dx[k] = su / sw; g.dy[k] = sv / sw }
                i += 1
            }
            j += 1
        }
        return g
    }
}
