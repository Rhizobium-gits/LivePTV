import Foundation

/// 🐱 Regular grid over the ROI, in full-frame pixels (x right, y down).
public struct GridGeometry: Codable, Equatable, Sendable {
    public var originX: Double
    public var originY: Double
    public var cellSize: Double
    public var columns: Int
    public var rows: Int

    public init(roi: PixelROI, cellSize: Double) {
        originX = Double(roi.x)
        originY = Double(roi.y)
        self.cellSize = max(1, cellSize)
        columns = max(1, Int(ceil(Double(roi.width) / self.cellSize)))
        rows = max(1, Int(ceil(Double(roi.height) / self.cellSize)))
    }

    public init(originX: Double, originY: Double, cellSize: Double, columns: Int, rows: Int) {
        self.originX = originX
        self.originY = originY
        self.cellSize = cellSize
        self.columns = columns
        self.rows = rows
    }

    public var count: Int { columns * rows }

    public func index(x: Double, y: Double) -> Int? {
        let i = Int(floor((x - originX) / cellSize)), j = Int(floor((y - originY) / cellSize))
        guard i >= 0, j >= 0, i < columns, j < rows else { return nil }
        return j * columns + i
    }

    public func center(_ k: Int) -> (x: Double, y: Double) {
        (originX + (Double(k % columns) + 0.5) * cellSize, originY + (Double(k / columns) + 0.5) * cellSize)
    }
}

/// 🐱 Velocity-gradient quantities on a grid, by central differences (one-sided next to gaps), in 1/s.
/// 🐱 Vorticity uses the usual y-up convention: positive = counter-clockwise as seen on screen.
public enum FieldDerivatives {
    public static func compute(columns: Int, rows: Int, spacing h: Double, u: [Double?], v: [Double?]) -> (vorticity: [Double?], divergence: [Double?]) {
        func at(_ a: [Double?], _ i: Int, _ j: Int) -> Double? {
            (i >= 0 && j >= 0 && i < columns && j < rows) ? a[j * columns + i] : nil
        }
        func derivative(_ a: [Double?], _ i: Int, _ j: Int, _ di: Int, _ dj: Int) -> Double? {
            let p = at(a, i + di, j + dj), m = at(a, i - di, j - dj), c = at(a, i, j)
            if let p, let m { return (p - m) / (2 * h) }
            if let p, let c { return (p - c) / h }
            if let c, let m { return (c - m) / h }
            return nil
        }
        var vort = [Double?](repeating: nil, count: columns * rows)
        var div = vort
        for j in 0..<rows {
            for i in 0..<columns {
                let k = j * columns + i
                guard u[k] != nil, v[k] != nil else { continue }
                // 🐱 image y points down: ω(y-up) = ∂u/∂y − ∂v/∂x in image coordinates; divergence is unchanged.
                if let dudy = derivative(u, i, j, 0, 1), let dvdx = derivative(v, i, j, 1, 0) { vort[k] = dudy - dvdx }
                if let dudx = derivative(u, i, j, 1, 0), let dvdy = derivative(v, i, j, 0, 1) { div[k] = dudx + dvdy }
            }
        }
        return (vort, div)
    }
}

extension FieldSnapshot {
    /// 🐱 Vorticity and divergence of the valid cells of a live field snapshot.
    public func derivatives() -> (vorticity: [Double?], divergence: [Double?]) {
        let u = cells.map { $0.valid ? Optional($0.u) : nil }
        let v = cells.map { $0.valid ? Optional($0.v) : nil }
        return FieldDerivatives.compute(columns: columns, rows: rows, spacing: cellSize, u: u, v: v)
    }
}

/// 🐱 Fixed-size uniform random sample of a stream (for medians / percentiles / histograms of long sessions).
public struct Reservoir: Sendable {
    public let capacity: Int
    public private(set) var values: [Double] = []
    public private(set) var seen = 0
    private var state: UInt64

    public init(capacity: Int, seed: UInt64) {
        self.capacity = capacity
        state = seed | 1
    }

    public mutating func add(_ v: Double) {
        guard v.isFinite else { return }
        seen += 1
        if values.count < capacity { values.append(v); return }
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        let r = Int(state % UInt64(seen))
        if r < capacity { values[r] = v }
    }

    public func percentile(_ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))]
    }
}

