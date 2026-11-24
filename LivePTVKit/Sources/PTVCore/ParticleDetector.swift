import Foundation

public struct Particle: Codable, Equatable, Sendable {
    /// 🐱 Sub-pixel centre in full-frame pixels. Pixel centres are at integer coordinates.
    public var x: Double
    public var y: Double
    /// 🐱 Peak foreground intensity (after background removal), grey levels.
    public var peak: Float
    /// 🐱 Sum of foreground intensity in the fitting window.
    public var mass: Float
    /// 🐱 Pixels above threshold around the peak.
    public var area: Int

    public init(x: Double, y: Double, peak: Float, mass: Float, area: Int) {
        self.x = x
        self.y = y
        self.peak = peak
        self.mass = mass
        self.area = area
    }
}

public struct DetectorParameters: Codable, Equatable, Sendable {
    public enum Polarity: String, Codable, Sendable, CaseIterable { case brightOnDark, darkOnBright }
    public enum Subpixel: String, Codable, Sendable, CaseIterable { case gaussian3Point, centroid }

    public var polarity: Polarity = .brightOnDark
    /// 🐱 Remove a slowly updated background (static scratches, reflections, uneven light).
    public var backgroundSubtraction = true
    /// 🐱 How fast the background follows a brightening pixel (0...1). Darkening is followed at 0.5, so the
    /// 🐱 model tracks the lower envelope of the image and transient particles are not absorbed into it.
    public var backgroundAlpha: Float = 0.02
    /// 🐱 The background is not updated under detected particles (it would learn slow particles and bias their
    /// 🐱 positions along their motion), except under detections that have stayed within ±1 px for this many frames:
    /// 🐱 those are static structures and are learned at `backgroundAlpha`.
    public var backgroundStaticFrames = 30
    /// 🐱 1-2-1 smoothing before peak search (suppresses single-pixel noise).
    public var smoothing = true
    /// 🐱 Adaptive threshold: background level + k · σ, where level and σ are the median and 1.4826 · MAD of the
    /// 🐱 smoothed foreground (σ = sensor noise after smoothing; particles do not inflate it)...
    public var thresholdK: Float = 5
    /// 🐱 ...but never below this absolute level (grey levels of the smoothed foreground).
    public var minimumThreshold: Float = 8
    /// 🐱 Peaks closer than this (px) are merged, keeping the brighter one.
    public var minSeparation: Double = 3
    /// 🐱 Half-size of the sub-pixel fitting window (2 → 5×5).
    public var windowRadius = 2
    public var subpixel: Subpixel = .gaussian3Point
    public var minArea = 2
    public var maxArea = 80
    public var maxParticles = 20_000

    public init() {}
}

/// 🐱 Finds particle images: background removal → smoothing → robust noise threshold → local maxima →
/// 🐱 non-maximum suppression → sub-pixel peak (3-point Gaussian estimator, centroid fallback).
/// 🐱 Keeps the running background, so use one detector per stream and call `reset()` on discontinuities.
public final class ParticleDetector {
    public var parameters: DetectorParameters
    /// 🐱 Threshold applied to the smoothed foreground in the last frame (grey levels, background level included).
    public private(set) var lastThreshold: Float = 0
    /// 🐱 Background level (median) and noise σ (1.4826 · MAD) of the smoothed foreground in the last frame.
    public private(set) var lastBackgroundLevel: Float = 0
    public private(set) var lastNoiseSigma: Float = 0
    private var background: [Float] = []
    private var backgroundShape = (0, 0, 0, 0)
    private var work: [Float] = []
    private var tmp: [Float] = []
    private var histogram: [Int32] = []
    private var nmsCells: [Int32] = []
    /// 🐱 Background update bookkeeping: pixels stamped with the current frame number are not updated; `anchors` holds,
    /// 🐱 at the pixel where each current detection was first seen, the number of frames it has stayed there.
    private var stamp: [UInt32] = []
    private var frameStamp: UInt32 = 0
    private var anchors: [UInt16] = []
    private var anchorList: [Int] = []

