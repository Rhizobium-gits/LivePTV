import Foundation
import Testing
@testable import PTVCore

/// 🐱 Accuracy of detection and tracking in conditions where the earlier detector / tracker failed: dense images with
/// 🐱 particles of mixed brightness, pure noise, slow Brownian particles under background subtraction, and dense, fast
/// 🐱 flow where displacements reach the particle spacing. Numbers in comments are this code / the code before.

/// 🐱 Ground-truth particle sets moving in a Taylor–Green vortex array (RK4), with a share replaced every frame
/// 🐱 (out-of-plane loss), as in the liveptv-tool-bench P2 experiment.
struct TaylorGreen {
    var u: Double, l: Double = 128
    func velocity(_ x: Double, _ y: Double) -> (Double, Double) {
        (u * sin(.pi * x / l) * cos(.pi * y / l), -u * cos(.pi * x / l) * sin(.pi * y / l))
    }

    /// 🐱 frames[k] = [(truth id, x, y)]
    func simulate(count n: Int, width w: Double, height h: Double, frames: Int, replace: Double,
                  rng: inout Synth) -> [[(id: Int, x: Double, y: Double)]] {
        var xs = (0..<n).map { _ in 1 + rng.unit() * (w - 3) }, ys = (0..<n).map { _ in 1 + rng.unit() * (h - 3) }
        var ids = Array(0..<n)
        var next = n
        var out: [[(id: Int, x: Double, y: Double)]] = []
        for _ in 0..<frames {
            out.append((0..<n).map { (ids[$0], xs[$0], ys[$0]) })
            let sub = 8, hs = 1.0 / Double(sub)
            for i in 0..<n {
                var x = xs[i], y = ys[i]
                for _ in 0..<sub {
                    let k1 = velocity(x, y)
                    let k2 = velocity(x + hs / 2 * k1.0, y + hs / 2 * k1.1)
                    let k3 = velocity(x + hs / 2 * k2.0, y + hs / 2 * k2.1)
                    let k4 = velocity(x + hs * k3.0, y + hs * k3.1)
                    x += hs / 6 * (k1.0 + 2 * k2.0 + 2 * k3.0 + k4.0)
                    y += hs / 6 * (k1.1 + 2 * k2.1 + 2 * k3.1 + k4.1)
                }
                if rng.unit() < replace {
                    x = 1 + rng.unit() * (w - 3)
                    y = 1 + rng.unit() * (h - 3)
                    ids[i] = next
                    next += 1
                }
                xs[i] = x
                ys[i] = y
            }
        }
        return out
    }
}

/// 🐱 Frame-to-frame link precision and recall of a tracker run against the truth ids.
func linkScores(_ truth: [[(id: Int, x: Double, y: Double)]], _ trackIDs: [[Int]]) -> (precision: Double, recall: Double) {
    var made = 0, correct = 0, possible = 0
    for k in 1..<truth.count {
        var previousTruthOfTrack: [Int: Int] = [:]
        for (i, q) in truth[k - 1].enumerated() { previousTruthOfTrack[trackIDs[k - 1][i]] = q.id }
        let previousIDs = Set(truth[k - 1].map(\.id))
        for (i, q) in truth[k].enumerated() {
            if previousIDs.contains(q.id) { possible += 1 }
            if let was = previousTruthOfTrack[trackIDs[k][i]] {
                made += 1
                if was == q.id { correct += 1 }
            }
        }
    }
    return (Double(correct) / Double(max(1, made)), Double(correct) / Double(max(1, possible)))
}

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

@Suite struct TrackerAccuracyTests {
    private func particles(_ pts: [(id: Int, x: Double, y: Double)]) -> [Particle] {
        pts.map { Particle(x: $0.x, y: $0.y, peak: 100, mass: 500, area: 10) }
    }

    private func run(_ truth: [[(id: Int, x: Double, y: Double)]], _ tracker: ParticleTracker) -> [[Int]] {
        truth.enumerated().map { k, f in tracker.update(particles: particles(f), time: Double(k), frameIndex: k).trackIDs }
    }

