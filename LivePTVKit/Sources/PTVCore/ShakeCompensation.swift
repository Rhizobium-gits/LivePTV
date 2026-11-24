import Foundation

/// 🐱 Camera-shake compensation settings.
public struct ShakeParameters: Codable, Equatable, Sendable {
    /// 🐱 How the picture may move between the two frames of a pair. All models are first-order (small motions) and
    /// 🐱 written about the centre of the vector grid; a rotation about any other point, also one outside the frame,
    /// 🐱 is the same rotation about the centre plus a shift.
    public enum Model: String, Codable, CaseIterable, Sendable {
        /// 🐱 Chosen per pair among the models below by the Bayesian information criterion, among those the static
        /// 🐱 background can determine (the spread of the static windows is checked).
        case auto
        /// 🐱 shift only (2 parameters)
        case translation
        /// 🐱 shift + rotation + uniform zoom (4): in-plane rotation about any point, distance changes
        case similarity
        /// 🐱 + shear and unequal stretch (6): rolling-shutter skew, an oblique view
        case affine
        /// 🐱 + keystone (8, linearised homography): the camera tilting on its stand (pitch, yaw)
        case perspective
        /// 🐱 rotation + zoom about one fixed point learned over the session (2): a stand swaying about its base. The
        /// 🐱 point may lie far outside the frame; the model stays well determined with little static background.
        case pivot

        public var title: String {
            switch self {
            case .auto: return "Automatic (chosen per pair)"
            case .translation: return "Shift only"
            case .similarity: return "Shift + rotation + zoom"
            case .affine: return "Affine (adds shear, rolling shutter)"
            case .perspective: return "Perspective (adds keystone, camera tilt)"
            case .pivot: return "Rotation about a fixed point (stand sway)"
            }
        }
    }

    public var enabled = true
    public var model: Model = .auto
    /// 🐱 Windows whose time-averaged displacement (shake removed) stays below this, in px per frame, are static
    /// 🐱 background. Shake is back-and-forth, so a static area averages to ≈0 while a flow keeps its mean velocity.
    public var staticThresholdPxPerFrame = 0.15
    /// 🐱 Frame pairs observed before automatic background detection starts.
    public var warmupPairs = 15
    /// 🐱 Weight of the newest pair in each window's motion history.
    public var historyAlpha = 0.1
    public var minBackgroundWindows = 6
    /// 🐱 Optional user-drawn reference area that is known not to move (wall, ruler); overrides automatic detection.
    public var referenceROI: PixelROI?

    public init() {}
}

/// 🐱 Global image motion between the two frames of a pair (full-frame px over the pair), to first order:
/// 🐱 d(x) = t + L·(x − c) − (x − c)·(k·(x − c)), with c the grid centre, L = [[s + ex, θ + gx], [−θ + gy, s + ey]] and
/// 🐱 k the keystone vector.
public struct ShakeEstimate: Codable, Equatable, Sendable {
    public var tx: Double
    public var ty: Double
    /// 🐱 rad, positive = counter-clockwise on screen
    public var rotation: Double
    /// 🐱 relative scale change (0 = none)
    public var scale: Double
    public var backgroundWindows: Int
    public var residualRMSPx: Double
    public var applied: Bool
    public var source: String
    /// 🐱 Persistent (non-oscillating) part of the fitted background motion that was NOT removed, px per frame.
    /// 🐱 Large values mean slow camera drift or flow mistaken for background.
    public var persistentPxPerFrame: Double = 0
    /// 🐱 Affine part beyond rotation and zoom: unequal stretch along x and y, and shear (x displacement per y,
    /// 🐱 y displacement per x), px/px.
    public var stretchX = 0.0
    public var stretchY = 0.0
    public var shearX = 0.0
    public var shearY = 0.0
    /// 🐱 Keystone (linearised perspective), 1/px.
    public var keystoneX = 0.0
    public var keystoneY = 0.0
    /// 🐱 Model fitted for this pair ("translation", "similarity", "affine", "perspective", "pivot"; "" when none).
    public var model = ""
    /// 🐱 The point the in-plane motion of this pair turned about (full-frame px, may lie outside the frame); nil when
    /// 🐱 the rotation was too small to locate it.
    public var pivotX: Double? = nil
    public var pivotY: Double? = nil