    public init(parameters: DetectorParameters = DetectorParameters()) { self.parameters = parameters }

    public func reset() {
        background = []
        backgroundShape = (0, 0, 0, 0)
        stamp = []
        anchors = []
        anchorList = []
    }

    public func detect(_ image: LumaImage) -> [Particle] {
        let w = image.width, h = image.height, n = w * h
        guard w >= 3, h >= 3 else { return [] }
        let p = parameters
        if work.count != n { work = [Float](repeating: 0, count: n); tmp = work }

        // 🐱 1. signed foreground (particles positive). Not clipped at zero: the noise must stay symmetric about the
        // 🐱 background level for its median and MAD to measure it.
        let shape = (w, h, image.originX, image.originY)
        if p.backgroundSubtraction && (background.count != n || backgroundShape != shape) {
            // 🐱 Start from a grey-scale opening of the first frame: removes particle images (smaller than the
            // 🐱 structuring element) instead of baking them into the background as ghosts.
            let k = max(1, p.windowRadius + 1)
            background = Self.morphology(image.pixels, w, h, radius: k, erode: p.polarity == .brightOnDark)
            background = Self.morphology(background, w, h, radius: k, erode: p.polarity != .brightOnDark)
            backgroundShape = shape
            stamp = []
            anchors = []
            anchorList = []
        }
        let bright = p.polarity == .brightOnDark
        image.pixels.withUnsafeBufferPointer { src in
            work.withUnsafeMutableBufferPointer { f in
                if p.backgroundSubtraction {
                    background.withUnsafeBufferPointer { bg in
                        if bright { for i in 0..<n { f[i] = src[i] - bg[i] } } else { for i in 0..<n { f[i] = bg[i] - src[i] } }
                    }
                } else {
                    if bright { for i in 0..<n { f[i] = src[i] } } else { for i in 0..<n { f[i] = 255 - src[i] } }
                }
            }
        }

        // 🐱 2. separable [1 2 1]/4 smoothing (edges replicate), both passes row by row
        if p.smoothing {
            work.withUnsafeMutableBufferPointer { f in
                tmp.withUnsafeMutableBufferPointer { t in
                    for y in 0..<h {
                        let r = y * w
                        t[r] = (3 * f[r] + f[r + 1]) * 0.25
                        for x in 1..<(w - 1) { t[r + x] = (f[r + x - 1] + 2 * f[r + x] + f[r + x + 1]) * 0.25 }
                        t[r + w - 1] = (f[r + w - 2] + 3 * f[r + w - 1]) * 0.25
                    }
                    for y in 0..<h {
                        let r = y * w, up = y > 0 ? r - w : r, down = y < h - 1 ? r + w : r
                        for x in 0..<w { f[r + x] = (t[up + x] + 2 * t[r + x] + t[down + x]) * 0.25 }
                    }
                }
            }
        }

        // 🐱 3. adaptive threshold from robust statistics. The mean and standard deviation of the whole image grow with
        // 🐱 the number and brightness of the particles (the old threshold rose with seeding density and lost faint
        // 🐱 particles); the median and MAD stay at the background and its noise while particles cover < ~25 % of it.
        let (level, sigma) = work.withUnsafeBufferPointer { f in
            Self.robustLevelAndNoise(f, width: w, height: h, histogram: &histogram)
        }
        let thr = max(p.minimumThreshold, level + p.thresholdK * sigma)
        lastThreshold = thr
        lastBackgroundLevel = level
        lastNoiseSigma = sigma

        // 🐱 4. local maxima (ties broken toward the first pixel in raster order)
        let r = max(1, p.windowRadius)
        let border = r
        var candidates: [(i: Int, v: Float)] = []
        work.withUnsafeBufferPointer { f in
            guard h > 2 * border, w > 2 * border else { return }
            for y in border..<(h - border) {
                let row = y * w
                for x in border..<(w - border) {
                    let i = row + x
                    let v = f[i]
                    if v <= thr { continue }
                    if v <= f[i - 1] || v <= f[i - w - 1] || v <= f[i - w] || v <= f[i - w + 1] { continue }
                    if v < f[i + 1] || v < f[i + w - 1] || v < f[i + w] || v < f[i + w + 1] { continue }
                    candidates.append((i, v))
                }
            }
        }
        candidates.sort { $0.v > $1.v }

        // 🐱 5. non-maximum suppression on a grid of cells of side sep/√2 (a cell holds at most one kept peak, and every
        // 🐱 kept peak closer than sep lies within ±2 cells), then 6. sub-pixel fit
        let sep = max(1.0, p.minSeparation)
        let sep2 = sep * sep
        let cs = sep / 2.0.squareRoot()
        let gw = Int(Double(w) / cs) + 1, gh = Int(Double(h) / cs) + 1
        if nmsCells.count != gw * gh { nmsCells = [Int32](repeating: -1, count: gw * gh) } else { nmsCells.withUnsafeMutableBufferPointer { $0.update(repeating: -1) } }
        var keptPeaks: [(x: Int32, y: Int32)] = []
        keptPeaks.reserveCapacity(min(candidates.count, p.maxParticles))
        var out: [Particle] = []
        out.reserveCapacity(min(candidates.count, p.maxParticles))
        var footprints: [(i: Int, radius: Int)] = []
        if p.backgroundSubtraction { footprints.reserveCapacity(out.capacity) }
        work.withUnsafeBufferPointer { f in
            for c in candidates {
                if out.count >= p.maxParticles { break }
                let cx = c.i % w, cy = c.i / w
                var tooClose = false
                let gx = Int(Double(cx) / cs), gy = Int(Double(cy) / cs)
                search: for yy in max(0, gy - 2)...min(gh - 1, gy + 2) {
                    for xx in max(0, gx - 2)...min(gw - 1, gx + 2) {
                        let k = Int(nmsCells[yy * gw + xx])
                        guard k >= 0 else { continue }
                        let ex = Double(keptPeaks[k].x) - Double(cx), ey = Double(keptPeaks[k].y) - Double(cy)
                        if ex * ex + ey * ey < sep2 { tooClose = true; break search }
                    }
                }
                if tooClose { continue }
                nmsCells[gy * gw + gx] = Int32(keptPeaks.count)
                keptPeaks.append((Int32(cx), Int32(cy)))

                var mass: Float = 0
                var area = 0
                let ar = r + 2
                for yy in max(0, cy - ar)...min(h - 1, cy + ar) {
                    for xx in max(0, cx - ar)...min(w - 1, cx + ar) {
                        let v = f[yy * w + xx]
                        if v > thr { area += 1 }
                        if abs(yy - cy) <= r && abs(xx - cx) <= r { mass += max(0, v - level) }
                    }
                }
                if area < p.minArea || area > p.maxArea { continue }

                let (ox, oy) = subpixelOffset(f, w, cx, cy, r, level, thr, p.subpixel)
                out.append(Particle(x: Double(image.originX + cx) + ox, y: Double(image.originY + cy) + oy,
                                    peak: c.v - level, mass: mass, area: area))
                if p.backgroundSubtraction {
                    // 🐱 above-threshold radius + 2 px of wing (the wing of a Gaussian image there is < 1 % of its peak)
                    footprints.append((c.i, max(r, Int((Double(area) / .pi).squareRoot().rounded(.up)) + 2)))
                }
            }
        }
        if p.backgroundSubtraction { updateBackground(image, footprints) }
        return out
    }

