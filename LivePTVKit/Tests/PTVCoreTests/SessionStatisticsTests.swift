import Foundation
import Testing
@testable import PTVCore

@Suite struct SessionStatisticsTests {
    @Test func vorticityAndDivergenceOfRotation() {
        // 🐱 u = −Ω(y−cy), v = Ω(x−cx) in image coordinates is clockwise on screen ⇒ ω(ccw) = −2Ω, div = 0.
        let omega = 0.5, cols = 8, rows = 6, h = 10.0
        var u: [Double?] = [], v: [Double?] = []
        for j in 0..<rows {
            for i in 0..<cols {
                let x = (Double(i) + 0.5) * h, y = (Double(j) + 0.5) * h
                u.append(-omega * (y - 30))
                v.append(omega * (x - 40))
            }
        }
        u[20] = nil; v[20] = nil   // 🐱 a gap: neighbours fall back to one-sided differences
        let d = FieldDerivatives.compute(columns: cols, rows: rows, spacing: h, u: u, v: v)
        for k in 0..<(cols * rows) where k != 20 {
            #expect(abs(d.vorticity[k]! - (-2 * omega)) < 1e-9)
            #expect(abs(d.divergence[k]!) < 1e-9)
        }
        #expect(d.vorticity[20] == nil)
    }

    @Test func cellMeansStdAndUncertainty() {
        let stats = SessionFieldStatistics(grid: GridGeometry(roi: PixelROI(x: 0, y: 0, width: 100, height: 100), cellSize: 50), minSamples: 5)
        var batch: [VelocitySample] = []
        for k in 0..<100 {
            let u = 10 + Double(k % 2 == 0 ? 1 : -1)   // 🐱 mean 10, std ≈ 1
            batch.append(VelocitySample(trackID: k, frameIndex: 1, x: 25, y: 25, t: 0, dx: u / 30, dy: 0, dt: 1.0 / 30, u: u, v: 0))
        }
        batch.append(VelocitySample(trackID: 999, frameIndex: 1, x: 75, y: 75, t: 0, dx: 9, dy: 9, dt: 1.0 / 30, u: 270, v: 270, outlier: true))
        stats.add(batch, frameIndex: 1, nominalInterval: 1.0 / 30)
        let cells = stats.cells()
        #expect(cells[0].count == 100 && cells[0].valid)
        #expect(abs(cells[0].meanU - 10) < 1e-12)
        #expect(abs(cells[0].stdU - sqrt(100.0 / 99.0)) < 1e-9)
        #expect(abs(cells[0].standardErrorU - cells[0].stdU / 10) < 1e-12)
        #expect(cells[3].count == 0 && !cells[3].valid)   // 🐱 the outlier was excluded
        #expect(stats.outliers == 1 && stats.samples == 100)
    }

    @Test(arguments: [false, true]) func diffusionRecoveredWithDriftAndNoise(injectMismatches: Bool) {
        // 🐱 Known D = 2 px²/s, localisation noise σ = 0.1 px, plus a uniform drift that must not bias D.
        var rng = SynthRNG(state: 99)
        let D = 2.0, sigma = 0.1, T = 1.0 / 30, drift = (u: 15.0, v: -5.0)
        let stats = SessionFieldStatistics(grid: GridGeometry(roi: PixelROI(x: 0, y: 0, width: 400, height: 400), cellSize: 100), minSamples: 5)
        var nextID = 0
        var tracks: [(id: Int, x: Double, y: Double, ox: Double, oy: Double)] = (0..<400).map { _ in
            let x = rng.unit() * 300 + 50, y = rng.unit() * 300 + 50
            nextID += 1
            return (nextID, x, y, x + sigma * rng.gauss(), y + sigma * rng.gauss())
        }
        for frame in 1...300 {
            var batch: [VelocitySample] = []
            for k in tracks.indices {
                var t = tracks[k]
                t.x += drift.u * T + sqrt(2 * D * T) * rng.gauss()
                t.y += drift.v * T + sqrt(2 * D * T) * rng.gauss()
                let ox = t.x + sigma * rng.gauss(), oy = t.y + sigma * rng.gauss()
                if t.x < 20 || t.x > 380 || t.y < 20 || t.y > 380 {
                    // 🐱 particle left: a new particle (new track) appears elsewhere, no velocity sample this frame
                    nextID += 1
                    t = (nextID, 200 + 100 * (rng.unit() - 0.5), 200 + 100 * (rng.unit() - 0.5), 0, 0)
                    t.ox = t.x + sigma * rng.gauss(); t.oy = t.y + sigma * rng.gauss()
                    tracks[k] = t
                    continue
                }
                var dx = ox - t.ox, dy = oy - t.oy
                if injectMismatches && frame > 120 && rng.unit() < 0.002 { dx += 40; dy -= 25 }   // 🐱 undetected wrong association
                batch.append(VelocitySample(trackID: t.id, frameIndex: frame, x: (ox + t.ox) / 2, y: (oy + t.oy) / 2, t: 0,
                                            dx: dx, dy: dy, dt: T, u: dx / T, v: dy / T))
                t.ox = ox; t.oy = oy
                tracks[k] = t
            }
            stats.add(batch, frameIndex: frame, nominalInterval: T)
        }
        let est = try! #require(stats.diffusion())
        #expect(abs(est.d - D) / D < 0.08)
        #expect(est.significant)
        #expect(abs((est.localizationNoisePx ?? 0) - sigma) < 0.03)
        if injectMismatches { #expect(est.rejectedSteps > 50) }
    }

    @Test func noBrownianMotionIsNotSignificant() {
        var rng = SynthRNG(state: 5)
        let stats = SessionFieldStatistics(grid: GridGeometry(roi: PixelROI(x: 0, y: 0, width: 200, height: 200), cellSize: 100), minSamples: 5)
        var obs = (0..<200).map { _ in (x: 100.0 + rng.gauss(), y: 100.0 + rng.gauss()) }
        for frame in 1...200 {
            var batch: [VelocitySample] = []
            for id in obs.indices {
                // 🐱 static particles seen with 0.05 px noise only
                let nx = 100.0 + 0.05 * rng.gauss() + Double(id % 10), ny = 100.0 + 0.05 * rng.gauss()
                let dx = nx - obs[id].x, dy = ny - obs[id].y
                if frame > 1 {
                    batch.append(VelocitySample(trackID: id, frameIndex: frame, x: nx, y: ny, t: 0, dx: dx, dy: dy, dt: 1.0 / 30, u: dx * 30, v: dy * 30))
                }
                obs[id] = (nx, ny)
            }
            stats.add(batch, frameIndex: frame, nominalInterval: 1.0 / 30)
        }
        let est = try! #require(stats.diffusion())
        #expect(!est.significant || est.d < 0.01)
    }

    @Test func reservoirPercentiles() {
        var r = Reservoir(capacity: 1000, seed: 3)
        for v in 0..<100_000 { r.add(Double(v)) }
        #expect(r.values.count == 1000 && r.seen == 100_000)
        #expect(abs(r.percentile(0.5)! - 50_000) < 5_000)
    }
}

struct SynthRNG {
    var state: UInt64
    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double {
        let a = max(unit(), 1e-12), b = unit()
        return sqrt(-2 * log(a)) * cos(2 * .pi * b)
    }
}
