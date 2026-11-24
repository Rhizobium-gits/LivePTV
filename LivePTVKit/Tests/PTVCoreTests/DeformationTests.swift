import Foundation
import Testing
@testable import PTVCore

/// 🐱 Image deformation, vector positions and edge vectors (LivePTV 0.8). Synthetic pairs are placed symmetrically
/// 🐱 about their midpoints p (frame A at p − d(p)/2, frame B at p + d(p)/2), so the true displacement at any point x is
/// 🐱 d(x) for the symmetric (central-difference) scheme. Numbers quoted were measured with these tests.
@Suite struct DeformationTests {
    static func pair(w: Int, h: Int, seed: UInt64, density: Double = 0.04,
                     _ field: (Double, Double) -> (Double, Double)) -> (LumaImage, LumaImage) {
        var rng = Synth(state: seed)
        var a: [(Double, Double)] = [], b: [(Double, Double)] = []
        let n = Int(Double((w + 40) * (h + 40)) * density)
        func inside(_ p: (Double, Double)) -> Bool { p.0 >= 0 && p.1 >= 0 && p.0 <= Double(w - 1) && p.1 <= Double(h - 1) }
        for _ in 0..<n {
            let x = rng.unit() * Double(w + 40) - 20, y = rng.unit() * Double(h + 40) - 20
            let d = field(x, y)
            let pa = (x - d.0 / 2, y - d.1 / 2), pb = (x + d.0 / 2, y + d.1 / 2)
            if inside(pa) { a.append(pa) }
            if inside(pb) { b.append(pb) }
        }
        var ra = Synth(state: seed &+ 1), rb = Synth(state: seed &+ 2)
        return (Synth.render(a, w: w, h: h, sigma: 0.65, peak: 160, background: 10, noise: 2, rng: &ra),
                Synth.render(b, w: w, h: h, sigma: 0.65, peak: 160, background: 10, noise: 2, rng: &rb))
    }

    static func lambOseen(xc: Double, yc: Double, rc: Double, umax: Double) -> (Double, Double) -> (Double, Double) {
        let rmax = 1.1209 * rc
        let gamma = 2 * Double.pi * rmax * umax / (1 - exp(-(rmax / rc) * (rmax / rc)))
        return { x, y in
            let dx = x - xc, dy = y - yc, r2 = dx * dx + dy * dy + 1e-12
            let s = gamma / (2 * Double.pi * r2) * (1 - exp(-r2 / (rc * rc)))
            return (-s * dy, s * dx)
        }
    }

    /// 🐱 RMS error per component of the measured (valid or replaced) vectors at least `margin` px inside the image.
    static func rms(_ f: PIVField, w: Int, h: Int, margin: Double = 32, _ field: (Double, Double) -> (Double, Double)) -> Double {
        var se = 0.0, n = 0
        for k in 0..<f.count where f.isMeasured(k) {
            let x = f.x(k), y = f.y(k)
            guard x >= margin, y >= margin, x <= Double(w - 1) - margin, y <= Double(h - 1) - margin else { continue }
            let t = field(x, y)
            se += pow(f.dx[k] - t.0, 2) + pow(f.dy[k] - t.1, 2); n += 1
        }
        return (se / Double(max(1, 2 * n))).squareRoot()
    }

    static func params(deformation: Bool) -> PIVParameters {
        var p = PIVParameters()
        p.deformation = deformation
        return p
    }

    /// 🐱 A vector is reported at the centre of its window. LivePTV ≤ 0.7 reported x0 + w/2 for a window covering
    /// 🐱 x0 … x0 + w − 1 (centre x0 + (w − 1)/2): every vector sat 0.5 px off, a bias of 0.5 px × gradient.
    @Test func vectorsAreReportedAtTheirWindowCentres() throws {
        let (w, h) = (384, 384), g = 0.05
        let shear: (Double, Double) -> (Double, Double) = { _, y in (g * (y - 191.5), 0) }
        let (a, b) = Self.pair(w: w, h: h, seed: 31, shear)
        for deformation in [false, true] {
            let f = try #require(PIVEngine(parameters: Self.params(deformation: deformation)).compute(a: a, b: b, dt: 1))
            var sum = 0.0, n = 0
            for k in 0..<f.count where f.status[k] == .valid {
                let y = f.y(k)
                guard y > 60, y < 320, f.x(k) > 40, f.x(k) < 340 else { continue }
                sum += f.dx[k] - g * (y - 191.5); n += 1
            }
            let offset = -(sum / Double(n)) / g    // 🐱 how far the vectors sit from where they were measured
            print(String(format: "CENTRE deformation %@: apparent position offset %+.3f px", deformation ? "on" : "off", offset))
            #expect(abs(offset) < 0.15)
        }
    }