    public static let none = ShakeEstimate(tx: 0, ty: 0, rotation: 0, scale: 0, backgroundWindows: 0, residualRMSPx: 0, applied: false, source: "none")

    public var magnitudePx: Double { hypot(tx, ty) }

    /// 🐱 Displacement the camera motion causes at an image point, relative to the centre (cx, cy).
    public func displacement(x: Double, y: Double, cx: Double, cy: Double) -> (Double, Double) {
        // 🐱 image y is down: a counter-clockwise rotation on screen moves +x points to −y
        let px = x - cx, py = y - cy
        let q = keystoneX * px + keystoneY * py
        return (tx + (scale + stretchX) * px + (rotation + shearX) * py - px * q,
                ty + (-rotation + shearY) * px + (scale + stretchY) * py - py * q)
    }

    /// 🐱 All parameters as one vector (for averaging, accumulating and subtracting motions; to first order, the motion
    /// 🐱 over several pairs is the sum of their vectors).
    public var vector: [Double] { [tx, ty, scale, rotation, stretchX, stretchY, shearX, shearY, keystoneX, keystoneY] }

    /// 🐱 A motion from a parameter vector (see `vector`).
    public init(vector v: [Double]) {
        self.init(tx: v[0], ty: v[1], rotation: v[3], scale: v[2], backgroundWindows: 0, residualRMSPx: 0, applied: true, source: "")
        stretchX = v[4]; stretchY = v[5]; shearX = v[6]; shearY = v[7]; keystoneX = v[8]; keystoneY = v[9]
    }

    public init(tx: Double, ty: Double, rotation: Double, scale: Double, backgroundWindows: Int, residualRMSPx: Double,
                applied: Bool, source: String) {
        self.tx = tx; self.ty = ty; self.rotation = rotation; self.scale = scale
        self.backgroundWindows = backgroundWindows; self.residualRMSPx = residualRMSPx; self.applied = applied; self.source = source
    }

    mutating func subtract(_ v: [Double]) {
        tx -= v[0]; ty -= v[1]; scale -= v[2]; rotation -= v[3]
        stretchX -= v[4]; stretchY -= v[5]; shearX -= v[6]; shearY -= v[7]; keystoneX -= v[8]; keystoneY -= v[9]
    }
}

/// 🐱 A point the camera motion turns about, learned over the session.
public struct ShakePivot: Codable, Equatable, Sendable {
    /// 🐱 full-frame px (may lie outside the frame)
    public var x: Double
    public var y: Double
    /// 🐱 Share of the fitted shifts that rotation and zoom about this point explain (1 = all).
    public var rSquared: Double
    /// 🐱 Pairs it was learned from.
    public var pairs: Int
    /// 🐱 RMS rotation per pair, rad.
    public var rotationRMS: Double
}

/// 🐱 Removes camera shake from PIV fields: background windows (static in the recent past, or inside a reference
/// 🐱 area) give the global motion of each pair; it is fitted robustly and subtracted from every vector.
public final class ShakeCompensator {
    /// 🐱 Per window: mean and variance of the signed displacement per frame (equal weights while learning, then EMA).
    private var histX: [Double] = []
    private var histY: [Double] = []
    private var varX: [Double] = []
    private var varY: [Double] = []
    private var histCount: [Int] = []
    /// 🐱 Long-term mean of the fitted camera motion per frame (all parameters): only deviations from it (the
    /// 🐱 oscillating shake) are removed, so persistent flow can never be subtracted as "camera motion".
    private var meanMotion = [Double](repeating: 0, count: 10)
    private var motionCount = 0
    private var gridKey: GridGeometry?
    private var pairs = 0
    public private(set) var center = (x: 0.0, y: 0.0)
    /// 🐱 Sums for the session pivot q: Σ(s² + θ²), Σ Mᵀt and Σ|t|² over pairs, with M = [[s, θ], [−θ, s]]; the
    /// 🐱 shift a rotation + zoom about q causes at the centre is t = −M(q − c), so q = c − ΣMᵀt / Σ(s² + θ²).
    private var pivotSums = (m: 0.0, mtx: 0.0, mty: 0.0, tt: 0.0, n: 0)
    /// 🐱 Models used so far (counts), for the evaluation.
    public private(set) var modelCounts: [String: Int] = [:]

