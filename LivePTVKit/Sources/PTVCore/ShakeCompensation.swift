import Foundation

/// 🐱 Camera-shake compensation settings.
public struct ShakeParameters: Codable, Equatable, Sendable {
    public enum Model: String, Codable, CaseIterable, Sendable {
        /// 🐱 shift only
        case translation
        /// 🐱 shift + small rotation + uniform scale (zoom / distance change)
        case similarity
    }

    public var enabled = true
    public var model: Model = .similarity
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

/// 🐱 Global image motion between the two frames of a pair (full-frame px over the pair).
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

    public static let none = ShakeEstimate(tx: 0, ty: 0, rotation: 0, scale: 0, backgroundWindows: 0, residualRMSPx: 0, applied: false, source: "none")

    public var magnitudePx: Double { hypot(tx, ty) }

    /// 🐱 Displacement the camera motion causes at an image point, relative to the centre (cx, cy).
    public func displacement(x: Double, y: Double, cx: Double, cy: Double) -> (Double, Double) {
        // 🐱 image y is down: a counter-clockwise rotation on screen moves +x points to −y
        let px = x - cx, py = y - cy
        return (tx + scale * px + rotation * py, ty + scale * py - rotation * px)
    }
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
    /// 🐱 Long-term mean of the fitted camera motion per frame (tx, ty, rotation, scale): only deviations from it
    /// 🐱 (the oscillating shake) are removed, so persistent flow can never be subtracted as "camera motion".
    private var meanMotion = (tx: 0.0, ty: 0.0, r: 0.0, s: 0.0)
    private var motionCount = 0
    private var gridKey: GridGeometry?
    private var pairs = 0
    public private(set) var center = (x: 0.0, y: 0.0)

    public init() {}

    public func reset() {
        histX = []
        histY = []
        varX = []
        varY = []
        histCount = []
        meanMotion = (0, 0, 0, 0)
        motionCount = 0
        gridKey = nil
        pairs = 0
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
        // 🐱 robust fit: fit, reject residuals > 3 robust σ (+0.05 px), refit
        var est = fit(g, background, model: p.model)
        var residuals = background.map { k -> Double in
            let d = est.displacement(x: g.x(k), y: g.y(k), cx: center.x, cy: center.y)
            return hypot(g.dx[k] - d.0, g.dy[k] - d.1)
        }
        let med = median(residuals)
        let keep = zip(background, residuals).filter { $0.1 <= 3 * 1.4826 * med + 0.05 }.map(\.0)
        if keep.count >= max(3, p.minBackgroundWindows) {
            est = fit(g, keep, model: p.model)
            residuals = keep.map { k -> Double in
                let d = est.displacement(x: g.x(k), y: g.y(k), cx: center.x, cy: center.y)
                return hypot(g.dx[k] - d.0, g.dy[k] - d.1)
            }
            background = keep
        }
        est.backgroundWindows = background.count
        est.residualRMSPx = sqrt(residuals.map { $0 * $0 }.reduce(0, +) / Double(max(1, residuals.count)))
        est.applied = true
        est.source = source

        // 🐱 Remove only the oscillating part: subtract the long-term mean motion (per frame × pair spacing).
        // 🐱 With a reference area the user vouches that it is static, so its whole motion is camera motion.
        if p.referenceROI == nil {
            let kk = Double(max(1, k))
            let w = motionCount < 20 ? 1 / Double(motionCount + 1) : 0.05
            meanMotion.tx += w * (est.tx / kk - meanMotion.tx)
            meanMotion.ty += w * (est.ty / kk - meanMotion.ty)
            meanMotion.r += w * (est.rotation / kk - meanMotion.r)
            meanMotion.s += w * (est.scale / kk - meanMotion.s)
            motionCount += 1
            est.tx -= meanMotion.tx * kk
            est.ty -= meanMotion.ty * kk
            est.rotation -= meanMotion.r * kk
            est.scale -= meanMotion.s * kk
            est.persistentPxPerFrame = hypot(meanMotion.tx, meanMotion.ty) + abs(meanMotion.r) * hypot(center.x, center.y) / 2
        }

        // 🐱 static windows keep their raw-frame measurement (after background subtraction they hold only residue)
        for (k, d) in remeasured { f.dx[k] = d.dx; f.dy[k] = d.dy }
        for k in 0..<f.count where f.isMeasured(k) {
            let d = est.displacement(x: f.x(k), y: f.y(k), cx: center.x, cy: center.y)
            f.dx[k] -= d.0
            f.dy[k] -= d.1
        }
        updateHistory(f, perFrame: perFrame, parameters: p)
        return est
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

    /// 🐱 Least squares for (tx, ty, rotation, scale) — or (tx, ty) — over the given windows.
    private func fit(_ f: PIVField, _ idx: [Int], model: ShakeParameters.Model) -> ShakeEstimate {
        let n = Double(idx.count)
        let mx = idx.map { f.dx[$0] }.reduce(0, +) / n, my = idx.map { f.dy[$0] }.reduce(0, +) / n
        guard model == .similarity else {
            return ShakeEstimate(tx: mx, ty: my, rotation: 0, scale: 0, backgroundWindows: idx.count, residualRMSPx: 0, applied: true, source: "")
        }
        // 🐱 dx = tx + σ·px + θ·py ; dy = ty + σ·py − θ·px  (px, py relative to the fitted points' centroid)
        let ax = idx.map { f.x($0) }.reduce(0, +) / n, ay = idx.map { f.y($0) }.reduce(0, +) / n
        var sxx = 0.0, sdx = 0.0, sdy = 0.0
        for k in idx {
            let px = f.x(k) - ax, py = f.y(k) - ay
            sxx += px * px + py * py
            sdx += (f.dx[k] - mx) * px + (f.dy[k] - my) * py        // 🐱 scale term
            sdy += (f.dx[k] - mx) * py - (f.dy[k] - my) * px        // 🐱 rotation term
        }
        let scale = sxx > 1e-9 ? sdx / sxx : 0
        let rotation = sxx > 1e-9 ? sdy / sxx : 0
        // 🐱 re-express the translation for the fixed compensation centre
        let dcx = ax - center.x, dcy = ay - center.y
        let tx = mx - (scale * dcx + rotation * dcy)
        let ty = my - (scale * dcy - rotation * dcx)
        return ShakeEstimate(tx: tx, ty: ty, rotation: rotation, scale: scale, backgroundWindows: idx.count, residualRMSPx: 0, applied: true, source: "")
    }
}
