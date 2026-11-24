import Foundation
import Testing
@testable import PTVCore

/// 🐱 Minimal Gaussian particle renderer + RNG (PTVCore tests must not depend on CameraKit).
struct Synth {
    var state: UInt64
    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    static func render(_ pts: [(Double, Double)], w: Int, h: Int, sigma: Double = 1.2, peak: Double = 180,
                       background: Double = 12, noise: Double = 0, rng: inout Synth) -> LumaImage {
        var img = [Float](repeating: Float(background), count: w * h)
        let r = Int(ceil(3.5 * sigma))
        for (x, y) in pts {
            for yy in max(0, Int(y) - r)...min(h - 1, Int(y) + r + 1) {
                for xx in max(0, Int(x) - r)...min(w - 1, Int(x) + r + 1) {
                    let dx = Double(xx) - x, dy = Double(yy) - y
                    img[yy * w + xx] += Float(peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
                }
            }
        }
        for i in img.indices {
            img[i] = Float(min(255, max(0, (Double(img[i]) + (noise > 0 ? noise * rng.gauss() : 0)).rounded())))
        }
        return LumaImage(width: w, height: h, pixels: img)
    }

    /// 🐱 Points on a jittered grid: well separated, random sub-pixel phase.
    static func grid(w: Int, h: Int, spacing: Double, rng: inout Synth) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        var y = spacing
        while y < Double(h) - spacing {
            var x = spacing
            while x < Double(w) - spacing {
                pts.append((x + (rng.unit() - 0.5) * spacing * 0.5, y + (rng.unit() - 0.5) * spacing * 0.5))
                x += spacing
            }
            y += spacing
        }
        return pts
    }
}

@Suite struct DetectorTests {
    private func match(_ truth: [(Double, Double)], _ found: [Particle], within: Double = 1.0) -> (recall: Double, rms: Double) {
        var errs: [Double] = []
        for t in truth {
            let best = found.map { hypot($0.x - t.0, $0.y - t.1) }.min() ?? .infinity
            if best < within { errs.append(best) }
        }
        let rms = errs.isEmpty ? .infinity : sqrt(errs.map { $0 * $0 }.reduce(0, +) / Double(errs.count))
        return (Double(errs.count) / Double(truth.count), rms)
    }

    @Test func subpixelAccuracyNoiseFree() {
        var rng = Synth(state: 1)
        let pts = Synth.grid(w: 320, h: 240, spacing: 16, rng: &rng)
        let img = Synth.render(pts, w: 320, h: 240, rng: &rng)
        var p = DetectorParameters()
        p.backgroundSubtraction = false
        p.smoothing = false
        let found = ParticleDetector(parameters: p).detect(img)
        let m = match(pts, found)
        #expect(m.recall > 0.99)
        #expect(m.rms < 0.06)               // 🐱 8-bit quantisation limits the 3-point estimator
        #expect(found.count == pts.count)   // 🐱 no false positives
    }

    @Test func robustToNoiseWithDefaults() {
        var rng = Synth(state: 2)
        let pts = Synth.grid(w: 320, h: 240, spacing: 14, rng: &rng)
        let img = Synth.render(pts, w: 320, h: 240, noise: 3, rng: &rng)
        var p = DetectorParameters()
        p.backgroundSubtraction = false
        let found = ParticleDetector(parameters: p).detect(img)
        let m = match(pts, found)
        #expect(m.recall > 0.97)
        #expect(m.rms < 0.15)
        #expect(Double(found.count) < Double(pts.count) * 1.03)
    }

    @Test func darkParticlesOnBrightBackground() {
        var rng = Synth(state: 3)
        let pts = Synth.grid(w: 200, h: 160, spacing: 16, rng: &rng)
        var img = Synth.render(pts, w: 200, h: 160, rng: &rng)
        img.pixels = img.pixels.map { 255 - $0 }
        var p = DetectorParameters()
        p.polarity = .darkOnBright
        p.backgroundSubtraction = false
        #expect(match(pts, ParticleDetector(parameters: p).detect(img)).recall > 0.99)
    }

    @Test func backgroundSubtractionRemovesStaticSpot() {
        var rng = Synth(state: 4)
        let detector = ParticleDetector()
        // 🐱 A bright static spot plus moving particles: after the background settles only the movers remain.
        var lastFound: [Particle] = []
        var lastTruth: [(Double, Double)] = []
        for k in 0..<200 {
            let shift: Double = Double(k) * 0.7
            let movers: [(Double, Double)] = (0..<20).map { (i: Int) -> (Double, Double) in
                let x: Double = 20 + Double(i) * 8 + shift
                let y: Double = 40 + Double(i % 5) * 20
                return (x, y)
            }
            lastTruth = movers.filter { $0.0 < 190 }
            lastFound = detector.detect(Synth.render(lastTruth + [(100, 140)], w: 200, h: 160, rng: &rng))
        }
        #expect(!lastFound.contains { hypot($0.x - 100, $0.y - 140) < 2 })
        #expect(match(lastTruth, lastFound).recall > 0.9)
    }

