import Accelerate
import Foundation

/// 🐱 Particle image velocimetry settings (cross-correlation of interrogation windows).
public struct PIVParameters: Codable, Equatable, Sendable {
    /// 🐱 Interrogation window size per pass (powers of two, decreasing), e.g. [64, 32]: the first pass predicts,
    /// 🐱 later passes shift their windows by the predicted displacement (multi-pass window offset).
    public var windowSizes: [Int] = [64, 32]
    /// 🐱 Overlap of the final pass (0.5 = 50 %): vector spacing = window × (1 − overlap).
    public var overlap = 0.5
    /// 🐱 Repeat the final pass with its own result as predictor (sub-pixel window shift converges, removing the
    /// 🐱 peak-locking bias of integer offsets).
    public var finalIterations = 2
    /// 🐱 Correlate frame i with frame i − pairSpacing. Raise it for slow flows (larger displacements per pair),
    /// 🐱 as when a 30 fps video is analysed at 6 fps (pairSpacing 5).
    public var pairSpacing = 1
    /// 🐱 Clip bright outliers (reflections, large particles) to mean + 2σ so they do not dominate correlation.
    /// 🐱 Off by default (as in PIVlab): on faint, sparse particle images σ is mostly noise, so the cap clips the
    /// 🐱 particles themselves (single-pair valid vectors 49 % → 16 % in the ensemble test images); with local
    /// 🐱 contrast normalisation it no longer helped on dense images either.
    public var intensityCapping = false
    /// 🐱 Subtract a box-blurred copy (radius px) to remove uneven background; 0 = off. (Not used when local
    /// 🐱 contrast normalisation is on, which includes it.)
    public var highPassRadius = 7
    /// 🐱 Local contrast normalisation (min–max / CLAHE-like): (I − local mean) / local standard deviation over a
    /// 🐱 box of this radius. Evens out lighting gradients, vignetting, haze and faint particles. 0 = off.
    public var normalizationRadius = 12
    /// 🐱 Vectors whose normalised correlation peak is below this are invalid. Pure noise in a 32×32 window peaks at
    /// 🐱 ≈0.11 (σ ≈ 1/32, maximum of 1024 values), so 0.2 is ≈6σ above chance.
    public var minCorrelation = 0.2
    /// 🐱 Windows with intensity standard deviation below this (grey levels) carry no pattern: invalid.
    public var minWindowContrast: Float = 1.5
    /// 🐱 Normalised median test (Westerweel & Scarano 2005) on displacements.
    public var validationThreshold = 2.0
    public var validationEpsilonPx = 0.1
    /// 🐱 Replace invalid vectors with the median of valid neighbours (flagged as replaced, excluded from statistics).
    public var replaceInvalid = true
    /// 🐱 Save every n-th instantaneous field to piv_vectors.csv while recording (0 = never).
    public var saveEveryNthField = 30
    /// 🐱 Adapt the pair spacing so the typical displacement is about `targetDisplacementPx` (in analysed pixels):
    /// 🐱 slow flows get pairs further apart in time, so sub-pixel motion becomes measurable.
    public var autoPairSpacing = true
    public var targetDisplacementPx = 2.0
    public var maxPairSpacing = 30
    /// 🐱 Ensemble correlation (averaged correlation planes), see EnsembleCorrelator.
    public var ensemble = EnsembleParameters()
    /// 🐱 A window whose masked share (container wall, glare, saturated blobs, exclusions) exceeds this gets no
    /// 🐱 vector (status `masked`): it is neither validated, replaced nor used in statistics.
    public var maxMaskedFraction = 0.4
    /// 🐱 Random uncertainty of every final-pass vector from correlation statistics (after Wieneke 2015).
    public var uncertainty = true
    /// 🐱 Interpolation for the sub-pixel window shift of the final passes (predictor passes always use bilinear).
    public var windowInterpolation: WindowInterpolation = .lanczos4

    public enum WindowInterpolation: String, Codable, CaseIterable, Sendable {
        /// 🐱 2×2 taps: fast, but its asymmetric kernel skews the correlation peak (≈0.03–0.09 px systematic error)
        case bilinear
        /// 🐱 8×8 windowed sinc: systematic error ≈0.002 px for 3-px particle images (measured, see tests)
        case lanczos4
    }

    public init() {}

    public var finalWindow: Int { windowSizes.last ?? 32 }
    public var finalStep: Int { max(1, Int((Double(finalWindow) * (1 - overlap)).rounded())) }
}

/// 🐱 One PIV vector field between two frames, on a regular grid of window centres (full-frame px).
public struct PIVField: Sendable {
    /// 🐱 `masked`: the window lies mostly in a masked area (outside the fluid, wall band, glare); no measurement.
    public enum Status: UInt8, Codable, Sendable { case valid = 0, replaced = 1, invalid = 2, masked = 3 }

    public var columns: Int
    public var rows: Int
    /// 🐱 Centre of window (0, 0), full-frame px.
    public var originX: Double
    public var originY: Double
    public var step: Double
    public var windowSize: Int
    /// 🐱 Displacement over the pair (px) and the pair's time interval (s).
    public var dx: [Double]
    public var dy: [Double]
    public var dt: Double
    public var status: [Status]
    /// 🐱 Normalised correlation coefficient of the peak (0...1).
    public var correlation: [Float]
    /// 🐱 Standard uncertainty of dx / dy per vector (px, correlation statistics); empty when not estimated.
    public var sigmaX: [Float] = []
    public var sigmaY: [Float] = []
    /// 🐱 Median particle-image diameter (e⁻² diameter, px) implied by the width of the correlation peaks of the
    /// 🐱 valid final-pass windows: d ≈ 2√2·σ_peak. Below ≈2 px the sub-pixel fit locks to integers (peak locking).
    public var particleImageDiameterPx: Double? = nil

    public var count: Int { columns * rows }
    public func x(_ k: Int) -> Double { originX + Double(k % columns) * step }
    public func y(_ k: Int) -> Double { originY + Double(k / columns) * step }
    public var validCount: Int { status.filter { $0 == .valid }.count }
    public var replacedCount: Int { status.filter { $0 == .replaced }.count }
    public var maskedCount: Int { status.filter { $0 == .masked }.count }
    /// 🐱 Valid or replaced (a displacement exists); invalid and masked windows have none.
    public func isMeasured(_ k: Int) -> Bool { status[k] == .valid || status[k] == .replaced }
    /// 🐱 Per-component standard uncertainty (px) of vector k, if estimated.
    public func sigma(_ k: Int) -> Double? {
        guard k < sigmaX.count, k < sigmaY.count, sigmaX[k] > 0 || sigmaY[k] > 0 else { return nil }
        return sqrt((Double(sigmaX[k]) * Double(sigmaX[k]) + Double(sigmaY[k]) * Double(sigmaY[k])) / 2)
    }

    /// 🐱 Grid whose cells are centred on the vectors (for statistics and heatmaps).
    public var cellGrid: GridGeometry {
        GridGeometry(originX: originX - step / 2, originY: originY - step / 2, cellSize: step, columns: columns, rows: rows)
    }

