import Foundation
import Testing
@testable import PTVCore

/// 🐱 Camera motion beyond shift + rotation about the centre: rotation about a point far outside the frame (a stand
/// 🐱 swaying about its foot), rolling-shutter shear, keystone from a tilting camera; static background on one side
/// 🐱 only; and the automatic model choice not over-fitting.
@Suite struct CameraMotionTests {
    static let cols = 24, rows = 18, step = 16.0, origin = 15.5
    static var center: (x: Double, y: Double) { (origin + Double(cols - 1) * step / 2, origin + Double(rows - 1) * step / 2) }

    enum Layout { case border, leftBand }

    /// 🐱 Static cells: a 3-cell frame around the picture, or the 4 left columns only. The rest moves with u = 2 px.
    static func isStatic(_ i: Int, _ j: Int, _ layout: Layout) -> Bool {
        switch layout {
        case .border: return i < 3 || j < 3 || i >= cols - 3 || j >= rows - 3
        case .leftBand: return i < 4
        }
    }

    static func field(_ truth: ShakeEstimate, layout: Layout, noise: Double, rng: inout Synth) -> PIVField {
        let n = cols * rows
        var f = PIVField(columns: cols, rows: rows, originX: origin, originY: origin, step: step, windowSize: 32,
                         dx: .init(repeating: 0, count: n), dy: .init(repeating: 0, count: n), dt: 1.0 / 30,
                         status: .init(repeating: .valid, count: n), correlation: .init(repeating: 0.8, count: n))
        for k in 0..<n {
            let i = k % cols, j = k / cols
            let d = truth.displacement(x: f.x(k), y: f.y(k), cx: center.x, cy: center.y)
            f.dx[k] = (isStatic(i, j, layout) ? 0 : 2) + d.0 + noise * rng.gauss()
            f.dy[k] = d.1 + noise * rng.gauss()
        }
        return f
    }

    /// 🐱 Rotation θ (and zoom s) about the point q, written about the grid centre.
    static func aboutPoint(theta: Double, zoom s: Double = 0, qx: Double, qy: Double) -> ShakeEstimate {
        let dx = qx - center.x, dy = qy - center.y
        return ShakeEstimate(tx: -theta * dy - s * dx, ty: theta * dx - s * dy, rotation: theta, scale: s,
                             backgroundWindows: 0, residualRMSPx: 0, applied: true, source: "")
    }

    /// 🐱 Largest error left in the moving region after compensation.
    static func flowError(_ f: PIVField, layout: Layout) -> Double {
        var worst = 0.0
        for k in 0..<f.count where !isStatic(k % cols, k / cols, layout) {
            worst = max(worst, hypot(f.dx[k] - 2, f.dy[k]))
        }
        return worst
    }

    /// 🐱 The camera swings about a point 1500 px below the picture's centre (the foot of a stand): the motion is
    /// 🐱 removed, and the point is learned.
    @Test func rotationAboutAPointOutsideTheFrame() throws {
        let comp = ShakeCompensator()
        var rng = Synth(state: 41)
        let qx = Self.center.x, qy = Self.center.y + 1500
        var worst = 0.0
        for pair in 0..<60 {
            let truth = Self.aboutPoint(theta: 0.0005 * rng.gauss(), qx: qx, qy: qy)
            var f = Self.field(truth, layout: .border, noise: 0.02, rng: &rng)
            let est = comp.compensate(&f, pairSpacing: 1, parameters: ShakeParameters())
            if pair >= 40 {
                #expect(est.applied)
                worst = max(worst, Self.flowError(f, layout: .border))
            }
        }
        let pv = try #require(comp.pivot)
        print(String(format: "PIVOT learned (%.0f, %.0f) px, truth (%.0f, %.0f); R² %.3f; worst flow error %.3f px; models %@",
                     pv.x, pv.y, qx, qy, pv.rSquared, worst, comp.modelCounts.description))
        #expect(hypot(pv.x - qx, pv.y - qy) < 0.05 * 1500)
        #expect(pv.rSquared > 0.95)
        // 🐱 the long-term mean motion is kept as possible flow: what is left is mostly the uncertainty of that mean
        #expect(worst < 0.3)
    }

