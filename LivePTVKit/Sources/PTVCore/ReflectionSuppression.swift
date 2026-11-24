import Accelerate
import Foundation

/// 🐱 What the camera sees that is not the flow, and how it is removed before correlation:
/// 🐱 static reflections, glare on the container, labels and scratches (temporal background subtraction),
/// 🐱 areas washed out by static glare (glare mask), moving glints such as the free-surface sparkle (saturated-blob
/// 🐱 mask) and user-drawn exclusions. Container walls are masked by `RefractionMap`.
public struct ReflectionParameters: Codable, Equatable, Sendable {
    public enum Background: String, Codable, CaseIterable, Sendable, Identifiable {
        /// 🐱 no temporal background (raw frames)
        case off
        /// 🐱 running mean: the lowest-noise estimate, for any tracer, texture or turbidity pattern (default)
        case mean
        /// 🐱 lower envelope (bright tracers): follows a dimming background at once, but its noise floor leaves a weak
        /// 🐱 static pattern (measured: ensemble error 8.7 % → 10.0 % on faint images)
        case minimum
        /// 🐱 upper envelope (dark tracers on a bright, back-lit background)
        case maximum

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .off: return "Off"
            case .mean: return "Running mean (recommended)"
            case .minimum: return "Lower envelope (bright tracers)"
            case .maximum: return "Upper envelope (dark tracers, back-lit)"
            }
        }
    }

    public var background: Background = .mean
    /// 🐱 Memory of the background in frames: it follows the image towards the tracer side with rate 1/memory, so
    /// 🐱 anything that stays put for longer than this (reflections, labels, scratches) becomes background. Keep it
    /// 🐱 well above the time a tracer image needs to move by its own diameter.
    public var backgroundMemoryFrames = 300
    /// 🐱 Static glare: background pixels at least `glareLevel` (grey levels) and `glareMargin` above the median
    /// 🐱 background are masked. Particles there have little contrast and shot noise is high.
    public var glareMasking = true
    public var glareLevel: Float = 200
    public var glareMargin: Float = 60
    /// 🐱 Moving glints: blobs of saturated pixels (at least half of a 5×5 neighbourhood) where the background is
    /// 🐱 not itself saturated are masked in that frame.
    public var saturationMasking = true
    public var saturationLevel: Float = 250
    /// 🐱 Grow every glare / glint mask by this many full-frame pixels (halo, blooming).
    public var maskDilationPx = 3
    /// 🐱 User-drawn areas to ignore (labels, ruler, a reflection the automatic masks miss), full-frame px.
    public var exclusions: [PixelROI] = []

    public init() {}
}

/// 🐱 Share of the analysed area masked in the last frame, by reason (percent; reasons can overlap).
public struct MaskStatistics: Codable, Equatable, Sendable {
    public var maskedPercent = 0.0
    public var staticPercent = 0.0
    public var glarePercent = 0.0
    public var saturatedPercent = 0.0
    public init() {}
}

/// 🐱 Temporal background subtraction plus glare / glint masks for one stream of analysed frames.
/// 🐱 Keeps state: call `process` once per frame in time order, and `reset()` on discontinuities.
public final class ReflectionSuppressor {
    public var parameters: ReflectionParameters
    public private(set) var background: [Float] = []
    public private(set) var lastStatistics = MaskStatistics()
    /// 🐱 Masks of the last frame (1 usable, 0 masked), kept for display and figures. Nil = nothing masked.
    public private(set) var lastStaticMask: [Float]?
    public private(set) var lastGlareMask: [Float]?
    public private(set) var lastSaturationMask: [Float]?
    public private(set) var geometry = (width: 0, height: 0, originX: 0, originY: 0, scale: 1)
    public private(set) var framesSeen = 0
    private var glareAge = Int.max
    private var mode: ReflectionParameters.Background?

    public init(parameters: ReflectionParameters = ReflectionParameters()) { self.parameters = parameters }

    /// 🐱 Frames averaged before the running mean is subtracted (tracer ghosts ≤ 1/30 of a tracer's brightness).
    public static let meanWarmupFrames = 30
    public var isWarmingUp: Bool { parameters.background == .mean && framesSeen < Self.meanWarmupFrames }

    public func reset() {
        background = []
        framesSeen = 0
        glareAge = Int.max
        lastGlareMask = nil
        lastSaturationMask = nil
        lastStaticMask = nil
    }

