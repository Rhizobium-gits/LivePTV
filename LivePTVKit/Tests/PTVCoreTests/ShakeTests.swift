import Foundation
import Testing
@testable import PTVCore

@Suite struct ShakeTests {
    /// 🐱 20×15 vectors; left and right 4 columns are static background, the middle moves with u = 2 px per pair.
    private func field(shake: ShakeEstimate, flow: Double = 2) -> PIVField {
        let cols = 20, rows = 15
        var f = PIVField(columns: cols, rows: rows, originX: 16, originY: 16, step: 16, windowSize: 32,
                         dx: .init(repeating: 0, count: cols * rows), dy: .init(repeating: 0, count: cols * rows), dt: 1.0 / 30,
                         status: .init(repeating: .valid, count: cols * rows), correlation: .init(repeating: 0.8, count: cols * rows))
        let cx = 16 + 19 * 16 / 2.0, cy = 16 + 14 * 16 / 2.0
        for k in 0..<f.count {
            let i = k % cols
            let fluid = i >= 4 && i < 16
            let d = shake.displacement(x: f.x(k), y: f.y(k), cx: cx, cy: cy)
            f.dx[k] = (fluid ? flow : 0) + d.0
            f.dy[k] = d.1
        }
        return f
    }

    @Test func learnsBackgroundAndRemovesShake() {
        let comp = ShakeCompensator()
        var p = ShakeParameters()
        var rng = Synth(state: 3)
        // 🐱 vibration (zero-mean) is present from the very first pair, and the uniform flow covers 60 % of the view
        var last: (PIVField, ShakeEstimate, ShakeEstimate)?
        for _ in 0..<40 {
            let truth = ShakeEstimate(tx: rng.gauss() * 0.3, ty: rng.gauss() * 0.3, rotation: rng.gauss() * 0.001, scale: rng.gauss() * 0.0005,
                                      backgroundWindows: 0, residualRMSPx: 0, applied: true, source: "")
            var f = field(shake: truth)
            let est = comp.compensate(&f, pairSpacing: 1, parameters: p)
            last = (f, est, truth)
        }
        let (f, est, truth) = last!
        #expect(est.applied)
        // 🐱 Only the oscillating part is removed (the long-term mean is kept as possible flow), so the correction
        // 🐱 matches the true shake up to the uncertainty of that mean (σ/√n ≈ 0.06 px here), not exactly.
        #expect(abs(est.tx - truth.tx) < 0.2 && abs(est.ty - truth.ty) < 0.2)
        #expect(est.persistentPxPerFrame < 0.2)
        for k in 0..<f.count {
            let fluid = (k % 20) >= 4 && (k % 20) < 16
            #expect(abs(f.dx[k] - (fluid ? 2 : 0)) < 0.35 && abs(f.dy[k]) < 0.35)
        }
    }

    @Test func strongShakeFailsSafe() {
        // 🐱 Shake far larger than the static threshold from the start: the compensator may decline, but must never
        // 🐱 apply a correction that is wrong (e.g. mistaking the uniform flow for background).
        let comp = ShakeCompensator()
        var rng = Synth(state: 9)
        for _ in 0..<60 {
            let truth = ShakeEstimate(tx: rng.gauss() * 2, ty: rng.gauss() * 2, rotation: 0, scale: 0, backgroundWindows: 0, residualRMSPx: 0, applied: true, source: "")
            var f = field(shake: truth)
            let est = comp.compensate(&f, pairSpacing: 1, parameters: ShakeParameters())
            // 🐱 any correction applied must track the real shake (never the 2-px flow)
            if est.applied { #expect(hypot(est.tx - truth.tx, est.ty - truth.ty) < 0.8) }
        }
    }

    @Test func referenceAreaWorksWithoutWarmup() {
        let comp = ShakeCompensator()
        var p = ShakeParameters()
        p.referenceROI = PixelROI(x: 0, y: 0, width: 70, height: 300)   // 🐱 left static band
        var f = field(shake: ShakeEstimate(tx: 1.5, ty: -0.5, rotation: 0, scale: 0, backgroundWindows: 0, residualRMSPx: 0, applied: true, source: ""))
        let est = comp.compensate(&f, pairSpacing: 1, parameters: p)
        #expect(est.applied && est.source == "reference area")
        #expect(abs(f.dx[5] - 2) < 1e-9 && abs(f.dx[0]) < 1e-9)
    }

    @Test func downsampledPIVReportsFullFramePixels() throws {
        let (w, h) = (256, 192)
        var rng = Synth(state: 21)
        let pts = (0..<(w * h / 60)).map { _ in (rng.unit() * Double(w - 1), rng.unit() * Double(h - 1)) }
        var r1 = Synth(state: 1), r2 = Synth(state: 2)
        let a = Synth.render(pts, w: w, h: h, sigma: 1.4, noise: 1, rng: &r1)
        let b = Synth.render(pts.map { ($0.0 + 6.4, $0.1 - 2.2) }.filter { $0.0 < Double(w - 1) && $0.1 >= 0 }, w: w, h: h, sigma: 1.4, noise: 1, rng: &r2)
        let f = try #require(PIVEngine().compute(a: a.downsampled(by: 2), b: b.downsampled(by: 2), dt: 1))
        let good = (0..<f.count).filter { f.status[$0] == .valid }
        let mx = good.map { f.dx[$0] }.reduce(0, +) / Double(good.count), my = good.map { f.dy[$0] }.reduce(0, +) / Double(good.count)
        #expect(abs(mx - 6.4) < 0.15 && abs(my + 2.2) < 0.15)
        #expect(f.step == 32 && f.windowSize == 64)   // 🐱 16 px / 32 px windows at half resolution
    }
}