    /// 🐱 Edge vectors in a shear flow. Before 0.8 they were measured 3–5 px further in and reported at the edge, and the
    /// 🐱 normalised median test, whose 3 × 3 neighbours lie on one side there, flagged 58–71 % of a correct edge row
    /// 🐱 (it then sat ≈12 px away after replacement).
    @Test func edgeVectorsAreMeasuredWhereReportedAndKept() throws {
        let (w, h) = (384, 320), g = 0.05
        let shear: (Double, Double) -> (Double, Double) = { _, y in (g * (y - 159.5), 0) }
        let (a, b) = Self.pair(w: w, h: h, seed: 32, shear)
        for deformation in [false, true] {
            let f = try #require(PIVEngine(parameters: Self.params(deformation: deformation)).compute(a: a, b: b, dt: 1))
            for row in [0, f.rows - 1] {
                var replaced = 0, n = 0, sum = 0.0
                for i in 2..<(f.columns - 2) {
                    let k = row * f.columns + i
                    n += 1
                    if f.status[k] == .replaced { replaced += 1 }
                    if f.isMeasured(k) { sum += f.dx[k] - g * (f.y(k) - 159.5) }
                }
                let offset = -(sum / Double(n)) / g
                print(String(format: "EDGE deformation %@, row %d: %d of %d replaced, position offset %+.2f px",
                             deformation ? "on" : "off", row, replaced, n, offset))
                #expect(Double(replaced) < 0.1 * Double(n))
                #expect(abs(offset) < 1.5)
            }
        }
    }

    /// 🐱 Amplitude of dy = sin(2πx/λ + φ) recovered on the vector grid (least squares on sin, cos and 1).
    static func modulation(_ f: PIVField, lambda: Double, phase: Double, w: Int, h: Int) -> Double {
        var m = [[Double]](repeating: [0, 0, 0, 0], count: 3)
        for k in 0..<f.count where f.isMeasured(k) {
            let x = f.x(k), y = f.y(k)
            guard x >= 32, y >= 32, x <= Double(w - 33), y <= Double(h - 33) else { continue }
            let t = 2 * Double.pi * x / lambda
            let row = [sin(t), cos(t), 1.0]
            for r in 0..<3 { for c in 0..<3 { m[r][c] += row[r] * row[c] }; m[r][3] += row[r] * f.dy[k] }
        }
        // 🐱 Gauss–Jordan on the 3 × 3 normal equations
        for c in 0..<3 {
            let p = (c..<3).max { abs(m[$0][c]) < abs(m[$1][c]) }!
            m.swapAt(c, p)
            for r in 0..<3 where r != c {
                let q = m[r][c] / m[c][c]
                for k in c..<4 { m[r][k] -= q * m[c][k] }
            }
        }
        let s = m[0][3] / m[0][0], co = m[1][3] / m[1][1]
        // 🐱 project onto the true phase: negative = phase reversal
        return s * cos(phase) + co * sin(phase)
    }

    /// 🐱 Window shift (≤ 0.7) has about the response of a top-hat average over the window, sinc(w/λ) = 0.64 at λ = 2w.
    /// 🐱 Deformation recovers most of the amplitude without overshooting at long wavelengths (bilinear interpolation
    /// 🐱 of the predictor overshot by 3 % at λ = 5w, which the cubic interpolant removed).
    @Test func deformationResolvesStructuresSmallerThanTheShiftDid() throws {
        let (w, h) = (640, 192)
        var results: [String] = []
        for (lambda, phase) in [(64.0, 0.7), (160.0, 2.1)] {
            let field: (Double, Double) -> (Double, Double) = { x, _ in (0, sin(2 * Double.pi * x / lambda + phase)) }
            let (a, b) = Self.pair(w: w, h: h, seed: 33, density: 0.05, field)
            var mods: [Double] = []
            for deformation in [false, true] {
                var p = Self.params(deformation: deformation)
                p.validationThreshold = 1e9     // 🐱 the response of the correlation itself
                let f = try #require(PIVEngine(parameters: p).compute(a: a, b: b, dt: 1))
                mods.append(Self.modulation(f, lambda: lambda, phase: phase, w: w, h: h))
            }
            results.append(String(format: "λ %.0f: shift %.3f, deformation %.3f", lambda, mods[0], mods[1]))
            if lambda == 64 {
                #expect(mods[0] > 0.55 && mods[0] < 0.78)     // 🐱 near the top-hat value sinc(0.5) = 0.637 (measured 0.72)
                #expect(mods[1] > 0.8 && mods[1] > mods[0] + 0.08)
            } else {
                #expect(mods[1] > 0.95 && mods[1] < 1.025)
            }
        }
        print("RESOLUTION " + results.joined(separator: " | "))
    }