    @Test func roiOffsetIsApplied() {
        var rng = Synth(state: 5)
        let img = Synth.render([(30.3, 20.6)], w: 64, h: 48, rng: &rng)
        let shifted = LumaImage(width: 64, height: 48, originX: 100, originY: 200, pixels: img.pixels)
        var p = DetectorParameters()
        p.backgroundSubtraction = false
        let f = ParticleDetector(parameters: p).detect(shifted)
        #expect(f.count == 1)
        #expect(abs(f[0].x - 130.3) < 0.1 && abs(f[0].y - 220.6) < 0.1)
    }
}

@Suite struct TrackerTests {
    private func particles(_ pts: [(Double, Double)]) -> [Particle] {
        pts.map { Particle(x: $0.0, y: $0.1, peak: 100, mass: 500, area: 10) }
    }

    @Test func uniformMotionGivesExactVelocities() {
        var rng = Synth(state: 7)
        let base = Synth.grid(w: 640, h: 480, spacing: 20, rng: &rng)
        let tracker = ParticleTracker()
        let fps = 30.0, dxPerFrame = 3.0, dyPerFrame = -1.5
        var samples: [VelocitySample] = []
        for k in 0..<10 {
            let pts = base.map { ($0.0 + dxPerFrame * Double(k), $0.1 + dyPerFrame * Double(k)) }
            samples += tracker.update(particles: particles(pts), time: Double(k) / fps, frameIndex: k).samples
        }
        #expect(samples.count == base.count * 9)
        #expect(samples.allSatisfy { abs($0.u - dxPerFrame * fps) < 1e-6 && abs($0.v - dyPerFrame * fps) < 1e-6 })
        #expect(Set(samples.map(\.trackID)).count == base.count)   // 🐱 no identity switches
    }

    @Test func droppedFrameUsesRealTimeStep() {
        let tracker = ParticleTracker()
        _ = tracker.update(particles: particles([(100, 100)]), time: 0, frameIndex: 0)
        _ = tracker.update(particles: particles([(104, 100)]), time: 1.0 / 30, frameIndex: 1)
        // 🐱 frame 2 lost: next observation is two intervals later, displaced twice as far.
        let s = tracker.update(particles: particles([(112, 100)]), time: 3.0 / 30, frameIndex: 3).samples
        #expect(s.count == 1)
        #expect(abs(s[0].u - 120) < 1e-6 && abs(s[0].dt - 2.0 / 30) < 1e-12)
    }

    @Test func predictionDisambiguatesCrossingNeighbours() {
        // 🐱 Two particles approach each other; nearest-neighbour alone would swap them, prediction does not.
        let tracker = ParticleTracker()
        var ids: [[Int]] = []
        for k in 0..<6 {
            let a = (100 + 6 * Double(k), 100.0), b = (160 - 6 * Double(k), 103.0)
            ids.append(tracker.update(particles: particles([a, b]), time: Double(k), frameIndex: k).trackIDs)
        }
        #expect(Set(ids.map { $0[0] }).count == 1)
        #expect(Set(ids.map { $0[1] }).count == 1)
    }

    @Test func nonAdvancingTimeResets() {
        let tracker = ParticleTracker()
        _ = tracker.update(particles: particles([(10, 10)]), time: 1, frameIndex: 0)
        let s = tracker.update(particles: particles([(11, 10)]), time: 1, frameIndex: 1)
        #expect(s.samples.isEmpty && s.started == 1)
    }
}

@Suite struct FieldTests {
    @Test func averagesAndFlagsOutlier() {
        let roi = PixelROI(x: 0, y: 0, width: 160, height: 160)
        var p = FieldParameters()
        p.cellSize = 32
        let acc = VelocityFieldAccumulator(roi: roi, parameters: p)
        var samples: [VelocitySample] = []
        for j in 0..<5 {
            for i in 0..<5 {
                let corrupt = (i == 2 && j == 2)
                for k in 0..<5 {
                    samples.append(VelocitySample(trackID: k, frameIndex: 0, x: Double(i) * 32 + 16, y: Double(j) * 32 + 16, t: 0.5,
                                                  dx: 0, dy: 0, dt: 1, u: corrupt ? -200 : 100 + Double(k), v: 10))
                }
            }
        }
        acc.add(samples)
        let snap = acc.snapshot(at: 1.0)
        #expect(snap.columns == 5 && snap.rows == 5)
        let c = snap.cell(i: 0, j: 0)!
        #expect(abs(c.u - 102) < 1e-9 && c.count == 5 && c.valid)
        #expect(snap.cell(i: 2, j: 2)!.outlier)
        #expect(snap.validCount == 24)
        // 🐱 Everything expires after the window.
        #expect(acc.snapshot(at: 2.0).validCount == 0)
    }

    @Test func calibrationUnits() {
        #expect(Calibration().unitLabel == "px/s")
        let c = Calibration(mmPerPixel: 0.05)
        #expect(c.unitLabel == "mm/s" && abs(c.physical(200) - 10) < 1e-12)
    }
}