    /// 🐱 Running background, updated after detection. Pixels under this frame's particles are left alone: a slowly
    /// 🐱 moving particle otherwise leaks into the background at the places it has just occupied, and subtracting that
    /// 🐱 ghost pushes the detected centre forward along its motion (Brownian steps came out ~20 % too long, D +37 %).
    /// 🐱 Detections that stay within ±1 px of where they were first seen for `backgroundStaticFrames` frames are
    /// 🐱 static structures (dust, glints, stuck particles) and are learned like any other pixel.
    private func updateBackground(_ image: LumaImage, _ footprints: [(i: Int, radius: Int)]) {
        let w = image.width, h = image.height, n = w * h
        let p = parameters
        if stamp.count != n { stamp = [UInt32](repeating: 0, count: n); anchors = [UInt16](repeating: 0, count: n); anchorList = [] }
        frameStamp &+= 1
        if frameStamp == 0 { for k in 0..<n { stamp[k] = 0 }; frameStamp = 1 }
        let fs = frameStamp
        let staticFrames = max(1, p.backgroundStaticFrames)

        // 🐱 Anchors: for each detection, the pixel where it was first seen and for how many consecutive frames it has
        // 🐱 stayed within ±1 px of it. Read last frame's anchors, then replace them with this frame's.
        var newAnchors: [(i: Int, count: UInt16)] = []
        newAnchors.reserveCapacity(footprints.count)
        let around = [0, -1, 1, -w, w, -w - 1, -w + 1, w - 1, w + 1]
        anchors.withUnsafeMutableBufferPointer { a in
            for fp in footprints {
                var best = -1
                var bestCount: UInt16 = 0
                for o in around {
                    let k = fp.i + o
                    if k >= 0, k < n, a[k] > bestCount { bestCount = a[k]; best = k }
                }
                if best >= 0 {
                    a[best] = 0   // 🐱 claimed: a second detection cannot continue the same anchor
                    newAnchors.append((best, bestCount == UInt16.max ? bestCount : bestCount + 1))
                } else {
                    newAnchors.append((fp.i, 1))
                }
            }
            for k in anchorList { a[k] = 0 }
            anchorList.removeAll(keepingCapacity: true)
            for na in newAnchors where a[na.i] < na.count {
                a[na.i] = na.count
                anchorList.append(na.i)
            }
        }

        // 🐱 Protect the footprints of moving (non-static) detections.
        stamp.withUnsafeMutableBufferPointer { s in
            for (fp, na) in zip(footprints, newAnchors) where Int(na.count) < staticFrames {
                let cx = fp.i % w, cy = fp.i / w, rr = fp.radius
                for yy in max(0, cy - rr)...min(h - 1, cy + rr) {
                    let row = yy * w
                    for xx in max(0, cx - rr)...min(w - 1, cx + rr) { s[row + xx] = fs }
                }
            }
        }

        let slow = p.backgroundAlpha, fast: Float = 0.5
        let bright = p.polarity == .brightOnDark
        image.pixels.withUnsafeBufferPointer { src in
            background.withUnsafeMutableBufferPointer { bg in
                stamp.withUnsafeBufferPointer { s in
                    for i in 0..<n where s[i] != fs {
                        let v = src[i]
                        let d = bright ? v - bg[i] : bg[i] - v
                        // 🐱 d > 0: pixel brighter than background in the particle direction (maybe an undetected
                        // 🐱 particle) → follow slowly; otherwise follow fast (lower envelope).
                        bg[i] += (d > 0 ? slow : fast) * (v - bg[i])
                    }
                }
            }
        }
    }