    /// 🐱 Vectors as velocity samples (trackID = grid index). Replaced/invalid vectors are flagged as outliers.
    public func samples(frameIndex: Int, midTime: Double) -> [VelocitySample] {
        guard dt > 0 else { return [] }
        var out: [VelocitySample] = []
        out.reserveCapacity(count)
        var k = 0
        while k < count {
            if isMeasured(k) {
                out.append(VelocitySample(trackID: k, frameIndex: frameIndex, x: x(k), y: y(k), t: midTime, dx: dx[k], dy: dy[k], dt: dt,
                                          u: dx[k] / dt, v: dy[k] / dt, outlier: status[k] != .valid, sigma: sigma(k)))
            }
            k += 1
        }
        return out
    }
}

/// 🐱 A frame after PIV pre-processing (computed once per frame and reused for both pairs it belongs to).
public struct PIVImage: Sendable {
    public let width: Int
    public let height: Int
    public let originX: Int
    public let originY: Int
    public let scale: Int
    public let pixels: [Float]
    /// 🐱 1 = usable pixel, 0 = masked (same layout as `pixels`); nil = nothing masked.
    public let mask: [Float]?

    public init(width: Int, height: Int, originX: Int, originY: Int, scale: Int, pixels: [Float], mask: [Float]? = nil) {
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        self.scale = scale
        self.pixels = pixels
        self.mask = mask
    }

    /// 🐱 Share of usable pixels in a w×w box around every pixel (nil when nothing is masked).
    public func coverage(window w: Int) -> [Float]? {
        guard let m = mask, width > w, height > w else { return nil }
        return PIVEngine.boxBlur(m, width, height, radius: max(1, w / 2))
    }
}

/// 🐱 FFT cross-correlation PIV with multi-pass window offset, 3-point Gaussian sub-pixel peaks, correlation and
/// 🐱 normalised-median validation, and median replacement. Windows are processed in parallel.
public final class PIVEngine: @unchecked Sendable {
    public var parameters: PIVParameters
    private var setup: FFTSetup?
    private var setupLog2 = 0

    public init(parameters: PIVParameters = PIVParameters()) { self.parameters = parameters }

    deinit { if let s = setup { vDSP_destroy_fftsetup(s) } }

    func fftSetup(maxLog2: Int) -> FFTSetup {
        if let s = setup, setupLog2 >= maxLog2 { return s }
        if let s = setup { vDSP_destroy_fftsetup(s) }
        setup = vDSP_create_fftsetup(vDSP_Length(maxLog2), FFTRadix(kFFTRadix2))
        setupLog2 = maxLog2
        return setup!
    }

    /// 🐱 `mask` (1 usable, 0 masked; same layout as the image): masked pixels are first set to the mean of the usable
    /// 🐱 ones (so glare or a wall edge does not leak into the local normalisation around it), and zeroed after
    /// 🐱 pre-processing, so they add nothing to any correlation.
    public func prepare(_ img: LumaImage, mask: [Float]? = nil) -> PIVImage {
        guard let m = mask, m.count == img.pixels.count else {
            return PIVImage(width: img.width, height: img.height, originX: img.originX, originY: img.originY, scale: img.scale, pixels: preprocess(img))
        }
        let n = m.count
        var filled = img
        var usable: Float = 0, sum: Float = 0
        vDSP_sve(m, 1, &usable, vDSP_Length(n))
        vDSP_dotpr(img.pixels, 1, m, 1, &sum, vDSP_Length(n))
        var mean = usable > 0 ? sum / usable : 0
        // 🐱 I·m + mean·(1 − m) = (I − mean)·m + mean
        var negMean = -mean
        vDSP_vsadd(img.pixels, 1, &negMean, &filled.pixels, 1, vDSP_Length(n))
        vDSP_vmul(filled.pixels, 1, m, 1, &filled.pixels, 1, vDSP_Length(n))
        vDSP_vsadd(filled.pixels, 1, &mean, &filled.pixels, 1, vDSP_Length(n))
        var px = preprocess(filled)
        vDSP_vmul(px, 1, m, 1, &px, 1, vDSP_Length(n))
        return PIVImage(width: img.width, height: img.height, originX: img.originX, originY: img.originY, scale: img.scale, pixels: px, mask: m)
    }

    /// 🐱 Pre-processing shared by both frames: intensity capping, then local contrast normalisation (or high-pass).
    public func preprocess(_ img: LumaImage) -> [Float] {
        var px = img.pixels
        let n = px.count
        let w = img.width, h = img.height
        if parameters.intensityCapping, n > 0 {
            var mean: Float = 0, sd: Float = 0
            vDSP_normalize(px, 1, nil, 1, &mean, &sd, vDSP_Length(n))
            let cap = mean + 2 * sd
            var lo: Float = 0, hi = cap
            vDSP_vclip(px, 1, &lo, &hi, &px, 1, vDSP_Length(n))
        }
        let nr = parameters.normalizationRadius
        if nr > 0, w > 2 * nr, h > 2 * nr {
            // 🐱 (I − μ) / (σ + ε) with μ, σ from box sums of I and I² (all vDSP)
            let mean = Self.boxBlur(px, w, h, radius: nr)
            var sq = [Float](repeating: 0, count: n)
            vDSP_vsq(px, 1, &sq, 1, vDSP_Length(n))
            let meanSq = Self.boxBlur(sq, w, h, radius: nr)
            var mean2 = [Float](repeating: 0, count: n), variance = mean2, sd = mean2
            vDSP_vsq(mean, 1, &mean2, 1, vDSP_Length(n))
            vDSP_vsub(mean2, 1, meanSq, 1, &variance, 1, vDSP_Length(n))
            var zero: Float = 0, big: Float = .greatestFiniteMagnitude
            vDSP_vclip(variance, 1, &zero, &big, &variance, 1, vDSP_Length(n))
            var count = Int32(n)
            vvsqrtf(&sd, variance, &count)
            // 🐱 ε ≈ sensor noise level, so flat regions are not amplified into noise patterns
            var eps: Float = 2
            vDSP_vsadd(sd, 1, &eps, &sd, 1, vDSP_Length(n))
            vDSP_vsub(mean, 1, px, 1, &px, 1, vDSP_Length(n))
            vDSP_vdiv(sd, 1, px, 1, &px, 1, vDSP_Length(n))
            // 🐱 back to a grey-level-like range so contrast thresholds keep their meaning
            var gain: Float = 32
            vDSP_vsmul(px, 1, &gain, &px, 1, vDSP_Length(n))
            return px
        }
        let r = parameters.highPassRadius
        if r > 0, w > 2 * r, h > 2 * r {
            // 🐱 separable box blur via running sums, then subtract
            // 🐱 separable box blur (edges replicated) with vDSP sliding-window sums, then subtract
            let blur = Self.boxBlur(px, w, h, radius: r)
            vDSP_vsub(blur, 1, px, 1, &px, 1, vDSP_Length(n))
        }
        return px
    }