    /// 🐱 5000 particles in 512² (spacing 7.2 px), up to 10 px per frame, 2 % replaced per frame, positions ±0.05 px:
    /// 🐱 the tracking-only P2 condition where closest-first assignment with nearest-neighbour start collapsed.
    /// 🐱 Observed link precision / recall 0.97 / 0.96, before 0.29 / 0.19.
    @Test func denseFastFlowLinks() {
        var rng = Synth(state: 21)
        var truth = TaylorGreen(u: 10).simulate(count: 5000, width: 512, height: 512, frames: 12, replace: 0.02, rng: &rng)
        for k in truth.indices {
            truth[k] = truth[k].map { ($0.id, $0.x + 0.05 * rng.gauss(), $0.y + 0.05 * rng.gauss()) }
        }
        let s = linkScores(truth, run(truth, ParticleTracker()))
        #expect(s.precision > 0.9, "precision \(s.precision)")
        #expect(s.recall > 0.85, "recall \(s.recall)")
    }

    /// 🐱 The two-frame problem: a uniform shift of 1.3 particle spacings, no velocity known yet. The nearest particle is
    /// 🐱 usually the wrong one; the neighbour-consistency vote finds the common displacement. Observed 1.00 / 0.03.
    @Test func firstFramePairWithDisplacementBeyondSpacing() {
        var rng = Synth(state: 22)
        let n = 3000
        let a = (0..<n).map { (id: $0, x: 20 + rng.unit() * 472, y: 20 + rng.unit() * 472) }   // 🐱 spacing ≈ 8.6 px
        let b = a.map { (id: $0.id, x: $0.x + 9, y: $0.y + 6) }                                    // 🐱 10.8 px
        let tracker = ParticleTracker()
        let ids = run([a, b], tracker)
        let s = linkScores([a, b], ids)
        #expect(s.precision > 0.95 && s.recall > 0.95, "precision \(s.precision), recall \(s.recall)")
    }

    /// 🐱 A fast particle on a tight circle (14 px per frame on a radius of 42 px): the constant-velocity prediction misses
    /// 🐱 by 4.7 px, more than the 4 px prediction radius; the speed-dependent gate (4 + 0.1 · 14 = 5.4 px) keeps the track.
    @Test func fastCurvedTrackIsKept() {
        var parameters = TrackerParameters()
        parameters.maxDisplacement = 16
        let tracker = ParticleTracker(parameters: parameters)
        let radius = 42.0, omega = 2 * asin(14 / (2 * radius))
        var ids: [Int] = []
        for k in 0..<30 {
            let a = omega * Double(k)
            let q = Particle(x: 200 + radius * cos(a), y: 200 + radius * sin(a), peak: 100, mass: 500, area: 10)
            ids.append(tracker.update(particles: [q], time: Double(k), frameIndex: k).trackIDs[0])
        }
        #expect(Set(ids).count == 1, "track ids \(Set(ids).sorted())")
    }

    /// 🐱 Closest-first takes the cheapest pair and leaves the other track without a candidate; the global assignment
    /// 🐱 links both, because that has the lower total cost.
    @Test func globalAssignmentBeatsClosestFirst() {
        func p(_ x: Double, _ y: Double) -> Particle { Particle(x: x, y: y, peak: 100, mass: 500, area: 10) }
        for global in [true, false] {
            var parameters = TrackerParameters()
            parameters.globalAssignment = global
            let tracker = ParticleTracker(parameters: parameters)
            // 🐱 A moves +3 px/frame, B −3 px/frame on the same line; predictions A → (103, 100), B → (107, 100).
            _ = tracker.update(particles: [p(94, 100), p(116, 100)], time: 0, frameIndex: 0)
            _ = tracker.update(particles: [p(97, 100), p(113, 100)], time: 1, frameIndex: 1)
            let ab = tracker.update(particles: [p(100, 100), p(110, 100)], time: 2, frameIndex: 2).trackIDs
            // 🐱 p = (104.5, 100): 1.5 px from A's prediction, 2.5 px from B's. q = (101, 102.5): 3.2 px from A's, out of B's
            // 🐱 gate. Closest-first: A→p, B nothing. Minimum total cost: A→q, B→p.
            let ids = tracker.update(particles: [p(101, 102.5), p(104.5, 100)], time: 3, frameIndex: 3).trackIDs
            if global {
                #expect(ids == [ab[0], ab[1]])
            } else {
                #expect(ids[1] == ab[0] && ids[0] != ab[1])
            }
        }
    }
}