    /// 🐱 Separable square erosion (min) or dilation (max) with edge clamping.
    static func morphology(_ src: [Float], _ w: Int, _ h: Int, radius r: Int, erode: Bool) -> [Float] {
        var tmp = src, out = src
        let pick: (Float, Float) -> Float = erode ? { min($0, $1) } : { max($0, $1) }
        for y in 0..<h {
            for x in 0..<w {
                var m = src[y * w + x]
                for k in max(0, x - r)...min(w - 1, x + r) { m = pick(m, src[y * w + k]) }
                tmp[y * w + x] = m
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var m = tmp[y * w + x]
                for k in max(0, y - r)...min(h - 1, y + r) { m = pick(m, tmp[k * w + x]) }
                out[y * w + x] = m
            }
        }
        return out
    }

    /// 🐱 Median and 1.4826 · MAD of the image (background level and noise σ), from a histogram with 1/16 grey-level
    /// 🐱 bins (linear within a bin) over every k-th row so that ~250k pixels are used: O(n) without sorting, ~0.1 grey
    /// 🐱 level resolution, and a sampling error of the median of < 0.5 % of σ.
    static func robustLevelAndNoise(_ f: UnsafeBufferPointer<Float>, width w: Int, height h: Int,
                                    histogram hist: inout [Int32]) -> (level: Float, sigma: Float) {
        let binsPerLevel: Float = 16, lo: Float = -256
        let nb = 512 * Int(binsPerLevel)
        if hist.count != nb { hist = [Int32](repeating: 0, count: nb) } else { for k in 0..<nb { hist[k] = 0 } }
        let rowStep = max(1, (w * h) / 250_000)
        var count = 0
        hist.withUnsafeMutableBufferPointer { hb in
            let maxBin = Float(nb - 1)
            var y = 0
            while y < h {
                let row = y * w
                for x in 0..<w {
                    // 🐱 bin k is centred on lo + k / 16, so exact multiples of 1/16 (smoothed integers) sit mid-bin
                    let b = min(maxBin, max(0, (f[row + x] - lo) * binsPerLevel + 0.5))
                    hb[Int(b)] &+= 1
                }
                count += w
                y += rowStep
            }
        }
        guard count > 0 else { return (0, 0) }
        // 🐱 Cumulative counts at bin edges; cdf(x) interpolates linearly inside a bin.
        var cum = [Double](repeating: 0, count: nb + 1)
        for k in 0..<nb { cum[k + 1] = cum[k] + Double(hist[k]) }
        func cdf(_ x: Double) -> Double {
            let pos = (x - Double(lo)) * Double(binsPerLevel) + 0.5
            if pos <= 0 { return 0 }
            if pos >= Double(nb) { return cum[nb] }
            let k = Int(pos)
            return cum[k] + (pos - Double(k)) * Double(hist[k])
        }
        let half = Double(count) / 2
        var a = Double(lo), b = -Double(lo)
        for _ in 0..<40 { let m = 0.5 * (a + b); if cdf(m) < half { a = m } else { b = m } }
        let median = 0.5 * (a + b)
        var r0 = 0.0, r1 = -2 * Double(lo)
        for _ in 0..<40 { let m = 0.5 * (r0 + r1); if cdf(median + m) - cdf(median - m) < half { r0 = m } else { r1 = m } }
        return (Float(median), Float(1.4826 * 0.5 * (r0 + r1)))
    }