    public init() {}

    public func reset() {
        histX = []
        histY = []
        varX = []
        varY = []
        histCount = []
        meanMotion = [Double](repeating: 0, count: 10)
        motionCount = 0
        gridKey = nil
        pairs = 0
        pivotSums = (0, 0, 0, 0, 0)
        modelCounts = [:]
    }

    /// 🐱 The session's pivot, once rotation has been seen often and strongly enough and rotation + zoom about one
    /// 🐱 point explain at least 80 % of the fitted shifts (else nil: the camera also shifts on its own).
    public var pivot: ShakePivot? {
        let s = pivotSums
        guard s.n >= 10, s.m > 0, s.tt > 0 else { return nil }
        let half = max(1, hypot(center.x, center.y))
        // 🐱 the rotation must move the frame's corners by ≥ 0.05 px RMS, or the point cannot be located
        guard (s.m / Double(s.n)).squareRoot() * half >= 0.05 else { return nil }
        let qx = center.x - s.mtx / s.m, qy = center.y - s.mty / s.m
        let dqx = qx - center.x, dqy = qy - center.y
        // 🐱 Σ|t + M(q − c)|² = Σ|t|² + 2(q − c)·ΣMᵀt + Σ(s² + θ²)|q − c|²
        let resid = s.tt + 2 * (dqx * s.mtx + dqy * s.mty) + s.m * (dqx * dqx + dqy * dqy)
        let r2 = 1 - max(0, resid) / s.tt
        guard r2 >= 0.8 else { return nil }
        return ShakePivot(x: qx, y: qy, rSquared: r2, pairs: s.n, rotationRMS: (s.m / Double(s.n)).squareRoot())
    }

