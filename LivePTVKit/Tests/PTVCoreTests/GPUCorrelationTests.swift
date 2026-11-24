import Foundation
import Testing
@testable import PTVCore

/// 🐱 The GPU (Metal) pass must give the same field as the CPU pass: same statuses, vectors to 1e-4 px, uncertainty
/// 🐱 to 0.1 %. Skipped on machines without a usable GPU (the engine then always runs on the CPU).
@Suite(.enabled(if: MetalCorrelator.shared != nil, "no Metal GPU that passes the self-check"))
struct GPUCorrelationTests {
    /// 🐱 Odd-sized ROI, solid-body rotation plus drift, a flat patch (windows below the contrast threshold) and a
    /// 🐱 masked block (windows with status `masked`).
    private func scene() -> (a: PIVImage, b: PIVImage, engine: (PIVParameters) -> PIVEngine) {
        let (w, h) = (347, 263)
        var rng = Synth(state: 11)
        let flat = { (x: Double, y: Double) in x > 230 && x < 320 && y > 20 && y < 110 }
        let p = (0..<Int(Double(w * h) / 90)).map { _ in (rng.unit() * Double(w + 40) - 20, rng.unit() * Double(h + 40) - 20) }
            .filter { !flat($0.0, $0.1) }
        let omega = 0.025
        let moved = p.map { q -> (Double, Double) in
            let x = q.0 - 170, y = q.1 - 130
            return (170 + x * cos(omega) - y * sin(omega) + 1.3, 130 + x * sin(omega) + y * cos(omega) - 0.6)
        }
        func render(_ pts: [(Double, Double)], _ seed: UInt64) -> LumaImage {
            var r = Synth(state: seed)
            let inside = pts.filter { $0.0 >= 0 && $0.1 >= 0 && $0.0 <= Double(w - 1) && $0.1 <= Double(h - 1) }
            return Synth.render(inside, w: w, h: h, sigma: 1.0, peak: 160, background: 10, noise: 2, rng: &r)
        }
        var mask = [Float](repeating: 1, count: w * h)
        for y in 150..<230 { for x in 20..<110 { mask[y * w + x] = 0 } }
        let prep = PIVEngine()
        return (prep.prepare(render(p, 12), mask: mask), prep.prepare(render(moved, 13), mask: mask),
                { PIVEngine(parameters: $0) })
    }

    private func compare(_ parameters: PIVParameters, expectDevice: String) throws {
        let s = scene()
        var cpuP = parameters; cpuP.useGPU = false
        var gpuP = parameters; gpuP.useGPU = true
        let cpuEngine = s.engine(cpuP), gpuEngine = s.engine(gpuP)
        let c = try #require(cpuEngine.compute(a: s.a, b: s.b, dt: 1))
        let g = try #require(gpuEngine.compute(a: s.a, b: s.b, dt: 1))
        #expect(cpuEngine.lastDevice == "CPU")
        #expect(gpuEngine.lastDevice.hasPrefix(expectDevice), "\(gpuEngine.lastDevice)")
        #expect(c.count == g.count && c.columns == g.columns)
        // 🐱 the scene exercises every status
        #expect(c.validCount > c.count / 2 && c.maskedCount > 0 && c.status.contains(.invalid))
        var statusMismatch = 0, maxD = 0.0, maxC: Float = 0, maxSigmaRel: Float = 0
        for k in 0..<c.count {
            if c.status[k] != g.status[k] { statusMismatch += 1; continue }
            guard c.isMeasured(k) || c.status[k] == .invalid else { continue }
            maxD = max(maxD, abs(c.dx[k] - g.dx[k]), abs(c.dy[k] - g.dy[k]))
            maxC = max(maxC, abs(c.correlation[k] - g.correlation[k]))
        }
        #expect(c.sigmaX.count == g.sigmaX.count)
        for k in 0..<min(c.sigmaX.count, g.sigmaX.count) {
            for (u, v) in [(c.sigmaX[k], g.sigmaX[k]), (c.sigmaY[k], g.sigmaY[k])] {
                #expect((u > 0) == (v > 0))
                if u > 0 { maxSigmaRel = max(maxSigmaRel, abs(u - v) / u) }
            }
        }
        print(String(format: "GPU vs CPU (%@): status mismatches %d of %d, max |Δd| %.2e px, max |Δcorr| %.2e, max σ rel %.2e",
                     gpuEngine.lastDevice, statusMismatch, c.count, maxD, maxC, maxSigmaRel))
        #expect(statusMismatch == 0)
        #expect(maxD < 1e-4)
        #expect(maxC < 1e-4)
        #expect(maxSigmaRel < 1e-3)
        if let dc = c.particleImageDiameterPx, let dg = g.particleImageDiameterPx { #expect(abs(dc - dg) < 1e-3 * dc) }
        #expect((c.particleImageDiameterPx == nil) == (g.particleImageDiameterPx == nil))
    }

    /// 🐱 Defaults: 64-px predictor pass on the CPU, three 32-px passes on the GPU, each deforming both frames with the
    /// 🐱 previous field (Lanczos-4; the last pass with uncertainty). The deformed frames are bit-identical (start-up
    /// 🐱 self-check); the predictor can differ by ~1e-6 px between the paths, which may move a resampling weight by one
    /// 🐱 table step (1/4096 px) — hence the 1e-4 px tolerance.
    @Test func defaultPassesMatchTheCPU() throws {
        try compare(PIVParameters(), expectDevice: "GPU (")
        #expect(MetalCorrelator.shared.map { PIVEngine.gpuName == $0.deviceName } == true)
    }

    /// 🐱 Window shift instead of deformation (≤ 0.7 behaviour): Lanczos-shifted windows on the GPU.
    @Test func shiftedWindowsMatchTheCPU() throws {
        var p = PIVParameters()
        p.deformation = false
        try compare(p, expectDevice: "GPU (")
    }

    /// 🐱 32-px only: the first pass has no predictor (integer windows: plain copy), then bilinear shifts.
    @Test func integerAndBilinearWindowsMatchTheCPU() throws {
        var p = PIVParameters()
        p.windowSizes = [32]
        p.windowInterpolation = .bilinear
        p.deformation = false
        try compare(p, expectDevice: "GPU (")
        p.deformation = true                // 🐱 bilinear deformation
        try compare(p, expectDevice: "GPU (")
    }

    /// 🐱 Other window sizes stay on the CPU.
    @Test func otherWindowSizesRunOnTheCPU() throws {
        var p = PIVParameters()
        p.windowSizes = [64]
        let s = scene()
        let e = PIVEngine(parameters: p)
        _ = try #require(e.compute(a: s.a, b: s.b, dt: 1))
        #expect(e.lastDevice == "CPU")
    }
}
