import Foundation
import Testing
@testable import PTVCore

/// 🐱 Realistic, difficult particle images: lighting gradient (vignetting), mixed brightness and sizes (focus),
/// 🐱 haze, sensor noise. Compares PIV pre-processing options on the same image pair.
@Suite struct PIVRobustnessTests {
    private func degraded(shift: (Double, Double), seed: UInt64, minLight: Double = 0.15, noiseStd: Double = 3, density: Int = 45) -> (LumaImage, LumaImage) {
        let (w, h) = (320, 256)
        var rng = Synth(state: seed)
        struct P { var x: Double; var y: Double; var peak: Double; var sigma: Double }
        let ps: [P] = (0..<(w * h / density)).map { _ in
            P(x: rng.unit() * Double(w + 20) - 10, y: rng.unit() * Double(h + 20) - 10,
              peak: 25 * exp(rng.gauss() * 0.8), sigma: 0.8 + rng.unit() * 1.4)
        }
        func render(_ dx: Double, _ dy: Double, _ seedNoise: UInt64) -> LumaImage {
            var noise = Synth(state: seedNoise)
            var img = [Float](repeating: 0, count: w * h)
            for p in ps {
                let x = p.x + dx, y = p.y + dy, r = Int(ceil(3 * p.sigma))
                let x0 = max(0, Int(x) - r), x1 = min(w - 1, Int(x) + r + 1), y0 = max(0, Int(y) - r), y1 = min(h - 1, Int(y) + r + 1)
                guard x0 <= x1, y0 <= y1 else { continue }
                for yy in y0...y1 { for xx in x0...x1 {
                    let ex = Double(xx) - x, ey = Double(yy) - y
                    img[yy * w + xx] += Float(p.peak * exp(-(ex * ex + ey * ey) / (2 * p.sigma * p.sigma)))
                } }
            }
            for y in 0..<h { for x in 0..<w {
                // 🐱 illumination falls from 100 % (right) to 15 % (left); haze adds a smooth glow
                let light = minLight + (1 - minLight) * Double(x) / Double(w)
                let haze = 30 * exp(-pow(Double(x - 200) / 90, 2) - pow(Double(y - 60) / 70, 2))
                let v = Double(img[y * w + x]) * light + 20 + haze + noise.gauss() * noiseStd
                img[y * w + x] = Float(min(255, max(0, v.rounded())))
            } }
            return LumaImage(width: w, height: h, pixels: img)
        }
        return (render(0, 0, seed &+ 1), render(shift.0, shift.1, seed &+ 2))
    }

    private func score(_ p: PIVParameters, _ a: LumaImage, _ b: LumaImage, _ s: (Double, Double)) -> (valid: Double, rms: Double, darkValid: Double) {
        var q = p
        q.replaceInvalid = false
        let f = PIVEngine(parameters: q).compute(a: a, b: b, dt: 1)!
        let ok = (0..<f.count).filter { f.status[$0] == .valid }
        let dark = (0..<f.count).filter { f.x($0) < 100 }
        var se = 0.0
        for k in ok { se += pow(f.dx[k] - s.0, 2) + pow(f.dy[k] - s.1, 2) }
        return (Double(ok.count) / Double(f.count), sqrt(se / Double(max(1, ok.count))),
                Double(dark.filter { f.status[$0] == .valid }.count) / Double(max(1, dark.count)))
    }

    /// 🐱 18 difficult image pairs (3 seeds × lighting / noise / seeding levels). Measured: high-pass only valid
    /// 🐱 91.9 %, rms 0.148 px; normalisation (default) 91.8 %, 0.146 px; normalisation + intensity capping (the
    /// 🐱 earlier default) 90.5 %, 0.171 px. Capping is what hurt; normalisation alone is on par with high-pass.
    @Test func defaultPreprocessingOnDifficultImages() {
        let shift = (2.3, -1.1)
        var valid = [0.0, 0.0, 0.0], rms = [0.0, 0.0, 0.0]
        var n = 0.0
        for seed in [11, 12, 13] as [UInt64] {
            for (light, noise, density) in [(0.15, 3.0, 45), (0.05, 3.0, 45), (0.15, 6.0, 45), (0.05, 6.0, 90), (0.1, 5.0, 120), (0.3, 3.0, 25)] {
                let (a, b) = degraded(shift: shift, seed: seed, minLight: light, noiseStd: noise, density: density)
                var highPass = PIVParameters()
                highPass.normalizationRadius = 0
                var capped = PIVParameters()
                capped.intensityCapping = true
                for (i, p) in [PIVParameters(), highPass, capped].enumerated() {
                    let r = score(p, a, b, shift)
                    valid[i] += r.valid
                    rms[i] += r.rms
                }
                n += 1
            }
        }
        print(String(format: "ROBUST mean valid: default %.1f %%, high-pass only %.1f %%, with capping %.1f %% | mean rms: %.3f, %.3f, %.3f px",
                     100 * valid[0] / n, 100 * valid[1] / n, 100 * valid[2] / n, rms[0] / n, rms[1] / n, rms[2] / n))
        #expect(valid[0] > valid[2] && rms[0] < 0.92 * rms[2])     // 🐱 capping off is clearly better
        #expect(abs(rms[0] - rms[1]) < 0.1 * rms[1] && abs(valid[0] - valid[1]) / n < 0.01)   // 🐱 on par with high-pass
        #expect(rms[0] / n < 0.19)
    }

    /// 🐱 Window-shift interpolation on the same 18 difficult pairs: the 8-tap windowed sinc removes most of the bias
    /// 🐱 that bilinear shifting adds, at the price of somewhat more random error (bilinear's implicit smoothing hides
    /// 🐱 noise). Measured: bilinear rms 0.151 px, bias +0.016 px; Lanczos-4 rms 0.177 px, bias −0.003 px.
    /// 🐱 For time-averaged fields the bias is what remains, so Lanczos-4 is the default.
    @Test func lanczosTradesSomeRandomErrorForMuchLessBias() {
        let shift = (2.3, -1.1)
        var rms = [0.0, 0.0], bias = [0.0, 0.0]
        var n = 0.0
        for seed in [11, 12, 13] as [UInt64] {
            for (light, noise, density) in [(0.15, 3.0, 45), (0.05, 3.0, 45), (0.15, 6.0, 45), (0.05, 6.0, 90), (0.1, 5.0, 120), (0.3, 3.0, 25)] {
                let (a, b) = degraded(shift: shift, seed: seed, minLight: light, noiseStd: noise, density: density)
                for (i, interp) in [PIVParameters.WindowInterpolation.bilinear, .lanczos4].enumerated() {
                    var p = PIVParameters()
                    p.replaceInvalid = false
                    p.windowInterpolation = interp
                    let f = PIVEngine(parameters: p).compute(a: a, b: b, dt: 1)!
                    let ok = (0..<f.count).filter { f.status[$0] == .valid }
                    var se = 0.0, mx = 0.0
                    for k in ok { se += pow(f.dx[k] - shift.0, 2) + pow(f.dy[k] - shift.1, 2); mx += f.dx[k] - shift.0 }
                    rms[i] += sqrt(se / Double(max(1, ok.count)))
                    bias[i] += mx / Double(max(1, ok.count))
                }
                n += 1
            }
        }
        print(String(format: "INTERP difficult images: bilinear rms %.3f bias %+.4f | lanczos4 rms %.3f bias %+.4f", rms[0] / n, bias[0] / n, rms[1] / n, bias[1] / n))
        #expect(abs(bias[1]) < 0.4 * abs(bias[0]))
        #expect(rms[1] < 1.3 * rms[0])
    }
}