    /// 🐱 `pairSpacing` normalises displacements to per-frame values for the static test. `remeasure` (optional): the
    /// 🐱 background windows' displacements measured again on the raw frames (when the analysed frames had a temporal
    /// 🐱 background removed, which also removes the static texture the camera-motion fit relies on).
    @discardableResult
    public func compensate(_ f: inout PIVField, pairSpacing k: Int, parameters p: ShakeParameters,
                           remeasure: (([Int]) -> [Int: (dx: Double, dy: Double)])? = nil) -> ShakeEstimate {
        let grid = f.cellGrid
        if gridKey != grid {
            reset()
            gridKey = grid
            histX = [Double](repeating: 0, count: f.count)
            histY = [Double](repeating: 0, count: f.count)
            varX = histX
            varY = histY
            histCount = [Int](repeating: 0, count: f.count)
            center = (f.originX + Double(f.columns - 1) * f.step / 2, f.originY + Double(f.rows - 1) * f.step / 2)
        }
        defer { pairs += 1 }
        let perFrame = 1 / Double(max(1, k))
        guard p.enabled else {
            updateHistory(f, perFrame: perFrame, parameters: p)
            return .none
        }

        // 🐱 background windows
        var background: [Int] = []
        var source = "automatic"
        if let ref = p.referenceROI {
            background = (0..<f.count).filter { f.status[$0] == .valid && ref.contains(x: f.x($0), y: f.y($0)) }
            source = "reference area"
        } else if pairs >= p.warmupPairs {
            background = (0..<f.count).filter { f.status[$0] == .valid && isStatic($0, p) }
        }
        guard background.count >= max(3, p.minBackgroundWindows) else {
            // 🐱 Fail safe: without enough recognisably static background nothing is corrected (and it is reported).
            updateHistory(f, perFrame: perFrame, parameters: p)
            var e = ShakeEstimate.none
            e.backgroundWindows = background.count
            e.source = pairs < p.warmupPairs && p.referenceROI == nil ? "learning background" : "too little static background"
            return e
        }

        // 🐱 the fit uses raw-frame measurements of the background windows when available
        var g = f
        var remeasured: [Int: (dx: Double, dy: Double)] = [:]
        if let remeasure {
            let m = remeasure(background)
            if m.count >= max(3, p.minBackgroundWindows) {
                for (k, d) in m { g.dx[k] = d.dx; g.dy[k] = d.dy }
                background = background.filter { m[$0] != nil }
                remeasured = m
            }
        }
        let learnedPivot = pivot
        // 🐱 1. a first robust pass with a simple model removes gross outliers (windows that were not really static)
        var est = fit(g, background, model: Self.determinable(.similarity, g, background) ? .similarity : .translation, pivot: nil)
        background = keepInliers(g, background, est)
        // 🐱 2. the model: the requested one if the background determines it (else the richest simpler one that it
        // 🐱 does), or in automatic mode the one with the lowest BIC
        est = choose(g, background, requested: p.model, pivot: learnedPivot)
        // 🐱 3. reject again with the chosen model and refit
        let kept = keepInliers(g, background, est)
        if kept.count >= max(3, p.minBackgroundWindows), kept.count < background.count {
            background = kept
            est = fit(g, background, model: ShakeParameters.Model(rawValue: est.model) ?? .similarity, pivot: learnedPivot)
        }
        let residuals = background.map { residual(g, $0, est) }
        est.backgroundWindows = background.count
        est.residualRMSPx = sqrt(residuals.map { $0 * $0 }.reduce(0, +) / Double(max(1, residuals.count)))
        est.applied = true
        est.source = source
        modelCounts[est.model, default: 0] += 1
        learnPivot(est)
        est.pivotX = nil; est.pivotY = nil
        let m2 = est.scale * est.scale + est.rotation * est.rotation
        if m2 > 0, m2.squareRoot() * max(1, hypot(center.x, center.y)) >= 0.05 {
            // 🐱 where rotation + zoom of this pair alone leave a point in place: c − M⁻¹t
            let s = est.scale, th = est.rotation
            est.pivotX = center.x - (s * est.tx - th * est.ty) / m2
            est.pivotY = center.y - (th * est.tx + s * est.ty) / m2
        }

        // 🐱 Remove only the oscillating part: subtract the long-term mean motion (per frame × pair spacing).
        // 🐱 With a reference area the user vouches that it is static, so its whole motion is camera motion.
        var keptMean: ShakeEstimate?
        if p.referenceROI == nil {
            let kk = Double(max(1, k))
            let w = motionCount < 20 ? 1 / Double(motionCount + 1) : 0.05
            let v = est.vector
            for i in 0..<10 { meanMotion[i] += w * (v[i] / kk - meanMotion[i]) }
            motionCount += 1
            est.subtract(meanMotion.map { $0 * kk })
            keptMean = ShakeEstimate(vector: meanMotion.map { $0 * kk })
            est.persistentPxPerFrame = hypot(meanMotion[0], meanMotion[1]) + abs(meanMotion[3]) * hypot(center.x, center.y) / 2
        }

        // 🐱 static windows keep their raw-frame measurement (after background subtraction they hold only residue)
        for (k, d) in remeasured { f.dx[k] = d.dx; f.dy[k] = d.dy }
        for k in 0..<f.count where f.isMeasured(k) {
            let d = est.displacement(x: f.x(k), y: f.y(k), cx: center.x, cy: center.y)
            f.dx[k] -= d.0
            f.dy[k] -= d.1
        }
        // 🐱 The static test learns from the field with the WHOLE camera motion removed. The vectors keep the long-term
        // 🐱 mean (it might be flow), but static windows then show that mean as a small, steady offset with little
        // 🐱 scatter, and one by one fail "zero within 3 standard errors" (seen after ~60 pairs with 0.02-px noise).
        if let m = keptMean {
            var h = f
            for k in 0..<h.count where h.isMeasured(k) {
                let d = m.displacement(x: h.x(k), y: h.y(k), cx: center.x, cy: center.y)
                h.dx[k] -= d.0
                h.dy[k] -= d.1
            }
            updateHistory(h, perFrame: perFrame, parameters: p)
        } else {
            updateHistory(f, perFrame: perFrame, parameters: p)
        }
        return est
    }

    private func residual(_ f: PIVField, _ k: Int, _ e: ShakeEstimate) -> Double {
        let d = e.displacement(x: f.x(k), y: f.y(k), cx: center.x, cy: center.y)
        return hypot(f.dx[k] - d.0, f.dy[k] - d.1)
    }

