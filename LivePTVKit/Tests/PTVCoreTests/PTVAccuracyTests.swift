import Foundation
import Testing
@testable import PTVCore

/// 🐱 Accuracy of detection in conditions where the earlier detector failed: dense images with particles of mixed
/// 🐱 brightness, pure noise, and slow Brownian particles under background subtraction. Numbers in comments are this
/// 🐱 code / the code before.

@Suite struct DetectorAccuracyTests {
    /// 🐱 Unique nearest matching within 1 px: (recall, precision).
    private func score(_ truth: [(Double, Double)], _ found: [Particle]) -> (recall: Double, precision: Double) {
        var used = Set<Int>()
        var hits = 0
        for f in found {
            var best = -1
            var bd = 1.0
            for (k, t) in truth.enumerated() where !used.contains(k) {
                let d = hypot(f.x - t.0, f.y - t.1)
                if d < bd { bd = d; best = k }
            }
            if best >= 0 { used.insert(best); hits += 1 }
        }
        return (Double(hits) / Double(truth.count), Double(hits) / Double(max(1, found.count)))
    }

    /// 🐱 Dense seeding (0.01 particles/px) with brightness spread over 30...200 grey levels: the whole-image mean + k·std
    /// 🐱 threshold rose with the particles themselves and lost the fainter half. Observed recall 1.00 / 0.44.
    @Test func recallInDenseImageOfMixedBrightness() {
        var rng = Synth(state: 11)
        let w = 256, h = 256
        var pts: [(Double, Double)] = []
        while pts.count < 650 {
            let c = (4 + rng.unit() * Double(w - 9), 4 + rng.unit() * Double(h - 9))
            if !pts.contains(where: { hypot($0.0 - c.0, $0.1 - c.1) < 4 }) { pts.append(c) }   // 🐱 resolvable pairs only
        }
        var img = [Float](repeating: 12, count: w * h)
        for (x, y) in pts {
            let peak = 30 + 170 * rng.unit()
            for yy in max(0, Int(y) - 4)...min(h - 1, Int(y) + 5) {
                for xx in max(0, Int(x) - 4)...min(w - 1, Int(x) + 5) {
                    let dx = Double(xx) - x, dy = Double(yy) - y
                    img[yy * w + xx] += Float(peak * exp(-(dx * dx + dy * dy) / (2 * 1.0 * 1.0)))
                }
            }
        }
        for i in img.indices { img[i] = Float(min(255, max(0, (Double(img[i]) + 3 * rng.gauss()).rounded()))) }
        let image = LumaImage(width: w, height: h, pixels: img)
        for background in [true, false] {
            var p = DetectorParameters()
            p.backgroundSubtraction = background
            let s = score(pts, ParticleDetector(parameters: p).detect(image))
            #expect(s.recall > 0.9, "background \(background): recall \(s.recall)")
            #expect(s.precision > 0.98, "background \(background): precision \(s.precision)")
        }
    }

    /// 🐱 Pure sensor noise (σ = 2 and 8 grey levels): essentially no detections, with and without background subtraction.
    @Test func noDetectionsInPureNoise() {
        var rng = Synth(state: 12)
        for noise in [2.0, 8.0] {
            for background in [true, false] {
                var p = DetectorParameters()
                p.backgroundSubtraction = background
                var total = 0
                for _ in 0..<3 {
                    let img = Synth.render([], w: 256, h: 256, background: 30, noise: noise, rng: &rng)
                    total += ParticleDetector(parameters: p).detect(img).count
                }
                #expect(total <= 1, "noise \(noise), background \(background): \(total) detections in 3 frames")
            }
        }
    }

    /// 🐱 Slow Brownian particles (≈ 0.54 px per axis per frame, images 6.4 px across) with background subtraction on:
    /// 🐱 the background must not learn the particles, or their centres are pushed along their recent motion and D comes
    /// 🐱 out too high. Lag-1/lag-2 estimator as used by the session evaluation. Observed D +5 % / +35 % (+4 % with
    /// 🐱 background subtraction off).
    @Test func brownianDiffusionWithBackgroundSubtraction() throws {
        var rng = Synth(state: 13)
        let w = 320, h = 240, fps = 24.0, dTrue = 3.5
        let step = (2 * dTrue / fps).squareRoot()
        var pts = (0..<200).map { _ in (10 + rng.unit() * Double(w - 20), 10 + rng.unit() * Double(h - 20)) }
        let detector = ParticleDetector()
        let tracker = ParticleTracker()
        let stats = SessionFieldStatistics(grid: GridGeometry(roi: PixelROI(x: 0, y: 0, width: w, height: h), cellSize: 64),
                                           minSamples: 2)
        for k in 0..<120 {
            let img = Synth.render(pts, w: w, h: h, sigma: 1.6, peak: 120, background: 20, noise: 3, rng: &rng)
            let found = detector.detect(img)
            let s = tracker.update(particles: found, time: Double(k) / fps, frameIndex: k)
            stats.add(s.samples, frameIndex: k, nominalInterval: 1 / fps)
            pts = pts.map { q in
                func reflect(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? 2 * lo - v : (v > hi ? 2 * hi - v : v) }
                return (reflect(q.0 + 0.8 / fps + step * rng.gauss(), 10, Double(w - 10)),
                        reflect(q.1 + 0.2 / fps + step * rng.gauss(), 10, Double(h - 10)))
            }
        }
        let d = try #require(stats.diffusion())
        #expect(abs(d.d - dTrue) / dTrue < 0.08, "D = \(d.d) px²/s (true \(dTrue))")
    }
}