    /// 🐱 Lamb–Oseen vortex, core radius 30 px, 4 px peak displacement. Measured: shift 0.104 px, deformation 0.026 px.
    @Test func deformationFollowsAStrongVortex() throws {
        let (w, h) = (384, 384)
        let v = Self.lambOseen(xc: 191.5, yc: 191.5, rc: 30, umax: 4)
        let (a, b) = Self.pair(w: w, h: h, seed: 34, v)
        let shift = Self.rms(try #require(PIVEngine(parameters: Self.params(deformation: false)).compute(a: a, b: b, dt: 1)), w: w, h: h, v)
        let deform = Self.rms(try #require(PIVEngine(parameters: Self.params(deformation: true)).compute(a: a, b: b, dt: 1)), w: w, h: h, v)
        print(String(format: "VORTEX rms: shift %.4f px, deformation %.4f px", shift, deform))
        #expect(deform < 0.5 * shift)
        #expect(deform < 0.05)
    }

    /// 🐱 The price of deformation: in uniform flow the predictor's noise partly propagates (the centre value is
    /// 🐱 added to a residual measured over the window). Measured: shift 0.0058 px, deformation 0.0066 px.
    @Test func uniformFlowCostsLittle() throws {
        let (w, h) = (384, 384)
        let u: (Double, Double) -> (Double, Double) = { _, _ in (2.37, -1.62) }
        let (a, b) = Self.pair(w: w, h: h, seed: 35, u)
        let shift = Self.rms(try #require(PIVEngine(parameters: Self.params(deformation: false)).compute(a: a, b: b, dt: 1)), w: w, h: h, u)
        let deform = Self.rms(try #require(PIVEngine(parameters: Self.params(deformation: true)).compute(a: a, b: b, dt: 1)), w: w, h: h, u)
        print(String(format: "UNIFORM rms: shift %.4f px, deformation %.4f px", shift, deform))
        #expect(deform < 1.4 * shift + 0.001)
        #expect(deform < 0.012)
    }

    /// 🐱 Field with `validShare` valid cells (the rest invalid) and a masked block.
    static func field(validShare: Double) -> PIVField {
        let cols = 12, rows = 10, n = cols * rows
        var rng = Synth(state: 36)
        var status = [PIVField.Status](repeating: .valid, count: n)
        for k in 0..<n where rng.unit() > validShare { status[k] = .invalid }
        for j in 3...5 { for i in 4...7 { status[j * cols + i] = .masked } }
        return PIVField(columns: cols, rows: rows, originX: 15.5, originY: 15.5, step: 16, windowSize: 32,
                        dx: (0..<n).map { k in status[k] == .masked ? 0 : 2 + 0.01 * Double(k % cols) },
                        dy: .init(repeating: -1, count: n), dt: 1, status: status, correlation: .init(repeating: 0.5, count: n))
    }

    /// 🐱 Below half valid vectors a pass does not deform (the field would mostly be filler); above, every cell —
    /// 🐱 masked ones included — gets a value from measured cells before the field is used.
    @Test func deformationNeedsAReliablePredictorAndFillsTheRest() throws {
        #expect(ImageDeformation.predictor(from: Self.field(validShare: 0.3), smoothing: true) == nil)
        let f = try #require(ImageDeformation.predictor(from: Self.field(validShare: 0.9), smoothing: true))
        // 🐱 the masked block was 0: after filling it holds values near its measured neighbours (dx ≈ 2.04 … 2.08)
        for j in 3...5 {
            for i in 4...7 {
                let k = j * f.columns + i
                #expect(f.dx[k] > 1.9 && f.dx[k] < 2.2 && abs(f.dy[k] + 1) < 1e-9)
            }
        }
        // 🐱 a wide hole is filled ring by ring
        var g = Self.field(validShare: 1)
        for k in 0..<g.count where k % g.columns >= 2 { g.status[k] = .masked; g.dx[k] = 0 }
        let filled = ImageDeformation.filledEverywhere(g)
        #expect(filled.dx.allSatisfy { $0 > 1.9 && $0 < 2.1 })
        #expect(filled.status.allSatisfy { $0 == .valid })
    }

    /// 🐱 CPU and GPU deform with the same arithmetic (`MetalCorrelator` checks bit-identical frames at start-up).
    @Test func cpuDeformationIsTheIdentityForAZeroField() {
        var rng = Synth(state: 37)
        let (w, h) = (40, 30)
        let img = (0..<(w * h)).map { _ in Float(255 * rng.unit()) }
        let zero = PIVField(columns: 3, rows: 2, originX: 7.5, originY: 7.5, step: 12, windowSize: 16,
                            dx: .init(repeating: 0, count: 6), dy: .init(repeating: 0, count: 6), dt: 1,
                            status: .init(repeating: .valid, count: 6), correlation: .init(repeating: 1, count: 6))
        for lanczos in [true, false] {
            #expect(ImageDeformation.deform(img, width: w, height: h, field: zero, sign: -0.5, lanczos: lanczos) == img)
        }
    }
}