    /// 🐱 Windows within 3 robust σ (+0.05 px) of the fit.
    private func keepInliers(_ f: PIVField, _ idx: [Int], _ e: ShakeEstimate) -> [Int] {
        let r = idx.map { residual(f, $0, e) }
        let med = median(r)
        let keep = zip(idx, r).filter { $0.1 <= 3 * 1.4826 * med + 0.05 }.map(\.0)
        return keep.count >= 3 ? keep : idx
    }

    private func learnPivot(_ e: ShakeEstimate) {
        guard e.model != "translation", e.model != "pivot" else { return }
        let s = e.scale, th = e.rotation
        // 🐱 Mᵀt with M = [[s, θ], [−θ, s]]
        pivotSums.m += s * s + th * th
        pivotSums.mtx += s * e.tx - th * e.ty
        pivotSums.mty += th * e.tx + s * e.ty
        pivotSums.tt += e.tx * e.tx + e.ty * e.ty
        pivotSums.n += 1
    }

    // 🐱 MARK: fitting

    /// 🐱 Number of parameters of a model.
    static func parameterCount(_ m: ShakeParameters.Model) -> Int {
        switch m {
        case .translation: return 2
        case .pivot: return 2
        case .similarity: return 4
        case .affine: return 6
        case .perspective: return 8
        case .auto: return 0
        }
    }

    /// 🐱 Basis functions of a model at a point relative to the centre (px, py), each giving (dx, dy), in coordinates
    /// 🐱 scaled by `l` (≈ half the grid diagonal) so the columns are comparable.
    static func basis(_ m: ShakeParameters.Model, px: Double, py: Double, l: Double, pivot: (dx: Double, dy: Double)?) -> [(Double, Double)] {
        let u = px / l, v = py / l
        switch m {
        case .translation:
            return [(1, 0), (0, 1)]
        case .similarity:
            return [(1, 0), (0, 1), (u, v), (v, -u)]
        case .affine:
            return [(1, 0), (0, 1), (u, 0), (v, 0), (0, u), (0, v)]
        case .perspective:
            return [(1, 0), (0, 1), (u, 0), (v, 0), (0, u), (0, v), (-u * u, -u * v), (-u * v, -v * v)]
        case .pivot:
            let q = pivot ?? (0, 0)
            let a = u - q.dx / l, b = v - q.dy / l
            return [(b, -a), (a, b)]        // 🐱 rotation and zoom about the pivot
        case .auto:
            return []
        }
    }

    /// 🐱 Whether the windows determine the model: the smallest eigenvalue of the column-normalised normal matrix
    /// 🐱 (1 = orthogonal columns, 0 = degenerate) is at least 0.02, and there are ≥ 2 observations per parameter.
    static func determinable(_ m: ShakeParameters.Model, _ f: PIVField, _ idx: [Int], center: (x: Double, y: Double)? = nil,
                             pivot: (dx: Double, dy: Double)? = nil) -> Bool {
        let k = parameterCount(m)
        guard k > 0, 2 * idx.count >= 2 * k + 2 else { return false }
        if m == .translation { return true }
        let c = center ?? centroid(f, idx)
        let l = scaleLength(f)
        var n = [Double](repeating: 0, count: k * k)
        for i in idx {
            let b = basis(m, px: f.x(i) - c.x, py: f.y(i) - c.y, l: l, pivot: pivot)
            for r in 0..<k { for s in 0..<k { n[r * k + s] += b[r].0 * b[s].0 + b[r].1 * b[s].1 } }
        }
        let d = (0..<k).map { max(1e-300, n[$0 * k + $0]).squareRoot() }
        for r in 0..<k { for s in 0..<k { n[r * k + s] /= d[r] * d[s] } }
        return smallestEigenvalue(n, k) >= 0.02
    }

    private static func centroid(_ f: PIVField, _ idx: [Int]) -> (x: Double, y: Double) {
        let n = Double(max(1, idx.count))
        return (idx.map { f.x($0) }.reduce(0, +) / n, idx.map { f.y($0) }.reduce(0, +) / n)
    }

    private static func scaleLength(_ f: PIVField) -> Double {
        max(1, hypot(Double(f.columns - 1) * f.step, Double(f.rows - 1) * f.step) / 2)
    }

    private static func determinable(_ m: ShakeParameters.Model, _ f: PIVField, _ idx: [Int]) -> Bool {
        determinable(m, f, idx, center: nil, pivot: nil)
    }