    /// 🐱 One analysed frame. Returns the foreground (background removed; the raw frame when the background is off)
    /// 🐱 and the usable-pixel mask (static ∧ no glare ∧ no glint), nil when nothing is masked.
    /// 🐱 `updateBackground: false` uses the current background without learning from this frame (an out-of-order frame).
    public func process(_ img: LumaImage, staticMask: [Float]?, updateBackground: Bool = true) -> (image: LumaImage, mask: [Float]?) {
        let p = parameters
        let n = img.pixels.count
        let shape = (img.width, img.height, img.originX, img.originY, img.scale)
        if shape != geometry || mode != p.background || background.count != n {
            reset()
            geometry = (img.width, img.height, img.originX, img.originY, img.scale)
            mode = p.background
        }
        var out = img
        if p.background != .off {
            if framesSeen == 0 { background = Self.initialBackground(img, mode: p.background) }
            // 🐱 the mean needs a few frames before it no longer contains individual tracers (they would come back as
            // 🐱 negative ghosts): until then the raw frame is used
            if p.background != .mean || framesSeen >= Self.meanWarmupFrames {
                out.pixels = foreground(img.pixels, mode: p.background)
            }
            if updateBackground { learn(img.pixels, mode: p.background) }
        }
        if updateBackground { framesSeen += 1 }
        let dilation = max(1, Int((Double(p.maskDilationPx) / Double(img.scale)).rounded()))

        // 🐱 static glare from the background (refreshed every 10 frames: it changes slowly by construction)
        if p.glareMasking && p.background != .off {
            if updateBackground { glareAge = glareAge == Int.max ? Int.max : glareAge + 1 }
            if glareAge == Int.max || glareAge >= 10 {
                lastGlareMask = glareMask(width: img.width, height: img.height, dilation: dilation)
                glareAge = 0
            }
        } else {
            lastGlareMask = nil
        }
        lastSaturationMask = p.saturationMasking ? saturationMask(img, dilation: dilation) : nil
        lastStaticMask = staticMask?.count == n ? staticMask : nil

        var combined: [Float]?
        for m in [lastStaticMask, lastGlareMask, lastSaturationMask] {
            guard let m else { continue }
            if combined == nil { combined = m } else { vDSP_vmul(combined!, 1, m, 1, &combined!, 1, vDSP_Length(n)) }
        }
        var st = MaskStatistics()
        func maskedShare(_ m: [Float]?) -> Double {
            guard let m, n > 0 else { return 0 }
            var s: Float = 0
            vDSP_sve(m, 1, &s, vDSP_Length(n))
            return 100 * (1 - Double(s) / Double(n))
        }
        st.maskedPercent = maskedShare(combined)
        st.staticPercent = maskedShare(lastStaticMask)
        st.glarePercent = maskedShare(lastGlareMask)
        st.saturatedPercent = maskedShare(lastSaturationMask)
        lastStatistics = st
        if st.maskedPercent <= 0 { combined = nil }
        return (out, combined)
    }

    // 🐱 MARK: background

    /// 🐱 First background: a grey-scale opening (minimum mode) or closing (maximum mode) removes tracer images,
    /// 🐱 which are smaller than the structuring element, so they are not baked in as ghosts.
    static func initialBackground(_ img: LumaImage, mode: ReflectionParameters.Background) -> [Float] {
        let r = 2
        switch mode {
        case .minimum:
            let e = ParticleDetector.morphology(img.pixels, img.width, img.height, radius: r, erode: true)
            return ParticleDetector.morphology(e, img.width, img.height, radius: r, erode: false)
        case .maximum:
            let d = ParticleDetector.morphology(img.pixels, img.width, img.height, radius: r, erode: false)
            return ParticleDetector.morphology(d, img.width, img.height, radius: r, erode: true)
        case .mean, .off:
            return img.pixels
        }
    }

    /// 🐱 minimum / mean: I − B; maximum: B − I (tracers become bright; correlation does not care). Signed, not
    /// 🐱 clipped at zero: clipping would cut half of the noise distribution, a non-linearity that lowers correlation
    /// 🐱 quality on faint images (measured: ensemble error 8.6 % → 9.6 % with clipping).
    private func foreground(_ px: [Float], mode: ReflectionParameters.Background) -> [Float] {
        let n = px.count
        var f = [Float](repeating: 0, count: n)
        switch mode {
        case .minimum:
            vDSP_vsub(background, 1, px, 1, &f, 1, vDSP_Length(n))
        case .maximum:
            vDSP_vsub(px, 1, background, 1, &f, 1, vDSP_Length(n))
        case .mean:
            vDSP_vsub(background, 1, px, 1, &f, 1, vDSP_Length(n))
        case .off:
            return px
        }
        return f
    }