/// 🐱 Time-averaged statistics of one grid cell over a whole measurement.
public struct CellStatistics: Codable, Equatable, Sendable {
    public var i: Int
    public var j: Int
    public var x: Double
    public var y: Double
    public var count: Int
    /// 🐱 px/s
    public var meanU: Double
    public var meanV: Double
    public var stdU: Double
    public var stdV: Double
    /// 🐱 ⟨u′v′⟩, px²/s²
    public var covUV: Double
    /// 🐱 Mean of the sample speeds (≥ speed of the mean velocity when there are fluctuations).
    public var meanSpeed: Double
    public var standardErrorU: Double
    public var standardErrorV: Double
    /// 🐱 |standard error of the mean velocity| / |mean velocity|; nil when the mean is ~0.
    public var relativeUncertainty: Double?
    /// 🐱 1/s, positive = counter-clockwise on screen
    public var vorticity: Double?
    /// 🐱 1/s
    public var divergence: Double?
    public var valid: Bool
    /// 🐱 RMS random measurement uncertainty of one sample, per component (px/s), from the per-vector estimates
    /// 🐱 (PIV correlation statistics). Nil when not estimated.
    public var measurementUncertainty: Double? = nil

    public var speedOfMean: Double { hypot(meanU, meanV) }
    /// 🐱 RMS velocity fluctuation per component, px/s
    public var fluctuationRMS: Double { sqrt((stdU * stdU + stdV * stdV) / 2) }
    /// 🐱 Fluctuation with the measurement noise removed: √max(0, rms² − σ²); nil without an uncertainty estimate.
    public var noiseCorrectedFluctuationRMS: Double? {
        guard let s = measurementUncertainty else { return nil }
        return sqrt(max(0, fluctuationRMS * fluctuationRMS - s * s))
    }
    public var turbulenceIntensity: Double? { speedOfMean > 1e-9 ? fluctuationRMS / speedOfMean : nil }
}

/// 🐱 Brownian diffusion from the variance of drift-corrected displacements at lags of one and two frames:
/// 🐱 var(lag k) = 2·D·k·Δt + 2σ²  ⇒  D = (var₂ − var₁)/(2Δt),  σ² = (2·var₁ − var₂)/2   (σ = localisation noise).
/// 🐱 Drift is removed per grid cell, so a steady flow does not inflate D; velocity gradients within a cell do.
public struct DiffusionEstimate: Codable, Equatable, Sendable {
    public var frameInterval: Double
    public var pairsLag1: Int
    public var pairsLag2: Int
    /// 🐱 px²/s
    public var dx: Double
    public var dy: Double
    public var d: Double
    public var standardError: Double
    /// 🐱 px; nil when the estimate came out negative (noise variance not resolvable)
    public var localizationNoisePx: Double?
    /// 🐱 Steps discarded as gross mismatches (drift-corrected residual > 6 robust σ).
    /// 🐱 Note: samples flagged by the tracker's median test are NOT excluded here. That test assumes a spatially coherent
    /// 🐱 flow and flags genuine large Brownian steps, which would bias D low (observed: −15 % at 12 % flagged).
    public var rejectedSteps: Int
    /// 🐱 RMS one-frame Brownian step per axis, px
    public var brownianStepPx: Double { sqrt(max(0, 2 * d * frameInterval)) }
    public var significant: Bool { d > 0 && d > 2 * standardError }
}

/// 🐱 Accumulates every velocity sample of a measurement on a fixed grid. Memory is O(cells + live tracks).
public final class SessionFieldStatistics {
    public let grid: GridGeometry
    public let minSamples: Int
    public private(set) var samples = 0
    public private(set) var outliers = 0
    public private(set) var outsideGrid = 0
    public private(set) var speeds = Reservoir(capacity: 200_000, seed: 0x5EED)
    public private(set) var displacements = Reservoir(capacity: 100_000, seed: 0xD15C)