    /// 🐱 The requested model, or (automatic) the determinable model with the lowest BIC; a requested model the
    /// 🐱 background cannot determine falls back to the richest simpler one it can.
    private func choose(_ f: PIVField, _ idx: [Int], requested: ShakeParameters.Model, pivot pv: ShakePivot?) -> ShakeEstimate {
        let q = pv.map { (dx: $0.x - center.x, dy: $0.y - center.y) }
        let ladder: [ShakeParameters.Model] = [.translation, .similarity, .affine, .perspective]
        func ok(_ m: ShakeParameters.Model) -> Bool {
            m == .pivot ? (q != nil && Self.determinable(.pivot, f, idx, center: center, pivot: q)) : Self.determinable(m, f, idx, center: center, pivot: nil)
        }
        if requested != .auto {
            if ok(requested) { return fit(f, idx, model: requested, pivot: pv) }
            // 🐱 fall back to the richest simpler model the background determines (pivot not learned yet: similarity)
            let simpler: [ShakeParameters.Model] = requested == .pivot ? [.similarity]
                : Array(ladder[0..<(ladder.firstIndex(of: requested) ?? 0)].reversed())
            for m in simpler where ok(m) { return fit(f, idx, model: m, pivot: pv) }
            return fit(f, idx, model: .translation, pivot: pv)
        }
        var best: (bic: Double, e: ShakeEstimate)?
        let nObs = Double(2 * idx.count)
        let candidates: [ShakeParameters.Model] = q != nil ? ladder + [.pivot] : ladder
        for m in candidates where ok(m) {
            let e = fit(f, idx, model: m, pivot: pv)
            var rss = 0.0
            for i in idx { let r = residual(f, i, e); rss += r * r }
            // 🐱 0.01-px floor: below it the fit is as good as the measurement anyway
            let bic = nObs * log(rss / nObs + 1e-4) + Double(Self.parameterCount(m)) * log(nObs)
            if best == nil || bic < best!.bic { best = (bic, e) }
        }
        return best?.e ?? fit(f, idx, model: .translation, pivot: pv)
    }

    /// 🐱 Least squares of the model over the windows (normal equations, k ≤ 8).
    private func fit(_ f: PIVField, _ idx: [Int], model: ShakeParameters.Model, pivot pv: ShakePivot?) -> ShakeEstimate {
        var e = ShakeEstimate(tx: 0, ty: 0, rotation: 0, scale: 0, backgroundWindows: idx.count, residualRMSPx: 0, applied: true, source: "")
        let m: ShakeParameters.Model = model == .pivot && pv == nil ? .similarity : model
        e.model = m.rawValue
        let k = Self.parameterCount(m)
        let l = Self.scaleLength(f)
        let q = pv.map { (dx: $0.x - center.x, dy: $0.y - center.y) }
        var n = [Double](repeating: 0, count: k * k), r = [Double](repeating: 0, count: k)
        for i in idx {
            let b = Self.basis(m, px: f.x(i) - center.x, py: f.y(i) - center.y, l: l, pivot: q)
            for a in 0..<k {
                r[a] += b[a].0 * f.dx[i] + b[a].1 * f.dy[i]
                for c in 0..<k { n[a * k + c] += b[a].0 * b[c].0 + b[a].1 * b[c].1 }
            }
        }
        guard let beta = Self.solve(n, r, k) else { return e }
        switch m {
        case .translation:
            e.tx = beta[0]; e.ty = beta[1]
        case .similarity:
            e.tx = beta[0]; e.ty = beta[1]; e.scale = beta[2] / l; e.rotation = beta[3] / l
        case .affine, .perspective:
            e.tx = beta[0]; e.ty = beta[1]
            let a11 = beta[2] / l, a12 = beta[3] / l, a21 = beta[4] / l, a22 = beta[5] / l
            e.scale = (a11 + a22) / 2; e.rotation = (a12 - a21) / 2
            e.stretchX = a11 - e.scale; e.stretchY = a22 - e.scale
            e.shearX = a12 - e.rotation; e.shearY = a21 + e.rotation
            if m == .perspective { e.keystoneX = beta[6] / (l * l); e.keystoneY = beta[7] / (l * l) }
        case .pivot:
            // 🐱 rotation θ and zoom s about q: d = θ·(b, −a) + s·(a, b) with (a, b) = x − q; as t + L(x − c):
            let th = beta[0] / l, s = beta[1] / l, qx = q?.dx ?? 0, qy = q?.dy ?? 0
            e.rotation = th; e.scale = s
            e.tx = -th * qy - s * qx
            e.ty = th * qx - s * qy
        case .auto:
            break
        }
        return e
    }