    /// 🐱 Box blur of radius r with replicated edges: rows, transpose, rows, transpose (all vDSP).
    static func boxBlur(_ src: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        func rows(_ a: [Float], _ cols: Int, _ nrows: Int) -> [Float] {
            var out = [Float](repeating: 0, count: a.count)
            let norm = 1 / Float(2 * r + 1)
            a.withUnsafeBufferPointer { A in
                out.withUnsafeMutableBufferPointer { O in
                    let ap = A.baseAddress!, op = O.baseAddress!
                    // 🐱 rows in chunks (one scratch row per chunk; few closures per pass)
                    let chunks = min(nrows, 16)
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        let pp = UnsafeMutablePointer<Float>.allocate(capacity: cols + 2 * r)
                        defer { pp.deallocate() }
                        var y = c * nrows / chunks
                        let end = (c + 1) * nrows / chunks
                        while y < end {
                            let row = ap + y * cols
                            memcpy(pp + r, row, cols * MemoryLayout<Float>.size)
                            var first = row[0], last = row[cols - 1]
                            vDSP_vfill(&first, pp, 1, vDSP_Length(r))
                            vDSP_vfill(&last, pp + r + cols, 1, vDSP_Length(r))
                            vDSP_vswsum(pp, 1, op + y * cols, 1, vDSP_Length(cols), vDSP_Length(2 * r + 1))
                            var k = norm
                            vDSP_vsmul(op + y * cols, 1, &k, op + y * cols, 1, vDSP_Length(cols))
                            y += 1
                        }
                    }
                }
            }
            return out
        }
        var t = [Float](repeating: 0, count: src.count)
        let horizontal = rows(src, w, h)
        vDSP_mtrans(horizontal, 1, &t, 1, vDSP_Length(w), vDSP_Length(h))   // 🐱 h×w → w×h
        let vertical = rows(t, h, w)
        var out = [Float](repeating: 0, count: src.count)
        vDSP_mtrans(vertical, 1, &out, 1, vDSP_Length(h), vDSP_Length(w))
        return out
    }

    /// 🐱 Vector field between `a` (earlier) and `b` (later) frames of the same ROI. Nil if the ROI is too small.
    public func compute(a: LumaImage, b: LumaImage, dt: Double) -> PIVField? {
        compute(a: prepare(a), b: prepare(b), dt: dt)
    }

    /// 🐱 Same, for frames already pre-processed with `prepare` (the pipeline prepares each frame once).
    public func compute(a: PIVImage, b: PIVImage, dt: Double) -> PIVField? {
        guard a.width == b.width, a.height == b.height, let first = parameters.windowSizes.first,
              a.width >= first, a.height >= first else { return nil }
        let A = a.pixels, B = b.pixels
        let W = a.width, H = a.height
        let sizes = parameters.windowSizes.map { Self.effectiveWindow($0) }
        let setup = fftSetup(maxLog2: Int(log2(Double(sizes.max()!))))
        // 🐱 a pixel is usable only if it is usable in both frames (dynamic glare differs per frame)
        let mask = Self.combinedMask(a.mask, b.mask, count: A.count)
        let maskedImage = PIVImage(width: W, height: H, originX: a.originX, originY: a.originY, scale: a.scale, pixels: [], mask: mask)
        let minCoverage = Float(1 - max(0, min(1, parameters.maxMaskedFraction)))
        var predictor: PIVField?
        var result: PIVField?
        let schedule = sizes.dropLast().map { ($0, false) } + Array(repeating: (sizes.last!, true), count: max(1, parameters.finalIterations))
        for (pass, (w, final)) in schedule.enumerated() {
            let last = pass == schedule.count - 1
            let step = final ? max(1, Int((Double(w) * (1 - parameters.overlap)).rounded())) : max(1, w / 2)
            guard W >= w, H >= w else { break }
            let cols = (W - w) / step + 1, rows = (H - w) / step + 1
            let n = cols * rows
            // 🐱 computed in this image's own pixel units (origin 0); converted to full-frame px at the end
            var field = PIVField(columns: cols, rows: rows, originX: Double(w) / 2, originY: Double(w) / 2,
                                 step: Double(step), windowSize: w, dx: .init(repeating: 0, count: n),
                                 dy: .init(repeating: 0, count: n), dt: dt,
                                 status: .init(repeating: .invalid, count: n), correlation: .init(repeating: 0, count: n))
            let pred = predictor
            let params = parameters
            let kernel: CorrelationWork.SubpixelKernel? = final && params.windowInterpolation == .lanczos4 ? .lanczos4 : nil
            let coverage = maskedImage.coverage(window: w)
            let wantSigma = last && params.uncertainty
            // 🐱 per-window extras of the last pass: σx, σy (px) and correlation-peak width (px, 0 = none)
            let sigX = UnsafeMutablePointer<Float>.allocate(capacity: n), sigY = UnsafeMutablePointer<Float>.allocate(capacity: n)
            let widths = UnsafeMutablePointer<Float>.allocate(capacity: n)
            sigX.initialize(repeating: 0, count: n); sigY.initialize(repeating: 0, count: n); widths.initialize(repeating: 0, count: n)
            defer { sigX.deallocate(); sigY.deallocate(); widths.deallocate() }
            field.dx.withUnsafeMutableBufferPointer { DX in
                field.dy.withUnsafeMutableBufferPointer { DY in
                    field.status.withUnsafeMutableBufferPointer { ST in
                        field.correlation.withUnsafeMutableBufferPointer { CO in
                            let dxp = DX.baseAddress!, dyp = DY.baseAddress!, stp = ST.baseAddress!, cop = CO.baseAddress!
                            A.withUnsafeBufferPointer { Ap in
                                B.withUnsafeBufferPointer { Bp in
                                    DispatchQueue.concurrentPerform(iterations: rows) { j in
                                        var work = CorrelationWork(size: w)
                                        var i = -1
                                        while i + 1 < cols {
                                            i += 1
                                            let k = j * cols + i
                                            if let cv = coverage {
                                                // 🐱 usable share of the window at its nominal position
                                                let ci = min(H - 1, j * step + w / 2) * W + min(W - 1, i * step + w / 2)
                                                if cv[ci] < minCoverage { stp[k] = .masked; continue }
                                            }
                                            // 🐱 window centre relative to the ROI
                                            let cx = Double(i * step) + Double(w) / 2, cy = Double(j * step) + Double(w) / 2
                                            var sx = 0.0, sy = 0.0
                                            if let p = pred {
                                                let d = p.interpolate(x: cx, y: cy)
                                                sx = d.dx; sy = d.dy
                                            }
                                            // 🐱 symmetric sub-pixel offset: A moves back half the predicted shift, B forward the rest;
                                            // 🐱 near the edges the pair slides inward (same shift) so both windows stay inside the image
                                            guard let ax = Self.place(Double(i * step) - sx / 2, shift: sx, window: w, size: W),
                                                  let ay = Self.place(Double(j * step) - sy / 2, shift: sy, window: w, size: H) else { continue }
                                            work.fill(Ap.baseAddress!, W, x0: ax, y0: ay, into: true, kernel: kernel, height: H)
                                            work.fill(Bp.baseAddress!, W, x0: ax + sx, y0: ay + sy, into: false, kernel: kernel, height: H)
                                            // 🐱 statistics of the aligned windows, before the FFT reuses them as scratch
                                            let sigma = wantSigma ? work.uncertainty() : nil
                                            guard let r = work.correlate(setup: setup, minContrast: params.minWindowContrast) else { continue }
                                            dxp[k] = sx + r.dx
                                            dyp[k] = sy + r.dy
                                            cop[k] = r.correlation
                                            // 🐱 residual beyond a quarter window means the offset prediction failed
                                            let ok = Double(r.correlation) >= params.minCorrelation && abs(r.dx) < Double(w) / 4 + 1 && abs(r.dy) < Double(w) / 4 + 1
                                            stp[k] = ok ? .valid : .invalid
                                            if last {
                                                if let sigma { sigX[k] = sigma.x; sigY[k] = sigma.y }
                                                widths[k] = r.peakWidth
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Self.validate(&field, threshold: parameters.validationThreshold, epsilon: parameters.validationEpsilonPx,
                          replace: final ? parameters.replaceInvalid : true)
            if last {
                if wantSigma {
                    field.sigmaX = Array(UnsafeBufferPointer(start: sigX, count: n))
                    field.sigmaY = Array(UnsafeBufferPointer(start: sigY, count: n))
                }
                var d: [Double] = []
                var k = 0
                while k < n {
                    if field.status[k] == .valid && widths[k] > 0 { d.append(2 * 2.0.squareRoot() * Double(widths[k])) }
                    k += 1
                }
                field.particleImageDiameterPx = GridKernels.median(of: d)
            }
            predictor = Self.filledForPrediction(field)
            result = field
        }
        guard let f = result else { return nil }
        return Self.toFullFrame(f, image: a)
    }

    /// 🐱 Re-measure selected final-pass windows of `field` (full-frame px, any pair geometry) between `a` and `b`, with
    /// 🐱 the field's own displacement as window offset (one Lanczos-shifted pass). Used to measure camera motion on raw
    /// 🐱 frames in static windows, whose texture background subtraction would otherwise have removed.
    public func measureWindows(a: PIVImage, b: PIVImage, field f: PIVField, indices: [Int]) -> [Int: (dx: Double, dy: Double)] {
        guard a.width == b.width, a.height == b.height, !indices.isEmpty else { return [:] }
        let s = Double(max(1, a.scale))
        let w = Self.effectiveWindow(Int((Double(f.windowSize) / s).rounded()))
        guard a.width > w + 8, a.height > w + 8 else { return [:] }
        let setup = fftSetup(maxLog2: max(setupLog2, Int(log2(Double(w)))))
        var work = CorrelationWork(size: w)
        var out: [Int: (dx: Double, dy: Double)] = [:]
        a.pixels.withUnsafeBufferPointer { Ap in
            b.pixels.withUnsafeBufferPointer { Bp in
                for k in indices where k >= 0 && k < f.count {
                    // 🐱 full-frame → analysed px
                    let cx = (f.x(k) - Double(a.originX) + 0.5) / s - 0.5, cy = (f.y(k) - Double(a.originY) + 0.5) / s - 0.5
                    let sx = f.dx[k] / s, sy = f.dy[k] / s
                    guard let ax = Self.place(cx - Double(w) / 2 - sx / 2, shift: sx, window: w, size: a.width),
                          let ay = Self.place(cy - Double(w) / 2 - sy / 2, shift: sy, window: w, size: a.height) else { continue }
                    work.fill(Ap.baseAddress!, a.width, x0: ax, y0: ay, into: true, kernel: .lanczos4, height: a.height)
                    work.fill(Bp.baseAddress!, a.width, x0: ax + sx, y0: ay + sy, into: false, kernel: .lanczos4, height: a.height)
                    guard let r = work.correlate(setup: setup, minContrast: parameters.minWindowContrast),
                          Double(r.correlation) >= parameters.minCorrelation, abs(r.dx) < Double(w) / 4, abs(r.dy) < Double(w) / 4 else { continue }
                    out[k] = ((sx + r.dx) * s, (sy + r.dy) * s)
                }
            }
        }
        return out
    }

    /// 🐱 Product of two masks (nil when neither frame has one).
    static func combinedMask(_ a: [Float]?, _ b: [Float]?, count: Int) -> [Float]? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (m?, nil), let (nil, m?): return m.count == count ? m : nil
        case let (m?, q?):
            guard m.count == count, q.count == count else { return nil }
            var out = [Float](repeating: 0, count: count)
            vDSP_vmul(m, 1, q, 1, &out, 1, vDSP_Length(count))
            return out
        }
    }

    /// 🐱 Predictor for the next pass: masked windows take the median of their measured neighbours, so a mask edge
    /// 🐱 does not pull the window offsets next to it towards zero.
    static func filledForPrediction(_ f: PIVField) -> PIVField {
        let n = f.count
        var usable = [UInt8](repeating: 0, count: n), targets = usable
        var any = false
        var k = 0
        while k < n {
            if f.isMeasured(k) { usable[k] = 1 }
            if f.status[k] == .masked { targets[k] = 1; any = true }
            k += 1
        }
        guard any else { return f }
        var g = f
        let r = GridKernels.neighbourMedians(u: f.dx, v: f.dy, usable: usable, targets: targets, columns: f.columns, rows: f.rows)
        k = 0
        while k < n {
            if r.found[k] != 0 { g.dx[k] = r.u[k]; g.dy[k] = r.v[k] }
            k += 1
        }
        return g
    }

    /// 🐱 Field in analysed-image px (origin 0) → full-frame px (block-averaged pixel i is centred at
    /// 🐱 origin + (i + 0.5)·s − 0.5).
    static func toFullFrame(_ field: PIVField, image a: PIVImage) -> PIVField {
        var f = field
        let s = Double(a.scale)
        f.originX = Double(a.originX) + (f.originX + 0.5) * s - 0.5
        f.originY = Double(a.originY) + (f.originY + 0.5) * s - 0.5
        f.step *= s
        f.windowSize *= a.scale
        if a.scale > 1 {
            var sc = s
            vDSP_vsmulD(f.dx, 1, &sc, &f.dx, 1, vDSP_Length(f.dx.count))
            vDSP_vsmulD(f.dy, 1, &sc, &f.dy, 1, vDSP_Length(f.dy.count))
            var sf = Float(s)
            if !f.sigmaX.isEmpty { vDSP_vsmul(f.sigmaX, 1, &sf, &f.sigmaX, 1, vDSP_Length(f.sigmaX.count)) }
            if !f.sigmaY.isEmpty { vDSP_vsmul(f.sigmaY, 1, &sf, &f.sigmaY, 1, vDSP_Length(f.sigmaY.count)) }
            f.particleImageDiameterPx = f.particleImageDiameterPx.map { $0 * s }
        }
        return f
    }

    /// 🐱 Interrogation window sizes actually used (powers of two, 8...256).
    static func effectiveWindow(_ w: Int) -> Int { 1 << Int(log2(Double(max(8, min(256, w)))).rounded()) }

    /// 🐱 Start of window A such that A and B = A + shift both fit, with the 3-px / 4-px margins the 8-tap interpolation
    /// 🐱 needs before / after the window; nil if impossible.
    static func place(_ start: Double, shift: Double, window w: Int, size: Int) -> Double? {
        // 🐱 1e-6 keeps floor(start + shift) ≥ 3 when rounding lands a hair below the bound
        let span = Double(size - w - 5)
        let lo = max(3, 3 - shift) + 1e-6, hi = min(span, span - shift) - 1e-6
        guard lo <= hi else { return nil }
        return min(max(start, lo), hi)
    }

    /// 🐱 Normalised median test, then (optionally) replace invalid vectors by the median of valid neighbours.
    static func validate(_ f: inout PIVField, threshold: Double, epsilon: Double, replace: Bool) {
        let cols = f.columns, rows = f.rows, n = cols * rows
        guard n > 0 else { return }
        var usable = [UInt8](repeating: 0, count: n)
        var invalid = [UInt8](repeating: 0, count: n)
        f.status.withUnsafeBufferPointer { sb in
            let S = sb.baseAddress!
            usable.withUnsafeMutableBufferPointer { ub in
                invalid.withUnsafeMutableBufferPointer { ib in
                    var k = 0
                    while k < n {
                        let r = S[k].rawValue
                        if r == PIVField.Status.valid.rawValue { ub[k] = 1 }
                        if r == PIVField.Status.invalid.rawValue { ib[k] = 1 }
                        k += 1
                    }
                }
            }
        }
        let outliers = GridKernels.medianTestOutliers(u: f.dx, v: f.dy, usable: usable, columns: cols, rows: rows,
                                                      threshold: threshold, epsilon: epsilon)
        var k = 0
        while k < n {
            if outliers[k] != 0 {
                f.status[k] = .invalid
                usable[k] = 0
                invalid[k] = 1
            }
            k += 1
        }
        guard replace else { return }
        let r = GridKernels.neighbourMedians(u: f.dx, v: f.dy, usable: usable, targets: invalid, columns: cols, rows: rows)
        k = 0
        while k < n {
            if r.found[k] != 0 {
                f.dx[k] = r.u[k]
                f.dy[k] = r.v[k]
                f.status[k] = .replaced
            }
            k += 1
        }
    }
}

extension PIVField {
    /// 🐱 Bilinear interpolation of the displacement at a full-frame point (clamped at the grid edges).
    public func interpolate(x: Double, y: Double) -> (dx: Double, dy: Double) {
        let fx = max(0, min(Double(columns - 1), (x - originX) / step))
        let fy = max(0, min(Double(rows - 1), (y - originY) / step))
        let i0 = Int(fx), j0 = Int(fy)
        let i1 = min(columns - 1, i0 + 1), j1 = min(rows - 1, j0 + 1)
        let tx = fx - Double(i0), ty = fy - Double(j0)
        func at(_ a: [Double], _ i: Int, _ j: Int) -> Double { a[j * columns + i] }
        func lerp(_ a: [Double]) -> Double {
            let top = at(a, i0, j0) * (1 - tx) + at(a, i1, j0) * tx
            let bottom = at(a, i0, j1) * (1 - tx) + at(a, i1, j1) * tx
            return top * (1 - ty) + bottom * ty
        }
        return (lerp(dx), lerp(dy))
    }
}

/// 🐱 Per-thread scratch for one window size: Z = A + iB → FFT → cross-power → inverse FFT → peak.
struct CorrelationWork {
    let n: Int
    let log2n: vDSP_Length
    var re: [Float]
    var im: [Float]
    var a: [Float]
    var b: [Float]
    var mr: [Float]
    var mi: [Float]
    var t1: [Float]
    var t2: [Float]
    /// 🐱 (n + 3) × n rows interpolated horizontally (bicubic window shifting)
    var rowsScratch: [Float] = []
    /// 🐱 index of −k for every k (as Float, for vDSP_vindex)
    let mirror: [Float]

    init(size: Int) {
        n = size
        log2n = vDSP_Length(log2(Double(size)))
        // 🐱 separate buffers from the start (sharing one would copy each on its first write)
        let nn = size * size
        re = .init(repeating: 0, count: nn); im = .init(repeating: 0, count: nn)
        a = .init(repeating: 0, count: nn); b = .init(repeating: 0, count: nn)
        mr = .init(repeating: 0, count: nn); mi = .init(repeating: 0, count: nn)
        t1 = .init(repeating: 0, count: nn); t2 = .init(repeating: 0, count: nn)
        mirror = Self.mirrorTable(size)
    }

    private static let mirrorLock = NSLock()
    nonisolated(unsafe) private static var mirrors: [Int: [Float]] = [:]

    /// 🐱 Built once per window size (a per-window loop here is slow in unoptimised builds).
    private static func mirrorTable(_ size: Int) -> [Float] {
        mirrorLock.withLock {
            if let m = mirrors[size] { return m }
            var m = [Float](repeating: 0, count: size * size)
            for r in 0..<size {
                for c in 0..<size { m[r * size + c] = Float(((size - r) % size) * size + (size - c) % size) }
            }
            mirrors[size] = m
            return m
        }
    }

    /// 🐱 `peakWidth`: standard deviation of the correlation peak (px, mean of x and y; 0 if not measurable).
    struct Result { var dx: Double; var dy: Double; var correlation: Float; var peakWidth: Float }

    /// 🐱 Copy an n×n window starting at a (possibly fractional) position. `cubic`: Keys bicubic interpolation
    /// 🐱 (a = −0.5; needs 1 px before and 2 px after the window), otherwise bilinear. Bilinear smooths the two windows
    /// 🐱 of a pair by different amounts when their sub-pixel phases differ, which biases the peak (≈0.04 px measured on
    /// 🐱 synthetic images with 3-px particles); bicubic removes most of that.
    mutating func fill(_ src: UnsafePointer<Float>, _ W: Int, x0: Double, y0: Double, into first: Bool, cubic: Bool = false,
                       kernel: SubpixelKernel? = nil, height H: Int? = nil) {
        let n = self.n
        let ix = Int(floor(x0)), iy = Int(floor(y0))
        let fx = Float(x0 - Double(ix)), fy = Float(y0 - Double(iy))
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
        let integral = fx < 1e-6 && fy < 1e-6
        var k = kernel ?? (cubic ? .cubic : nil)
        if let kk = k {
            // 🐱 the kernel reads T/2 − 1 px before and T/2 px after the window; never outside the image
            let before = kk.taps / 2 - 1, after = kk.taps / 2
            if ix - before < 0 || iy - before < 0 || ix + n + after > W || (H.map { iy + n + after > $0 } ?? false) { k = nil }
        }
        if let k, !integral {
            let taps = k.taps
            if rowsScratch.count != (n + taps - 1) * n { rowsScratch = [Float](repeating: 0, count: (n + taps - 1) * n) }
            rowsScratch.withUnsafeMutableBufferPointer { S in
                let s = S.baseAddress!
                if first {
                    a.withUnsafeMutableBufferPointer { dst in Self.kernelCopy(src, W, ix, iy, n, fx, fy, k, s, dst.baseAddress!) }
                } else {
                    b.withUnsafeMutableBufferPointer { dst in Self.kernelCopy(src, W, ix, iy, n, fx, fy, k, s, dst.baseAddress!) }
                }
            }
            return
        }
        if first {
            a.withUnsafeMutableBufferPointer { dst in Self.copy(src, W, ix, iy, n, integral, w00, w10, w01, w11, dst.baseAddress!) }
        } else {
            b.withUnsafeMutableBufferPointer { dst in Self.copy(src, W, ix, iy, n, integral, w00, w10, w01, w11, dst.baseAddress!) }
        }
    }

    /// 🐱 Separable interpolation kernels for sub-pixel window shifting.
    enum SubpixelKernel: Sendable {
        case cubic, lanczos3, lanczos4
        var taps: Int { self == .cubic ? 4 : self == .lanczos3 ? 6 : 8 }
        /// 🐱 weights for taps −(taps/2 − 1) … taps/2 at fraction t, normalised to sum 1
        func weights(_ t: Float) -> [Float] {
            switch self {
            case .cubic:
                let w = CorrelationWork.cubicWeights(t)
                return [w.0, w.1, w.2, w.3]
            case .lanczos3, .lanczos4:
                let a = Double(taps / 2)
                var w: [Float] = []
                var sum: Float = 0
                var j = -(taps / 2 - 1)
                while j <= taps / 2 {
                    let x = Double(j) - Double(t)
                    let v: Double = abs(x) < 1e-9 ? 1 : (sin(.pi * x) / (.pi * x)) * (sin(.pi * x / a) / (.pi * x / a))
                    w.append(Float(v)); sum += Float(v)
                    j += 1
                }
                return w.map { $0 / sum }
            }
        }
    }

    /// 🐱 Generic separable kernel copy (taps T, first tap at −(T/2 − 1)).
    private static func kernelCopy(_ src: UnsafePointer<Float>, _ W: Int, _ ix: Int, _ iy: Int, _ n: Int, _ fx: Float, _ fy: Float,
                                   _ k: SubpixelKernel, _ scratch: UnsafeMutablePointer<Float>, _ dst: UnsafeMutablePointer<Float>) {
        let T = k.taps, before = T / 2 - 1
        var wx = k.weights(fx), wy = k.weights(fy)
        let len = vDSP_Length(n)
        let bytes = n * MemoryLayout<Float>.size
        var r = 0
        while r < n + T - 1 {
            let s = src + (iy - before + r) * W + ix - before
            let d = scratch + r * n
            if fx < 1e-6 {
                memcpy(d, s + before, bytes)
            } else {
                vDSP_vsmul(s, 1, &wx[0], d, 1, len)
                var j = 1
                while j < T { vDSP_vsma(s + j, 1, &wx[j], d, 1, d, 1, len); j += 1 }
            }
            r += 1
        }
        r = 0
        while r < n {
            let h = scratch + r * n
            let d = dst + r * n
            if fy < 1e-6 {
                memcpy(d, h + before * n, bytes)
            } else {
                vDSP_vsmul(h, 1, &wy[0], d, 1, len)
                var j = 1
                while j < T { vDSP_vsma(h + j * n, 1, &wy[j], d, 1, d, 1, len); j += 1 }
            }
            r += 1
        }
    }

    /// 🐱 Keys cubic convolution weights for taps −1, 0, 1, 2 at fraction t.
    @inline(__always)
    static func cubicWeights(_ t: Float) -> (Float, Float, Float, Float) {
        let t2 = t * t, t3 = t2 * t
        return (-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
    }

    /// 🐱 Separable bicubic: rows iy−1 … iy+n+1 interpolated horizontally into `scratch`, then 4 rows per output row.
    private static func cubicCopy(_ src: UnsafePointer<Float>, _ W: Int, _ ix: Int, _ iy: Int, _ n: Int, _ fx: Float, _ fy: Float,
                                  _ scratch: UnsafeMutablePointer<Float>, _ dst: UnsafeMutablePointer<Float>) {
        var (a0, a1, a2, a3) = cubicWeights(fx)
        var (b0, b1, b2, b3) = cubicWeights(fy)
        let len = vDSP_Length(n)
        let bytes = n * MemoryLayout<Float>.size
        var r = 0
        while r < n + 3 {
            let s = src + (iy - 1 + r) * W + ix - 1
            let d = scratch + r * n
            if fx < 1e-6 {
                memcpy(d, s + 1, bytes)
            } else {
                vDSP_vsmul(s, 1, &a0, d, 1, len)
                vDSP_vsma(s + 1, 1, &a1, d, 1, d, 1, len)
                vDSP_vsma(s + 2, 1, &a2, d, 1, d, 1, len)
                vDSP_vsma(s + 3, 1, &a3, d, 1, d, 1, len)
            }
            r += 1
        }
        r = 0
        while r < n {
            let h = scratch + r * n      // 🐱 rows iy−1+r … iy+2+r
            let d = dst + r * n
            if fy < 1e-6 {
                memcpy(d, h + n, bytes)
            } else {
                vDSP_vsmul(h, 1, &b0, d, 1, len)
                vDSP_vsma(h + n, 1, &b1, d, 1, d, 1, len)
                vDSP_vsma(h + 2 * n, 1, &b2, d, 1, d, 1, len)
                vDSP_vsma(h + 3 * n, 1, &b3, d, 1, d, 1, len)
            }
            r += 1
        }
    }

    private static func copy(_ src: UnsafePointer<Float>, _ W: Int, _ ix: Int, _ iy: Int, _ n: Int, _ integral: Bool,
                             _ w00: Float, _ w10: Float, _ w01: Float, _ w11: Float, _ dst: UnsafeMutablePointer<Float>) {
        var a = w00, b = w10, c = w01, e = w11
        let len = vDSP_Length(n)
        let bytes = n * MemoryLayout<Float>.size
        // 🐱 `while`, not `for … in`: range iteration is very slow in unoptimised (Playgrounds) builds
        var r = 0
        while r < n {
            let row0 = src + (iy + r) * W + ix
            let d = dst + r * n
            if integral {
                memcpy(d, row0, bytes)
            } else {
                // 🐱 d = w00·r0[c] + w10·r0[c+1] + w01·r1[c] + w11·r1[c+1]
                let row1 = row0 + W
                vDSP_vsmul(row0, 1, &a, d, 1, len)
                vDSP_vsma(row0 + 1, 1, &b, d, 1, d, 1, len)
                vDSP_vsma(row1, 1, &c, d, 1, d, 1, len)
                vDSP_vsma(row1 + 1, 1, &e, d, 1, d, 1, len)
            }
            r += 1
        }
    }

    /// 🐱 Correlate the windows previously placed in `a` (earlier) and `b` (later).
    mutating func correlate(setup: FFTSetup, minContrast: Float) -> Result? {
        guard correlationPlane(setup: setup, minContrast: minContrast) else { return nil }
        let p = re.withUnsafeBufferPointer { Self.findPeak($0.baseAddress!, n: n, ratioScratch: nil) }
        let width: Float = p.widthX > 0 && p.widthY > 0 ? (p.widthX + p.widthY) / 2 : 0
        return Result(dx: p.dx, dy: p.dy, correlation: max(0, min(1, p.height)), peakWidth: width)
    }

    /// 🐱 Random uncertainty (standard uncertainty, px) of the displacement between the windows in `a` and `b`, which
    /// 🐱 the caller has already aligned by the predicted displacement. Correlation statistics after Wieneke (2015):
    /// 🐱 with a′, b′ the zero-mean windows, C₀ = Σ a′b′, C± = Σ a′(x)·b′(x ± 1) along one axis, and the per-pixel
    /// 🐱 contributions ΔS(x) = a′(x)b′(x+1) − a′(x+1)b′(x) to the asymmetry C₊ − C₋. Random image differences
    /// 🐱 (noise, particles entering / leaving, out-of-plane loss) make ΔS scatter; the variance of its sum (pixel
    /// 🐱 variance plus covariances with the neighbours within 2 px, since particle images span several pixels) propagated
    /// 🐱 through the 3-point Gaussian estimator, linearised about C₊ = C₋ = C̄, gives
    /// 🐱     σ = σ(ΣΔS) / (4·C̄·ln(C₀/C̄)).
    /// 🐱 Nil when the window has no usable peak (C̄ ≤ 0 or C₀ ≤ C̄). Uses `mr`, `mi`, `t1`, `t2` as scratch.
    mutating func uncertainty() -> (x: Float, y: Float)? {
        let n = self.n, nn = n * n
        var meanA: Float = 0, meanB: Float = 0
        vDSP_meanv(a, 1, &meanA, vDSP_Length(nn))
        vDSP_meanv(b, 1, &meanB, vDSP_Length(nn))
        var negA = -meanA, negB = -meanB
        vDSP_vsadd(a, 1, &negA, &mr, 1, vDSP_Length(nn))
        vDSP_vsadd(b, 1, &negB, &mi, 1, vDSP_Length(nn))
        var c0: Float = 0
        vDSP_dotpr(mr, 1, mi, 1, &c0, vDSP_Length(nn))
        guard c0 > 0 else { return nil }
        let sx: Float? = mr.withUnsafeBufferPointer { A in
            mi.withUnsafeBufferPointer { B in
                t1.withUnsafeMutableBufferPointer { T1 in
                    t2.withUnsafeMutableBufferPointer { T2 in
                        Self.axisSigma(A.baseAddress!, B.baseAddress!, n: n, lag: 1, c0: c0, sp: T1.baseAddress!, sm: T2.baseAddress!)
                    }
                }
            }
        }
        let sy: Float? = mr.withUnsafeBufferPointer { A in
            mi.withUnsafeBufferPointer { B in
                t1.withUnsafeMutableBufferPointer { T1 in
                    t2.withUnsafeMutableBufferPointer { T2 in
                        Self.axisSigma(A.baseAddress!, B.baseAddress!, n: n, lag: n, c0: c0, sp: T1.baseAddress!, sm: T2.baseAddress!)
                    }
                }
            }
        }
        guard let sx, let sy else { return nil }
        return (sx, sy)
    }

    /// 🐱 Neighbourhood (px) over which per-pixel contributions are treated as correlated (particle images span
    /// 🐱 several pixels). 2 matched the actual errors best on synthetic images (ratios 0.8–1.1).
    static let covarianceRadius = 2

    /// 🐱 One axis of `uncertainty()`: lag 1 = x (pairs across a row end are excluded), lag n = y.
    private static func axisSigma(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, n: Int, lag: Int, c0: Float,
                                  sp: UnsafeMutablePointer<Float>, sm: UnsafeMutablePointer<Float>) -> Float? {
        let nn = n * n
        let m = nn - lag
        guard m > 2 * n else { return nil }
        vDSP_vmul(a, 1, b + lag, 1, sp, 1, vDSP_Length(m))      // 🐱 S₊(x) = a′(x)·b′(x+1)
        vDSP_vmul(a + lag, 1, b, 1, sm, 1, vDSP_Length(m))      // 🐱 S₋(x) = a′(x+1)·b′(x)
        var valid = m
        if lag == 1 {
            // 🐱 (row r, last column) pairs with (row r+1, first column): not a neighbour
            var r = 0
            while r < n - 1 { sp[r * n + n - 1] = 0; sm[r * n + n - 1] = 0; r += 1 }
            valid = (n - 1) * n
        }
        var cp: Float = 0, cm: Float = 0
        vDSP_sve(sp, 1, &cp, vDSP_Length(m))
        vDSP_sve(sm, 1, &cm, vDSP_Length(m))
        let cbar = (cp + cm) / 2
        guard cbar > 0, c0 > cbar * 1.0001 else { return nil }
        // 🐱 ΔS − mean(ΔS)
        vDSP_vsub(sm, 1, sp, 1, sp, 1, vDSP_Length(m))
        var mean: Float = 0
        vDSP_sve(sp, 1, &mean, vDSP_Length(m))
        mean /= Float(valid)
        var neg = -mean
        vDSP_vsadd(sp, 1, &neg, sp, 1, vDSP_Length(m))
        if lag == 1 {
            var r = 0
            while r < n - 1 { sp[r * n + n - 1] = 0; r += 1 }
        }
        var variance: Float = 0
        vDSP_dotpr(sp, 1, sp, 1, &variance, vDSP_Length(m))
        // 🐱 covariance with the neighbours within `covarianceRadius` (half-plane offsets, counted twice)
        var cov: Float = 0
        let L = Self.covarianceRadius
        var dy = 0
        while dy <= L {
            var dx = dy == 0 ? 1 : -L
            while dx <= L {
                let off = dy * n + dx
                if off > 0 && off < m {
                    var c: Float = 0
                    vDSP_dotpr(sp, 1, sp + off, 1, &c, vDSP_Length(m - off))
                    cov += c
                }
                dx += 1
            }
            dy += 1
        }
        let total = max(variance, variance + 2 * cov)
        return total.squareRoot() / (4 * cbar * log(c0 / cbar))
    }

    /// 🐱 `widthX/Y`: standard deviation of the peak along x / y (px) from the same three points (0 if not Gaussian).
    struct Peak { var dx: Double; var dy: Double; var height: Float; var ratio: Float; var widthX: Float = 0; var widthY: Float = 0 }

    /// 🐱 Normalised cyclic cross-correlation plane of the windows in `a` and `b`, left in `re` (n×n, shift (0,0)
    /// 🐱 at index 0): 1 at the peak means perfect correlation. False if either window has too little contrast.
    mutating func correlationPlane(setup: FFTSetup, minContrast: Float) -> Bool {
        let n = self.n, nn = n * n
        var meanA: Float = 0, sdA: Float = 0, meanB: Float = 0, sdB: Float = 0
        vDSP_normalize(a, 1, nil, 1, &meanA, &sdA, vDSP_Length(nn))
        vDSP_normalize(b, 1, nil, 1, &meanB, &sdB, vDSP_Length(nn))
        guard sdA >= minContrast, sdB >= minContrast else { return false }
        var negA = -meanA, negB = -meanB
        vDSP_vsadd(a, 1, &negA, &re, 1, vDSP_Length(nn))
        vDSP_vsadd(b, 1, &negB, &im, 1, vDSP_Length(nn))

        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var z = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(setup, &z, 1, vDSP_Stride(n), log2n, log2n, FFTDirection(kFFTDirection_Forward))
                // 🐱 Separate FA, FB from Z (A real, B imaginary) and form P = conj(FA)·FB in a/b as scratch.
                //     FA(k) = (Z(k) + conj(Z(−k)))/2,  FB(k) = (Z(k) − conj(Z(−k)))/(2i)
                // 🐱 vectorised: M = Z(−k) by gather, then with FA = (far, fai), FB = (fbr, fbi):
                //     far = (zr+mr)/2, fai = (zi−mi)/2, fbr = (zi+mi)/2, fbi = (mr−zr)/2
                //     conj(FA)·FB = (far·fbr + fai·fbi) + i (far·fbi − fai·fbr)
                let N = vDSP_Length(nn)
                let R = rp.baseAddress!, I = ip.baseAddress!
                vDSP_vindex(R, mirror, 1, &mr, 1, N)
                vDSP_vindex(I, mirror, 1, &mi, 1, N)
                var half: Float = 0.5
                vDSP_vadd(R, 1, mr, 1, &a, 1, N); vDSP_vsmul(a, 1, &half, &a, 1, N)     // 🐱 far
                vDSP_vsub(mi, 1, I, 1, &b, 1, N); vDSP_vsmul(b, 1, &half, &b, 1, N)     // 🐱 fai = zi − mi
                vDSP_vadd(I, 1, mi, 1, &t1, 1, N); vDSP_vsmul(t1, 1, &half, &t1, 1, N)  // 🐱 fbr
                vDSP_vsub(R, 1, mr, 1, &t2, 1, N); vDSP_vsmul(t2, 1, &half, &t2, 1, N)  // 🐱 fbi = mr − zr
                // 🐱 real: far·fbr + fai·fbi ; imag: far·fbi − fai·fbr
                vDSP_vmma(a, 1, t1, 1, b, 1, t2, 1, R, 1, N)
                vDSP_vmmsb(a, 1, t2, 1, b, 1, t1, 1, I, 1, N)
                vDSP_fft2d_zip(setup, &z, 1, vDSP_Stride(n), log2n, log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        // 🐱 IFFT is unnormalised (×N); Σ A·B over the window = N·σA·σB at perfect correlation.
        var scale = 1 / (Float(nn) * Float(nn) * sdA * sdB)
        vDSP_vsmul(re, 1, &scale, &re, 1, vDSP_Length(nn))
        return true
    }

    /// 🐱 Highest peak of a cyclic n×n plane with 3-point Gaussian sub-pixel position (shifts in [−n/2, n/2)), and,
    /// 🐱 with a scratch buffer, the peak ratio: peak / highest value outside its 3×3 neighbourhood.
    static func findPeak(_ p: UnsafePointer<Float>, n: Int, ratioScratch: UnsafeMutablePointer<Float>?) -> Peak {
        let nn = n * n
        var peak: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(p, 1, &peak, &index, vDSP_Length(nn))
        let pr = Int(index) / n, pc = Int(index) % n
        func at(_ r: Int, _ c: Int) -> Int { ((r % n + n) % n) * n + (c % n + n) % n }
        func sub(_ m: Float, _ c0: Float, _ q: Float) -> Double {
            if m > 0, c0 > 0, q > 0 {
                let lm = log(Double(m)), lc = log(Double(c0)), lq = log(Double(q))
                let den = 2 * (lm - 2 * lc + lq)
                if abs(den) > 1e-12 { return (lm - lq) / den }
            }
            let den = 2 * Double(m - 2 * c0 + q)
            return abs(den) > 1e-12 ? Double(m - q) / den : 0
        }
        // 🐱 Unbiased estimator (Westerweel 1997): a shift s only overlaps n − |s| columns of the window, so the
        // 🐱 plane is weighted towards zero; dividing the three fitted values by that overlap removes the bias.
        let ix = pc >= n / 2 ? pc - n : pc, iy = pr >= n / 2 ? pr - n : pr
        func overlap(_ s: Int) -> Float { Float(n - abs(s)) }
        let ox = sub(p[at(pr, pc - 1)] / overlap(ix - 1), peak / overlap(ix), p[at(pr, pc + 1)] / overlap(ix + 1))
        let oy = sub(p[at(pr - 1, pc)] / overlap(iy - 1), peak / overlap(iy), p[at(pr + 1, pc)] / overlap(iy + 1))
        let shiftX = Double(ix) + max(-1, min(1, ox))
        let shiftY = Double(iy) + max(-1, min(1, oy))
        // 🐱 second difference of ln C is −1/σ² for a Gaussian peak (independent of its sub-pixel position)
        func width(_ m: Float, _ c0: Float, _ q: Float) -> Float {
            guard m > 0, c0 > 0, q > 0 else { return 0 }
            let d = log(m) - 2 * log(c0) + log(q)
            return d < -1e-6 ? (-1 / d).squareRoot() : 0
        }
        let wx = width(p[at(pr, pc - 1)], peak, p[at(pr, pc + 1)])
        let wy = width(p[at(pr - 1, pc)], peak, p[at(pr + 1, pc)])
        var ratio = Float.infinity
        if let s = ratioScratch {
            memcpy(s, p, nn * MemoryLayout<Float>.size)
            var dr = -1
            while dr <= 1 {
                var dc = -1
                while dc <= 1 {
                    s[at(pr + dr, pc + dc)] = -Float.greatestFiniteMagnitude
                    dc += 1
                }
                dr += 1
            }
            var second: Float = 0
            vDSP_maxv(s, 1, &second, vDSP_Length(nn))
            if second > 0 { ratio = peak / second }
        }
        return Peak(dx: shiftX, dy: shiftY, height: peak, ratio: ratio, widthX: wx, widthY: wy)
    }
}
