import Foundation
import Testing
@testable import PTVCore

/// 🐱 Per-vector uncertainty (correlation statistics) against the actual error of synthetic image pairs, and the
/// 🐱 particle-image diameter from the correlation-peak width.
@Suite struct UncertaintyTests {
    /// 🐱 Pair with known uniform displacement; `loss`: share of particles replaced in the second frame (out-of-plane).
    private func pair(shift: (Double, Double), sigma: Double, noise: Double, loss: Double, seed: UInt64) -> (LumaImage, LumaImage) {
        let (w, h) = (320, 320)
        // 🐱 the renderer needs points near the image
        func inside(_ q: [(Double, Double)]) -> [(Double, Double)] { q.filter { $0.0 > -2 && $0.1 > -2 && $0.0 < Double(w) + 2 && $0.1 < Double(h) + 2 } }
        var rng = Synth(state: seed)
        let n = Int(0.025 * Double(w * h))
        var pts: [(Double, Double)] = (0..<n).map { _ in (rng.unit() * Double(w + 20) - 10, rng.unit() * Double(h + 20) - 10) }
        var r1 = Synth(state: seed &+ 11)
        let a = Synth.render(inside(pts), w: w, h: h, sigma: sigma, peak: 110, background: 20, noise: noise, rng: &r1)
        pts = pts.map { p in rng.unit() < loss ? (rng.unit() * Double(w + 20) - 10, rng.unit() * Double(h + 20) - 10) : (p.0 + shift.0, p.1 + shift.1) }
        var r2 = Synth(state: seed &+ 12)
        let b = Synth.render(inside(pts), w: w, h: h, sigma: sigma, peak: 110, background: 20, noise: noise, rng: &r2)
        return (a, b)
    }

    /// 🐱 Ratio of the predicted to the actual RMS error over several image pairs (valid vectors only).
    private func calibration(sigma: Double, noise: Double, loss: Double) -> (predicted: Double, actual: Double, n: Int) {
        let shift = (2.37, -1.18)
        var p = PIVParameters()
        p.replaceInvalid = false
        let engine = PIVEngine(parameters: p)
        var se = 0.0, ss = 0.0, n = 0
        for seed in [3, 4, 5] as [UInt64] {
            let (a, b) = pair(shift: shift, sigma: sigma, noise: noise, loss: loss, seed: seed)
            guard let f = engine.compute(a: a, b: b, dt: 1) else { continue }
            for k in 0..<f.count where f.status[k] == .valid && k < f.sigmaX.count {
                let ex = f.dx[k] - shift.0, ey = f.dy[k] - shift.1
                se += ex * ex + ey * ey
                ss += Double(f.sigmaX[k] * f.sigmaX[k] + f.sigmaY[k] * f.sigmaY[k])
                n += 2
            }
        }
        return ((ss / Double(max(1, n))).squareRoot(), (se / Double(max(1, n))).squareRoot(), n / 2)
    }

    /// 🐱 Over image noise, particle size and out-of-plane loss the predicted RMS uncertainty must follow the actual
    /// 🐱 RMS error within a factor 1.5 (the agreement reported for correlation-statistics UQ), and rise with noise.
    @Test func predictedUncertaintyFollowsActualError() {
        var ratios: [Double] = []
        var lastPredicted = 0.0
        for (sigma, noise, loss) in [(0.8, 2.0, 0.0), (0.8, 8.0, 0.0), (0.8, 16.0, 0.0), (1.2, 8.0, 0.0), (0.8, 4.0, 0.25), (1.2, 4.0, 0.25)] {
            let c = calibration(sigma: sigma, noise: noise, loss: loss)
            let ratio = c.predicted / c.actual
            ratios.append(ratio)
            print(String(format: "UQ particle σ %.1f px, noise %4.1f, loss %2.0f %%: predicted %.3f px, actual %.3f px, ratio %.2f (%d vectors)",
                         sigma, noise, loss * 100, c.predicted, c.actual, ratio, c.n))
            #expect(c.n > 200)
            #expect(ratio > 1 / 1.5 && ratio < 1.5)
            if sigma == 0.8 && loss == 0 { #expect(c.predicted > lastPredicted); lastPredicted = c.predicted }
        }
    }

    @Test func particleImageDiameterFromPeakWidth() throws {
        let engine = PIVEngine()
        for sigma in [0.7, 1.0, 1.4] {
            let (a, b) = pair(shift: (1.3, 0.4), sigma: sigma, noise: 2, loss: 0, seed: 9)
            let f = try #require(engine.compute(a: a, b: b, dt: 1))
            let d = try #require(f.particleImageDiameterPx)
            let truth = 4 * sigma      // 🐱 e⁻² diameter of a Gaussian image
            print(String(format: "DIAMETER true %.1f px → estimated %.2f px", truth, d))
            #expect(abs(d - truth) / truth < 0.3)
        }
    }
}