    /// 🐱 Solves the symmetric system n·x = r (Gaussian elimination with partial pivoting); nil if singular.
    static func solve(_ n: [Double], _ r: [Double], _ k: Int) -> [Double]? {
        var a = n, b = r
        for c in 0..<k {
            var p = c
            for i in (c + 1)..<max(c + 1, k) where abs(a[i * k + c]) > abs(a[p * k + c]) { p = i }
            guard abs(a[p * k + c]) > 1e-300 else { return nil }
            if p != c {
                for j in 0..<k { a.swapAt(c * k + j, p * k + j) }
                b.swapAt(c, p)
            }
            for i in 0..<k where i != c {
                let f = a[i * k + c] / a[c * k + c]
                if f == 0 { continue }
                for j in c..<k { a[i * k + j] -= f * a[c * k + j] }
                b[i] -= f * b[c]
            }
        }
        return (0..<k).map { b[$0] / a[$0 * k + $0] }
    }

    /// 🐱 Smallest eigenvalue of a symmetric k × k matrix (cyclic Jacobi rotations).
    static func smallestEigenvalue(_ m: [Double], _ k: Int) -> Double {
        var a = m
        for _ in 0..<60 {
            var off = 0.0
            for p in 0..<k { for q in (p + 1)..<max(p + 1, k) { off += a[p * k + q] * a[p * k + q] } }
            if off < 1e-22 { break }
            for p in 0..<k {
                for q in (p + 1)..<max(p + 1, k) where abs(a[p * k + q]) > 1e-300 {
                    let theta = (a[q * k + q] - a[p * k + p]) / (2 * a[p * k + q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for i in 0..<k {
                        let aip = a[i * k + p], aiq = a[i * k + q]
                        a[i * k + p] = c * aip - s * aiq
                        a[i * k + q] = s * aip + c * aiq
                    }
                    for i in 0..<k {
                        let api = a[p * k + i], aqi = a[q * k + i]
                        a[p * k + i] = c * api - s * aqi
                        a[q * k + i] = s * api + c * aqi
                    }
                }
            }
        }
        return (0..<k).map { a[$0 * k + $0] }.min() ?? 0
    }

    private func updateHistory(_ f: PIVField, perFrame: Double, parameters p: ShakeParameters) {
        for k in 0..<f.count where f.status[k] == .valid {
            // 🐱 equal-weight running mean/variance while few samples (fastest averaging of zero-mean shake), then EMA
            let n = histCount[k]
            let w = n < p.warmupPairs ? 1 / Double(n + 1) : p.historyAlpha
            let ex = f.dx[k] * perFrame - histX[k], ey = f.dy[k] * perFrame - histY[k]
            histX[k] += w * ex
            histY[k] += w * ey
            varX[k] = (1 - w) * (varX[k] + w * ex * ex)
            varY[k] = (1 - w) * (varY[k] + w * ey * ey)
            histCount[k] = n + 1
        }
    }

    /// 🐱 Static = the window's mean motion is zero within 3 standard errors (plus a small floor), and below the cap.
    /// 🐱 A slow but steady flow has a mean that is many standard errors from zero, so it is not "background".
    private func isStatic(_ k: Int, _ p: ShakeParameters) -> Bool {
        let n = histCount[k]
        guard n >= 3 else { return false }
        let neff = n < p.warmupPairs ? Double(n) : (2 - p.historyAlpha) / p.historyAlpha
        let seX = sqrt(varX[k] / neff), seY = sqrt(varY[k] / neff)
        let floor = 0.003
        return abs(histX[k]) < 3 * seX + floor && abs(histY[k]) < 3 * seY + floor
            && hypot(histX[k], histY[k]) < p.staticThresholdPxPerFrame
    }
}