    private func subpixelOffset(_ f: UnsafeBufferPointer<Float>, _ w: Int, _ cx: Int, _ cy: Int, _ r: Int,
                                _ level: Float, _ thr: Float, _ mode: DetectorParameters.Subpixel) -> (Double, Double) {
        let i = cy * w + cx
        if mode == .gaussian3Point {
            // 🐱 Fitted above the background level: a pedestal under the Gaussian biases the estimator toward the pixel.
            let floorV: Float = 0.5
            let c = log(Double(max(f[i] - level, floorV)))
            let l = log(Double(max(f[i - 1] - level, floorV))), rr = log(Double(max(f[i + 1] - level, floorV)))
            let u = log(Double(max(f[i - w] - level, floorV))), d = log(Double(max(f[i + w] - level, floorV)))
            let denX = l - 2 * c + rr, denY = u - 2 * c + d
            if denX < -1e-9, denY < -1e-9 {
                let ox = (l - rr) / (2 * denX), oy = (u - d) / (2 * denY)
                if abs(ox) <= 1, abs(oy) <= 1 { return (ox, oy) }
            }
        }
        // 🐱 Centroid of the window, weighted by intensity above half the threshold (measured from the background level).
        var sw = 0.0, sx = 0.0, sy = 0.0
        let base = Double(level) + Double(thr - level) * 0.5
        for dy in -r...r {
            for dx in -r...r {
                let wgt = Double(f[i + dy * w + dx]) - base
                if wgt > 0 { sw += wgt; sx += wgt * Double(dx); sy += wgt * Double(dy) }
            }
        }
        return sw > 0 ? (sx / sw, sy / sw) : (0, 0)
    }
}
