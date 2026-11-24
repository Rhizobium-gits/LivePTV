import Accelerate
import Foundation
import Testing
@testable import PTVCore

/// 🐱 Why the final passes shift windows with an 8-tap windowed sinc: an asymmetric interpolation kernel (bilinear,
/// 🐱 Keys bicubic) skews the correlation peak of aligned windows, a systematic error that iterating cannot remove.
@Suite struct WindowShiftInterpolationTests {
    @Test func lanczosRemovesTheInterpolationBias() {
        let (w, h) = (220, 220)
        let n = 32
        let setup = vDSP_create_fftsetup(5, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var worst: [String: Double] = [:]
        for sigma in [0.8, 1.2] {
            for s in [0.13, 0.37, 0.5, 0.71] {
                var rng = Synth(state: 3)
                let pts: [(Double, Double)] = (0..<1200).map { _ in (rng.unit() * 220, rng.unit() * 220) }
                var r1 = Synth(state: 11), r2 = Synth(state: 12)
                let a = Synth.render(pts, w: w, h: h, sigma: sigma, peak: 110, background: 20, noise: 0, rng: &r1)
                let b = Synth.render(pts.map { (min(219, $0.0 + s), $0.1) }, w: w, h: h, sigma: sigma, peak: 110, background: 20, noise: 0, rng: &r2)
                for (label, k) in [("bilinear", CorrelationWork.SubpixelKernel?.none), ("lanczos4", .lanczos4)] {
                    var se = 0.0, count = 0.0
                    for wy in stride(from: 20, to: 170, by: 16) {
                        for wx in stride(from: 20, to: 170, by: 16) {
                            var work = CorrelationWork(size: n)
                            a.pixels.withUnsafeBufferPointer { Ap in b.pixels.withUnsafeBufferPointer { Bp in
                                work.fill(Ap.baseAddress!, w, x0: Double(wx) - s / 2, y0: Double(wy), into: true, kernel: k)
                                work.fill(Bp.baseAddress!, w, x0: Double(wx) + s / 2, y0: Double(wy), into: false, kernel: k)
                            } }
                            if let r = work.correlate(setup: setup, minContrast: 0.1) { se += r.dx * r.dx; count += 1 }
                        }
                    }
                    worst[label] = max(worst[label] ?? 0, (se / count).squareRoot())
                }
            }
        }
        print(String(format: "INTERP worst rms residual of aligned windows: bilinear %.4f px, lanczos4 %.4f px", worst["bilinear"]!, worst["lanczos4"]!))
        #expect(worst["bilinear"]! > 0.02)
        #expect(worst["lanczos4"]! < 0.008)
    }
}