    private var n: [Int]
    private var su: [Double], sv: [Double], suu: [Double], svv: [Double], suv: [Double], sspeed: [Double]
    /// 🐱 Σ (σ/dt)² and count of samples with an uncertainty estimate
    private var ssig: [Double], nsig: [Int]
    // 🐱 diffusion: per-cell sums of displacements and squares at lag 1 and lag 2 (single-interval steps only)
    private var c1: [Int], s1x: [Double], s1y: [Double], q1x: [Double], q1y: [Double]
    private var c2: [Int], s2x: [Double], s2y: [Double], q2x: [Double], q2y: [Double]
    private var dtSum = 0.0
    private var dtCount = 0
    private var previousStep: [Int: (dx: Double, dy: Double, frame: Int)] = [:]
    private var lastPrune = 0
    // 🐱 Robust guard against undetected mismatches: one wrong association can inflate a variance enormously.
    private var residuals = Reservoir(capacity: 20_000, seed: 0xA5A5)
    private var residualScale: Double?
    private var lastScaleUpdate = 0
    public private(set) var rejectedSteps = 0

    public init(grid: GridGeometry, minSamples: Int) {
        self.grid = grid
        self.minSamples = max(2, minSamples)
        let z = [Double](repeating: 0, count: grid.count)
        let zi = [Int](repeating: 0, count: grid.count)
        n = zi; su = z; sv = z; suu = z; svv = z; suv = z; sspeed = z
        ssig = z; nsig = zi
        c1 = zi; s1x = z; s1y = z; q1x = z; q1y = z
        c2 = zi; s2x = z; s2y = z; q2x = z; q2y = z
    }

    /// 🐱 `nominalInterval`: the camera frame interval; only single-interval steps (±15 %) enter the diffusion estimate.
    public func add(_ batch: [VelocitySample], frameIndex: Int, nominalInterval: Double?, includeDiffusion: Bool = true) {
        for s in batch {
            let cell = grid.index(x: s.x, y: s.y)
            // 🐱 Mean-field statistics: flagged samples excluded.
            if s.outlier {
                outliers += 1
            } else {
                samples += 1
                speeds.add(hypot(s.u, s.v))
                displacements.add(hypot(s.dx, s.dy))
                if let k = cell {
                    n[k] += 1
                    su[k] += s.u; sv[k] += s.v
                    suu[k] += s.u * s.u; svv[k] += s.v * s.v; suv[k] += s.u * s.v
                    sspeed[k] += hypot(s.u, s.v)
                    if let sg = s.sigma, s.dt > 0 {
                        let sv = sg / s.dt
                        ssig[k] += sv * sv
                        nsig[k] += 1
                    }
                }
            }
            // 🐱 Diffusion statistics: every single-interval step, with its own robust mismatch guard.
            // 🐱 (Not for PIV: window displacements average many particles and carry no Brownian information.)
            guard includeDiffusion else { continue }
            guard let k = cell else {
                outsideGrid += 1
                previousStep.removeValue(forKey: s.trackID)
                continue
            }

            guard let T = nominalInterval, T > 0, abs(s.dt - T) <= 0.15 * T else {
                previousStep.removeValue(forKey: s.trackID)
                continue
            }
            if c1[k] >= 10 {
                let rx = s.dx - s1x[k] / Double(c1[k]), ry = s.dy - s1y[k] / Double(c1[k])
                if let scale = residualScale, max(abs(rx), abs(ry)) > 6 * scale {
                    rejectedSteps += 1
                    previousStep.removeValue(forKey: s.trackID)
                    continue
                }
                residuals.add(abs(rx))
                residuals.add(abs(ry))
            }
            c1[k] += 1
            s1x[k] += s.dx; s1y[k] += s.dy
            q1x[k] += s.dx * s.dx; q1y[k] += s.dy * s.dy
            dtSum += s.dt
            dtCount += 1
            if let prev = previousStep[s.trackID], s.frameIndex - prev.frame == 1,
               let k2 = grid.index(x: s.x - s.dx / 2, y: s.y - s.dy / 2) {
                let ex = prev.dx + s.dx, ey = prev.dy + s.dy
                c2[k2] += 1
                s2x[k2] += ex; s2y[k2] += ey
                q2x[k2] += ex * ex; q2y[k2] += ey * ey
            }
            previousStep[s.trackID] = (s.dx, s.dy, s.frameIndex)
        }
        if frameIndex - lastScaleUpdate >= 100, residuals.values.count >= 200, let med = residuals.percentile(0.5) {
            residualScale = max(1e-6, 1.4826 * med)
            lastScaleUpdate = frameIndex
        }
        if frameIndex - lastPrune >= 200 {
            previousStep = previousStep.filter { frameIndex - $0.value.frame <= 2 }
            lastPrune = frameIndex
        }
    }

