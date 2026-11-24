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
    /// 🐱 1-2-1 smoothing before peak search (suppresses single-pixel noise).
    public var smoothing = true
    /// 🐱 Adaptive threshold: mean + k · std of the foreground image...
    public var thresholdK: Float = 4
    /// 🐱 ...but never below this absolute level (grey levels).
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

/// 🐱 Finds particle images: background removal → smoothing → adaptive threshold → local maxima →
/// 🐱 non-maximum suppression → sub-pixel peak (3-point Gaussian estimator, centroid fallback).
/// 🐱 Keeps the running background, so use one detector per stream and call `reset()` on discontinuities.
public final class ParticleDetector {
    public var parameters: DetectorParameters
    public private(set) var lastThreshold: Float = 0
    private var background: [Float] = []
    private var backgroundShape = (0, 0, 0, 0)
    private var work: [Float] = []
    private var tmp: [Float] = []

    public init(parameters: DetectorParameters = DetectorParameters()) { self.parameters = parameters }

    public func reset() {
        background = []
        backgroundShape = (0, 0, 0, 0)
    }

    public func detect(_ image: LumaImage) -> [Particle] {
        let w = image.width, h = image.height, n = w * h
        guard w >= 3, h >= 3 else { return [] }
        let p = parameters
        if work.count != n { work = [Float](repeating: 0, count: n); tmp = work }

        // 🐱 1. foreground (particles positive)
        let shape = (w, h, image.originX, image.originY)
        if p.backgroundSubtraction && (background.count != n || backgroundShape != shape) {
            // 🐱 Start from a grey-scale opening of the first frame: removes particle images (smaller than the
            // 🐱 structuring element) instead of baking them into the background as ghosts.
            let k = max(1, p.windowRadius + 1)
            background = Self.morphology(image.pixels, w, h, radius: k, erode: p.polarity == .brightOnDark)
            background = Self.morphology(background, w, h, radius: k, erode: p.polarity != .brightOnDark)
            backgroundShape = shape
        }
        image.pixels.withUnsafeBufferPointer { src in
            work.withUnsafeMutableBufferPointer { f in
                if p.backgroundSubtraction {
                    background.withUnsafeMutableBufferPointer { bg in
                        let slow = p.backgroundAlpha, fast: Float = 0.5
                        let bright = p.polarity == .brightOnDark
                        for i in 0..<n {
                            let v = src[i]
                            let d = bright ? v - bg[i] : bg[i] - v
                            f[i] = d > 0 ? d : 0
                            // 🐱 d > 0: pixel brighter than background in the particle direction (maybe a
                            // 🐱 particle) → follow slowly; otherwise follow fast.
                            bg[i] += (d > 0 ? slow : fast) * (v - bg[i])
                        }
                    }
                } else {
                    for i in 0..<n { f[i] = p.polarity == .brightOnDark ? src[i] : 255 - src[i] }
                }
            }
        }

        // 🐱 2. separable [1 2 1]/4 smoothing (edges replicate)
        if p.smoothing {
            work.withUnsafeMutableBufferPointer { f in
                tmp.withUnsafeMutableBufferPointer { t in
                    for y in 0..<h {
                        let r = y * w
                        t[r] = (3 * f[r] + f[r + 1]) * 0.25
                        for x in 1..<(w - 1) { t[r + x] = (f[r + x - 1] + 2 * f[r + x] + f[r + x + 1]) * 0.25 }
                        t[r + w - 1] = (f[r + w - 2] + 3 * f[r + w - 1]) * 0.25
                    }
                    for x in 0..<w {
                        f[x] = (3 * t[x] + t[w + x]) * 0.25
                        for y in 1..<(h - 1) { f[y * w + x] = (t[(y - 1) * w + x] + 2 * t[y * w + x] + t[(y + 1) * w + x]) * 0.25 }
                        f[(h - 1) * w + x] = (t[(h - 2) * w + x] + 3 * t[(h - 1) * w + x]) * 0.25
                    }
                }
            }
        }

        // 🐱 3. adaptive threshold
        var sum: Double = 0, sum2: Double = 0
        work.withUnsafeBufferPointer { f in
            for i in 0..<n { let v = Double(f[i]); sum += v; sum2 += v * v }
        }
        let mean = sum / Double(n)
        let std = sqrt(max(0, sum2 / Double(n) - mean * mean))
        let thr = max(p.minimumThreshold, Float(mean + Double(p.thresholdK) * std))
        lastThreshold = thr

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

        // 🐱 5. non-maximum suppression on a hash grid, then 6. sub-pixel fit
        let sep = max(1.0, p.minSeparation)
        let sep2 = sep * sep
        var grid: [Int: [(Double, Double)]] = [:]
        func key(_ x: Double, _ y: Double) -> Int { Int(floor(x / sep)) &* 73_856_093 ^ Int(floor(y / sep)) &* 19_349_663 }
        var out: [Particle] = []
        out.reserveCapacity(min(candidates.count, p.maxParticles))
        work.withUnsafeBufferPointer { f in
            for c in candidates {
                if out.count >= p.maxParticles { break }
                let cx = c.i % w, cy = c.i / w
                let px = Double(cx), py = Double(cy)
                var tooClose = false
                let gx = Int(floor(px / sep)), gy = Int(floor(py / sep))
                search: for dy in -1...1 {
                    for dx in -1...1 {
                        let k = (gx + dx) &* 73_856_093 ^ (gy + dy) &* 19_349_663
                        for q in grid[k] ?? [] where (q.0 - px) * (q.0 - px) + (q.1 - py) * (q.1 - py) < sep2 {
                            tooClose = true
                            break search
                        }
                    }
                }
                if tooClose { continue }
                grid[key(px, py), default: []].append((px, py))

                var mass: Float = 0
                var area = 0
                let ar = r + 2
                for yy in max(0, cy - ar)...min(h - 1, cy + ar) {
                    for xx in max(0, cx - ar)...min(w - 1, cx + ar) {
                        let v = f[yy * w + xx]
                        if v > thr { area += 1 }
                        if abs(yy - cy) <= r && abs(xx - cx) <= r { mass += v }
                    }
                }
                if area < p.minArea || area > p.maxArea { continue }

                let (ox, oy) = subpixelOffset(f, w, cx, cy, r, thr, p.subpixel)
                out.append(Particle(x: Double(image.originX + cx) + ox, y: Double(image.originY + cy) + oy,
                                    peak: c.v, mass: mass, area: area))
            }
        }
        return out
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

    private func subpixelOffset(_ f: UnsafeBufferPointer<Float>, _ w: Int, _ cx: Int, _ cy: Int, _ r: Int,
                                _ thr: Float, _ mode: DetectorParameters.Subpixel) -> (Double, Double) {
        let i = cy * w + cx
        if mode == .gaussian3Point {
            let floorV: Float = 0.5
            let c = log(Double(max(f[i], floorV)))
            let l = log(Double(max(f[i - 1], floorV))), rr = log(Double(max(f[i + 1], floorV)))
            let u = log(Double(max(f[i - w], floorV))), d = log(Double(max(f[i + w], floorV)))
            let denX = l - 2 * c + rr, denY = u - 2 * c + d
            if denX < -1e-9, denY < -1e-9 {
                let ox = (l - rr) / (2 * denX), oy = (u - d) / (2 * denY)
                if abs(ox) <= 1, abs(oy) <= 1 { return (ox, oy) }
            }
        }
        // 🐱 Centroid of the window, weighted by intensity above half threshold.
        var sw = 0.0, sx = 0.0, sy = 0.0
        let base = Double(thr) * 0.5
        for dy in -r...r {
            for dx in -r...r {
                let wgt = Double(f[i + dy * w + dx]) - base
                if wgt > 0 { sw += wgt; sx += wgt * Double(dx); sy += wgt * Double(dy) }
            }
        }
        return sw > 0 ? (sx / sw, sy / sw) : (0, 0)
    }
}