    /// 🐱 Asymmetric running update: towards the tracer side slowly (1/memory per frame), away from it fast (0.5), so
    /// 🐱 the background tracks the envelope that tracers never reach; the mean mode uses the cumulative mean while
    /// 🐱 fewer than `memory` frames were seen.
    private func learn(_ px: [Float], mode: ReflectionParameters.Background) {
        let n = px.count
        let slow = 1 / Float(max(2, parameters.backgroundMemoryFrames))
        var d = [Float](repeating: 0, count: n)
        vDSP_vsub(background, 1, px, 1, &d, 1, vDSP_Length(n))     // 🐱 d = I − B
        switch mode {
        case .mean:
            var rate = max(slow, 1 / Float(framesSeen + 1))
            vDSP_vsma(d, 1, &rate, background, 1, &background, 1, vDSP_Length(n))
        case .minimum, .maximum:
            var pos = [Float](repeating: 0, count: n)
            var z: Float = 0
            vDSP_vthres(d, 1, &z, &pos, 1, vDSP_Length(n))         // 🐱 max(d, 0)
            vDSP_vsub(pos, 1, d, 1, &d, 1, vDSP_Length(n))          // 🐱 min(d, 0)
            var up: Float = mode == .minimum ? slow : 0.5
            var down: Float = mode == .minimum ? 0.5 : slow
            vDSP_vsma(pos, 1, &up, background, 1, &background, 1, vDSP_Length(n))
            vDSP_vsma(d, 1, &down, background, 1, &background, 1, vDSP_Length(n))
        case .off:
            break
        }
    }

    // 🐱 MARK: masks

    /// 🐱 1 where usable: background below max(glareLevel, median background + glareMargin), grown by `dilation`.
    private func glareMask(width w: Int, height h: Int, dilation: Int) -> [Float]? {
        let n = background.count
        guard n > 0 else { return nil }
        // 🐱 median of a regular subsample (≤ 4096 pixels)
        let stride = max(1, n / 4096)
        var sample: [Double] = []
        sample.reserveCapacity(n / stride + 1)
        var k = 0
        while k < n { sample.append(Double(background[k])); k += stride }
        let median = Float(GridKernels.median(of: sample) ?? 0)
        let threshold = max(parameters.glareLevel, median + parameters.glareMargin)
        var top: Float = 0
        vDSP_maxv(background, 1, &top, vDSP_Length(n))
        guard top >= threshold else { return nil }
        let hits = Self.indicator(background, atLeast: threshold)
        return Self.usable(grow: hits, w, h, by: dilation)
    }

    /// 🐱 Saturated blobs of this frame where the background is not saturated (a back-lit, clipped background is
    /// 🐱 not a glint), grown by the blob radius plus `dilation`.
    private func saturationMask(_ img: LumaImage, dilation: Int) -> [Float]? {
        let n = img.pixels.count
        let level = parameters.saturationLevel
        var top: Float = 0
        vDSP_maxv(img.pixels, 1, &top, vDSP_Length(n))
        guard top >= level else { return nil }
        var sat = Self.indicator(img.pixels, atLeast: level)
        if background.count == n {
            // 🐱 × (B < level − 10)
            let bgSat = Self.indicator(background, atLeast: level - 10)
            var notBg = [Float](repeating: 1, count: n)
            vDSP_vsub(bgSat, 1, notBg, 1, &notBg, 1, vDSP_Length(n))
            vDSP_vmul(sat, 1, notBg, 1, &sat, 1, vDSP_Length(n))
        }
        // 🐱 blob cores: at least half of the 5×5 neighbourhood saturated (isolated bright tracers are kept)
        let density = PIVEngine.boxBlur(sat, img.width, img.height, radius: 2)
        let cores = Self.indicator(density, atLeast: 0.5)
        var any: Float = 0
        vDSP_maxv(cores, 1, &any, vDSP_Length(n))
        guard any > 0 else { return nil }
        return Self.usable(grow: cores, img.width, img.height, by: 2 + dilation)
    }

    /// 🐱 1 where v ≥ level, else 0.
    static func indicator(_ v: [Float], atLeast level: Float) -> [Float] {
        let n = v.count
        var t = [Float](repeating: 0, count: n)
        var negLevel = -level
        vDSP_vsadd(v, 1, &negLevel, &t, 1, vDSP_Length(n))
        // 🐱 vlim: t ≥ 0 → +0.5, else −0.5; then + 0.5
        var zero: Float = 0, half: Float = 0.5
        vDSP_vlim(t, 1, &zero, &half, &t, 1, vDSP_Length(n))
        vDSP_vsadd(t, 1, &half, &t, 1, vDSP_Length(n))
        return t
    }

    /// 🐱 Usable mask (1 − dilated hits): a pixel is masked if any hit lies within `r` px (box neighbourhood).
    static func usable(grow hits: [Float], _ w: Int, _ h: Int, by r: Int) -> [Float] {
        let n = hits.count
        let spread = r > 0 ? PIVEngine.boxBlur(hits, w, h, radius: r) : hits
        // 🐱 any hit in the box → mean ≥ 1/(2r+1)² > 1e-3·… ; threshold just above zero
        let near = indicator(spread, atLeast: 1e-4)
        var out = [Float](repeating: 1, count: n)
        vDSP_vsub(near, 1, out, 1, &out, 1, vDSP_Length(n))
        return out
    }
}