    public func cells() -> [CellStatistics] {
        var out: [CellStatistics] = []
        out.reserveCapacity(grid.count)
        for k in 0..<grid.count {
            let c = n[k]
            let center = grid.center(k)
            var cell = CellStatistics(i: k % grid.columns, j: k / grid.columns, x: center.x, y: center.y, count: c,
                                      meanU: 0, meanV: 0, stdU: 0, stdV: 0, covUV: 0, meanSpeed: 0,
                                      standardErrorU: 0, standardErrorV: 0, relativeUncertainty: nil,
                                      vorticity: nil, divergence: nil, valid: c >= minSamples)
            if c > 0 {
                let dn = Double(c)
                cell.meanU = su[k] / dn
                cell.meanV = sv[k] / dn
                cell.meanSpeed = sspeed[k] / dn
                if c > 1 {
                    let varU = max(0, (suu[k] - dn * cell.meanU * cell.meanU) / (dn - 1))
                    let varV = max(0, (svv[k] - dn * cell.meanV * cell.meanV) / (dn - 1))
                    cell.stdU = sqrt(varU)
                    cell.stdV = sqrt(varV)
                    cell.covUV = (suv[k] - dn * cell.meanU * cell.meanV) / (dn - 1)
                    cell.standardErrorU = cell.stdU / sqrt(dn)
                    cell.standardErrorV = cell.stdV / sqrt(dn)
                    let se = hypot(cell.standardErrorU, cell.standardErrorV)
                    cell.relativeUncertainty = cell.speedOfMean > 1e-9 ? se / cell.speedOfMean : nil
                }
                if nsig[k] > 0 { cell.measurementUncertainty = sqrt(ssig[k] / Double(nsig[k])) }
            }
            out.append(cell)
        }
        let u = out.map { $0.valid ? Optional($0.meanU) : nil }
        let v = out.map { $0.valid ? Optional($0.meanV) : nil }
        let d = FieldDerivatives.compute(columns: grid.columns, rows: grid.rows, spacing: grid.cellSize, u: u, v: v)
        for k in out.indices {
            out[k].vorticity = d.vorticity[k]
            out[k].divergence = d.divergence[k]
        }
        return out
    }

    /// 🐱 Nil until both lags have at least `minimumPairs` drift-corrected displacements.
    public func diffusion(minimumPairs: Int = 50) -> DiffusionEstimate? {
        func pooled(_ c: [Int], _ s: [Double], _ q: [Double]) -> (variance: Double, dof: Int) {
            var num = 0.0, dof = 0
            for k in c.indices where c[k] >= 2 {
                num += q[k] - s[k] * s[k] / Double(c[k])
                dof += c[k] - 1
            }
            return dof > 0 ? (num / Double(dof), dof) : (.nan, 0)
        }
        let v1x = pooled(c1, s1x, q1x), v1y = pooled(c1, s1y, q1y)
        let v2x = pooled(c2, s2x, q2x), v2y = pooled(c2, s2y, q2y)
        guard dtCount > 0, v1x.dof >= minimumPairs, v2x.dof >= minimumPairs else { return nil }
        let T = dtSum / Double(dtCount)
        let dx = (v2x.variance - v1x.variance) / (2 * T)
        let dy = (v2y.variance - v1y.variance) / (2 * T)
        // 🐱 Standard error of a sample variance ≈ var·√(2/dof); the two lags are treated as independent (conservative).
        func se(_ a: (variance: Double, dof: Int), _ b: (variance: Double, dof: Int)) -> Double {
            sqrt(pow(a.variance * sqrt(2 / Double(a.dof)), 2) + pow(b.variance * sqrt(2 / Double(b.dof)), 2)) / (2 * T)
        }
        let sigma2 = ((2 * v1x.variance - v2x.variance) + (2 * v1y.variance - v2y.variance)) / 4
        return DiffusionEstimate(frameInterval: T, pairsLag1: v1x.dof, pairsLag2: v2x.dof, dx: dx, dy: dy, d: (dx + dy) / 2,
                                 standardError: hypot(se(v1x, v2x), se(v1y, v2y)) / 2,
                                 localizationNoisePx: sigma2 > 0 ? sqrt(sigma2) : nil, rejectedSteps: rejectedSteps)
    }
}