    /// 🐱 Static background on the left only: the affine and perspective models are not determinable there and must
    /// 🐱 not be chosen; rotation about a far point is still removed across the picture.
    @Test func oneSidedBackground() {
        let comp = ShakeCompensator()
        var rng = Synth(state: 42)
        var worst = 0.0
        for pair in 0..<60 {
            let truth = Self.aboutPoint(theta: 0.0004 * rng.gauss(), qx: Self.center.x - 900, qy: Self.center.y + 1200)
            var f = Self.field(truth, layout: .leftBand, noise: 0.02, rng: &rng)
            comp.compensate(&f, pairSpacing: 1, parameters: ShakeParameters())
            if pair >= 40 { worst = max(worst, Self.flowError(f, layout: .leftBand)) }
        }
        print("ONE-SIDED models \(comp.modelCounts), worst flow error \(worst)")
        #expect((comp.modelCounts["affine"] ?? 0) + (comp.modelCounts["perspective"] ?? 0) == 0)
        #expect(worst < 0.35)
    }

    /// 🐱 Rolling-shutter shear and keystone: the automatic model removes them; similarity cannot.
    @Test func shearAndKeystone() {
        func run(_ model: ShakeParameters.Model) -> Double {
            let comp = ShakeCompensator()
            var p = ShakeParameters()
            p.model = model
            var rng = Synth(state: 43)
            var worst = 0.0
            for pair in 0..<60 {
                var truth = ShakeEstimate(tx: 0.3 * rng.gauss(), ty: 0.3 * rng.gauss(), rotation: 0.0005 * rng.gauss(), scale: 0,
                                          backgroundWindows: 0, residualRMSPx: 0, applied: true, source: "")
                truth.shearX = 0.002 * rng.gauss()                   // 🐱 0.36 px across ±180 px of rows
                truth.keystoneX = 1.5e-5 * rng.gauss()               // 🐱 ≈0.3 px at the corners
                truth.keystoneY = 1.5e-5 * rng.gauss()
                var f = Self.field(truth, layout: .border, noise: 0.01, rng: &rng)
                comp.compensate(&f, pairSpacing: 1, parameters: p)
                if pair >= 40 { worst = max(worst, Self.flowError(f, layout: .border)) }
            }
            return worst
        }
        let auto = run(.auto), similarity = run(.similarity), perspective = run(.perspective)
        print(String(format: "SHEAR+KEYSTONE worst flow error: automatic %.3f px, perspective %.3f px, similarity %.3f px", auto, perspective, similarity))
        #expect(auto < 0.3 && perspective < 0.3)
        #expect(similarity > 2.5 * auto)
    }

    /// 🐱 Pure shift with measurement noise: the information criterion keeps to the simple models.
    @Test func automaticChoiceDoesNotOverfit() {
        let comp = ShakeCompensator()
        var rng = Synth(state: 44)
        for _ in 0..<80 {
            let truth = ShakeEstimate(tx: 0.4 * rng.gauss(), ty: 0.4 * rng.gauss(), rotation: 0, scale: 0,
                                      backgroundWindows: 0, residualRMSPx: 0, applied: true, source: "")
            var f = Self.field(truth, layout: .border, noise: 0.05, rng: &rng)
            comp.compensate(&f, pairSpacing: 1, parameters: ShakeParameters())
        }
        let complex = (comp.modelCounts["affine"] ?? 0) + (comp.modelCounts["perspective"] ?? 0)
        let total = comp.modelCounts.values.reduce(0, +)
        print("OVERFIT check: models \(comp.modelCounts)")
        #expect(total > 50)
        #expect(Double(complex) < 0.1 * Double(total))
    }

    /// 🐱 The per-pair pivot of a pure rotation about q is q.
    @Test func pairPivotIsTheRotationCentre() {
        let comp = ShakeCompensator()
        var rng = Synth(state: 45)
        var p = ShakeParameters()
        p.referenceROI = PixelROI(x: 0, y: 0, width: 1000, height: 1000)     // 🐱 everything static: no learning phase
        let qx = -300.0, qy = 900.0
        var f = Self.field(Self.aboutPoint(theta: 0.003, qx: qx, qy: qy), layout: .border, noise: 0, rng: &rng)
        for k in 0..<f.count { f.dx[k] -= Self.isStatic(k % Self.cols, k / Self.cols, .border) ? 0 : 2 }
        let est = comp.compensate(&f, pairSpacing: 1, parameters: p)
        #expect(abs((est.pivotX ?? .nan) - qx) < 1 && abs((est.pivotY ?? .nan) - qy) < 1)
    }

    @Test func eigenvalueAndSolver() {
        let m = [4.0, 1, 0, 1, 3, 0, 0, 0, 0.5]
        #expect(abs(ShakeCompensator.smallestEigenvalue(m, 3) - 0.5) < 1e-9)
        let x = ShakeCompensator.solve([2, 1, 1, 3], [3, 5], 2)!
        #expect(abs(x[0] - 0.8) < 1e-12 && abs(x[1] - 1.4) < 1e-12)
    }
}