/// 🐱 Pixels excluded for the whole recording: user exclusions and everything outside the fluid / inside the wall
/// 🐱 band of the container (from `RefractionMap`), on the analysed-image grid.
public enum StaticMask {
    /// 🐱 1 = usable, 0 = excluded; nil when nothing is excluded.
    public static func build(width w: Int, height h: Int, originX: Int, originY: Int, scale: Int,
                             exclusions: [PixelROI], container: RefractionMap?) -> [Float]? {
        guard w > 0, h > 0, !exclusions.isEmpty || container != nil else { return nil }
        var m = [Float](repeating: 1, count: w * h)
        let s = Double(max(1, scale))
        // 🐱 full-frame centre of analysed pixel i: origin + (i + 0.5)·s − 0.5
        func fx(_ i: Int) -> Double { Double(originX) + (Double(i) + 0.5) * s - 0.5 }
        func fy(_ j: Int) -> Double { Double(originY) + (Double(j) + 0.5) * s - 0.5 }
        if let map = container {
            m.withUnsafeMutableBufferPointer { M in
                let mp = M.baseAddress!
                var j = 0
                while j < h {
                    let y = fy(j)
                    var i = 0
                    while i < w {
                        if !map.isUsable(x: fx(i), y: y) { mp[j * w + i] = 0 }
                        i += 1
                    }
                    j += 1
                }
            }
        }
        for r in exclusions {
            // 🐱 analysed pixels whose centre lies inside the rectangle
            let i0 = max(0, Int(ceil((Double(r.x) + 0.5 - Double(originX)) / s - 0.5)))
            let i1 = min(w - 1, Int(floor((Double(r.x + r.width) - 0.5 - Double(originX)) / s - 0.5)))
            let j0 = max(0, Int(ceil((Double(r.y) + 0.5 - Double(originY)) / s - 0.5)))
            let j1 = min(h - 1, Int(floor((Double(r.y + r.height) - 0.5 - Double(originY)) / s - 0.5)))
            guard i0 <= i1, j0 <= j1 else { continue }
            var j = j0
            while j <= j1 {
                var zero: Float = 0
                m.withUnsafeMutableBufferPointer { vDSP_vfill(&zero, $0.baseAddress! + j * w + i0, 1, vDSP_Length(i1 - i0 + 1)) }
                j += 1
            }
        }
        var minV: Float = 1
        vDSP_minv(m, 1, &minV, vDSP_Length(m.count))
        return minV < 1 ? m : nil
    }
}

extension PIVField {
    /// 🐱 Windows whose usable share in `image` (its mask) is below 1 − `maxMaskedFraction` become `masked`
    /// 🐱 (used for ensemble fields, which are computed without the per-pair mask check).
    public mutating func applyMask(of image: PIVImage, maxMaskedFraction: Double) {
        let wa = max(2, windowSize / max(1, image.scale))
        guard let cov = image.coverage(window: wa) else { return }
        let s = Double(max(1, image.scale))
        let minCoverage = Float(1 - max(0, min(1, maxMaskedFraction)))
        var k = 0
        while k < count {
            // 🐱 full-frame px → analysed px: (x − origin + 0.5)/s − 0.5
            let i = Int(((x(k) - Double(image.originX) + 0.5) / s - 0.5).rounded())
            let j = Int(((y(k) - Double(image.originY) + 0.5) / s - 0.5).rounded())
            if i >= 0, j >= 0, i < image.width, j < image.height, cov[j * image.width + i] < minCoverage {
                status[k] = .masked
                dx[k] = 0
                dy[k] = 0
            }
            k += 1
        }
    }

    /// 🐱 Counts of the fractional part of the valid displacements in analysed px (20 bins over −0.5…0.5). Peak
    /// 🐱 locking piles them up in the middle bins.
    public func subpixelHistogram(scale: Int) -> [Int] {
        var h = [Int](repeating: 0, count: 20)
        let inv = 1 / Double(max(1, scale))
        var k = 0
        while k < count {
            if status[k] == .valid {
                for d in [dx[k] * inv, dy[k] * inv] {
                    let f = d - d.rounded()
                    h[min(19, max(0, Int((f + 0.5) * 20)))] += 1
                }
            }
            k += 1
        }
        return h
    }

    /// 🐱 Median per-vector uncertainty (px) of the valid vectors.
    public var medianSigma: Double? {
        var v: [Double] = []
        var k = 0
        while k < count {
            if status[k] == .valid, let s = sigma(k) { v.append(s) }
            k += 1
        }
        return GridKernels.median(of: v)
    }
}
