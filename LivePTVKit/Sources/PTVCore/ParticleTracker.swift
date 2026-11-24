import Foundation

public struct TrackerParameters: Codable, Equatable, Sendable {
    /// 🐱 Search radius (px) when nothing better is known: the largest displacement expected between frames.
    public var maxDisplacement: Double = 12
    /// 🐱 Search radius (px) around the prediction of an established track that is (nearly) at rest...
    public var predictionRadius: Double = 4
    /// 🐱 ...plus this fraction of its predicted displacement |v|·dt: the prediction error of a fast particle in a
    /// 🐱 curved or accelerating flow grows with its speed.
    public var speedRadiusFactor: Double = 0.1
    /// 🐱 Extrapolate established tracks with their acceleration as well as their velocity, while their last two
    /// 🐱 accelerations agree (smooth curved or accelerating motion; a mismatch or Brownian steps do not qualify).
    public var accelerationPrediction = true
    /// 🐱 New tracks borrow the median velocity of established tracks within this radius (px) as their
    /// 🐱 prediction. This is what keeps nearest-neighbour ambiguity low at realistic seeding densities. Where there are
    /// 🐱 no established tracks (first frames), new tracks vote among themselves for a common local displacement.
    public var neighborPrediction = true
    public var neighborRadius: Double = 40
    /// 🐱 ...using only the nearest this-many of them (nearer neighbours move more alike in a sheared flow).
    public var neighborCount = 8
    /// 🐱 Assignment: minimum total normalised squared prediction residual (|x − x̂|² / r², an unmatched track costs 1)
    /// 🐱 over each connected group of tracks and candidates, solved exactly; groups with more than
    /// 🐱 `maxSubnetworkSize` tracks + particles fall back to closest-first. Off: closest-first everywhere.
    public var globalAssignment = true
    public var maxSubnetworkSize = 2000
    /// 🐱 Frames a track may go unmatched (bridged with its prediction) before it ends.
    public var maxMissedFrames = 1
    /// 🐱 Points kept per track for display tails.
    public var tailLength = 10
    /// 🐱 Lagrangian normalised median test on each frame's samples (neighbours within `neighborRadius`).
    public var outlierThreshold = 3.0
    /// 🐱 Noise floor of that test, as a displacement in px (converted to px/s with each sample's dt).
    public var outlierEpsilonPx = 0.1
    public var outlierMinNeighbors = 4

    public init() {}
}

/// 🐱 One Lagrangian velocity measurement between two consecutive observations of the same particle,
/// 🐱 located at the midpoint in space and time (second-order accurate for smooth trajectories).
public struct VelocitySample: Codable, Equatable, Sendable {
    public var trackID: Int
    public var frameIndex: Int
    public var x: Double
    public var y: Double
    public var t: Double
    public var dx: Double
    public var dy: Double
    public var dt: Double
    /// 🐱 px/s
    public var u: Double
    public var v: Double
    /// 🐱 Rejected by the normalised median test against neighbouring samples (kept, but flagged).
    public var outlier: Bool = false
    /// 🐱 Random measurement uncertainty of the displacement (standard uncertainty per component, px), when the
    /// 🐱 method provides one (PIV correlation statistics). Nil = not estimated.
    public var sigma: Double? = nil
}

public struct Track: Sendable {
    public let id: Int
    public fileprivate(set) var points: [(x: Double, y: Double, t: Double)]
    public fileprivate(set) var length: Int
    public fileprivate(set) var missed: Int
    public fileprivate(set) var velocity: (u: Double, v: Double)?
    /// 🐱 px/s², from the last two velocities, once both came from links predicted by the track's own velocity
    /// 🐱 (the first link of a track is ambiguous, and an acceleration across it would mislead every later prediction).
    public fileprivate(set) var acceleration: (u: Double, v: Double)? = nil
    /// 🐱 Consecutive links made with the track's own velocity as prediction.
    fileprivate var predictedLinks = 0
    /// 🐱 The last two accelerations agree (change < half the latest): smooth motion, not a mismatch or Brownian noise.
    fileprivate var steadyAcceleration = false

    public var last: (x: Double, y: Double, t: Double) { points[points.count - 1] }
}

public struct TrackingStep: Sendable {
    /// 🐱 Track id for each input particle (same order as the detections); 0 = not tracked.
    public var trackIDs: [Int]
    public var samples: [VelocitySample]
    public var started: Int
    public var ended: Int

    public init(trackIDs: [Int], samples: [VelocitySample], started: Int, ended: Int) {
        self.trackIDs = trackIDs
        self.samples = samples
        self.started = started
        self.ended = ended
    }
}

/// 🐱 Frame-to-frame association for particle tracking velocimetry:
/// 🐱  1. prediction: own velocity (and acceleration), else the median velocity of the nearest established
/// 🐱     neighbours, else none;
/// 🐱  2. gated search around the prediction, the gate growing with the predicted displacement;
/// 🐱  3. global assignment: minimum total normalised squared residual per connected group of competing tracks
/// 🐱     and particles (exact shortest-augmenting-path / Jonker–Volgenant), closest-first for oversized groups;
/// 🐱  4. velocity samples from real timestamps (correct across dropped frames);
/// 🐱  5. normalised median test flags samples that disagree with their neighbours.
public final class ParticleTracker {
    public var parameters: TrackerParameters
    public private(set) var tracks: [Track] = []
    private var nextID = 1
    private var lastTime: Double?
    private var solver = AssignmentSolver()

    public init(parameters: TrackerParameters = TrackerParameters()) { self.parameters = parameters }

    public func reset() {
        tracks.removeAll()
        lastTime = nil
    }

    public func update(particles: [Particle], time t: Double, frameIndex: Int) -> TrackingStep {
        let p = parameters
        if let lt = lastTime, t <= lt { reset() }   // 🐱 time did not advance: restart cleanly
        lastTime = t
        let nT = tracks.count, nP = particles.count

        // 🐱 Established tracks (with velocity) on a grid, for neighbour prediction.
        let established = p.neighborPrediction ? tracks.indices.filter { tracks[$0].velocity != nil && tracks[$0].missed == 0 } : []
        let nbGrid = CellGrid(count: established.count, cell: max(1, p.neighborRadius / 2),
                              x: { self.tracks[established[$0]].last.x }, y: { self.tracks[established[$0]].last.y })
        var nb: [(d2: Double, u: Double, v: Double)] = []
        var med: [Double] = []
        func neighborVelocity(_ x: Double, _ y: Double) -> (Double, Double)? {
            guard !established.isEmpty else { return nil }
            nb.removeAll(keepingCapacity: true)
            let r2 = p.neighborRadius * p.neighborRadius
            nbGrid.forEach(near: x, y, radius: p.neighborRadius) { k in
                let tr = tracks[established[k]]
                let l = tr.last
                let d2 = (l.x - x) * (l.x - x) + (l.y - y) * (l.y - y)
                if d2 <= r2, let v = tr.velocity { nb.append((d2, v.u, v.v)) }
            }
            guard nb.count >= 3 else { return nil }
            let k = max(3, p.neighborCount)
            if nb.count > k { nb.sort { $0.d2 < $1.d2 }; nb.removeLast(nb.count - k) }
            med.removeAll(keepingCapacity: true)
            med.append(contentsOf: nb.lazy.map(\.u))
            let mu = medianInPlace(&med)
            med.removeAll(keepingCapacity: true)
            med.append(contentsOf: nb.lazy.map(\.v))
            return (mu, medianInPlace(&med))
        }

        // 🐱 Candidate particles on a grid.
        let cell = max(1.0, min(p.maxDisplacement, 2 * p.predictionRadius))
        let grid = CellGrid(count: nP, cell: cell, x: { particles[$0].x }, y: { particles[$0].y })

        // 🐱 Prediction and gate of every track.
        var predX = [Double](repeating: 0, count: nT), predY = predX, gate = predX
        var unpredicted: [Int] = []
        for (ti, tr) in tracks.enumerated() {
            let last = tr.last
            let dt = t - last.t
            var px = last.x, py = last.y
            let grow = 1 + 0.5 * Double(tr.missed)
            var radius = p.maxDisplacement * Double(1 + tr.missed)
            if let v = tr.velocity {
                px += v.u * dt
                py += v.v * dt
                if p.accelerationPrediction, tr.steadyAcceleration, let a = tr.acceleration, tr.points.count >= 2 {
                    // 🐱 v is the mean velocity over the last interval Δ₁ (centred Δ₁/2 before the last point), so
                    // 🐱 x(t + Δ) = x + vΔ + aΔ(Δ + Δ₁)/2 under constant acceleration.
                    let d1 = last.t - tr.points[tr.points.count - 2].t
                    px += a.u * dt * (dt + d1) / 2
                    py += a.v * dt * (dt + d1) / 2
                }
                radius = (p.predictionRadius + p.speedRadiusFactor * hypot(v.u, v.v) * dt) * grow
            } else if let v = neighborVelocity(last.x, last.y) {
                px += v.0 * dt
                py += v.1 * dt
                radius = min(p.maxDisplacement, 1.5 * p.predictionRadius + p.speedRadiusFactor * hypot(v.0, v.1) * dt) * grow
            } else {
                unpredicted.append(ti)
            }
            predX[ti] = px
            predY[ti] = py
            gate[ti] = radius
        }
        if p.neighborPrediction && unpredicted.count > 1 {
            voteForUnpredicted(unpredicted, particles: particles, grid: grid, predX: &predX, predY: &predY, gate: &gate)
        }

        // 🐱 Candidates of every track with cost |x − x̂|² / r² (≤ 1 inside the gate).
        solver.begin(rows: nT, columns: nP)
        for ti in 0..<nT {
            let px = predX[ti], py = predY[ti], radius = gate[ti]
            let r2 = radius * radius
            if r2 > 0 {
                grid.forEach(near: px, py, radius: radius) { pi in
                    let ex = particles[pi].x - px, ey = particles[pi].y - py
                    let d2 = ex * ex + ey * ey
                    if d2 <= r2 { solver.addEdge(column: pi, cost: d2 / r2) }
                }
            }
            solver.endRow()
        }
        let match = p.globalAssignment ? solver.solve(missCost: 1, maxGroupSize: p.maxSubnetworkSize) : solver.solveGreedy()

        var trackUsed = [Bool](repeating: false, count: nT)
        var ids = [Int](repeating: 0, count: nP)
        var samples: [VelocitySample] = []
        samples.reserveCapacity(min(nT, nP))
        let keep = max(2, p.tailLength)
        for ti in 0..<nT {
            let pi = match[ti]
            guard pi >= 0 else { continue }
            trackUsed[ti] = true
            var tr = tracks[ti]
            let prev = tr.last
            let q = particles[pi]
            let dt = t - prev.t
            ids[pi] = tr.id
            if dt > 0 {
                let dx = q.x - prev.x, dy = q.y - prev.y
                let u = dx / dt, v = dy / dt
                tr.predictedLinks = tr.velocity == nil ? 0 : tr.predictedLinks + 1
                var a: (u: Double, v: Double)?
                if let old = tr.velocity, tr.predictedLinks >= 2, tr.points.count >= 2 {
                    let span = 0.5 * (dt + prev.t - tr.points[tr.points.count - 2].t)
                    if span > 0 { a = ((u - old.u) / span, (v - old.v) / span) }
                }
                if let a, let b = tr.acceleration {
                    tr.steadyAcceleration = hypot(a.u - b.u, a.v - b.v) <= 0.5 * hypot(a.u, a.v)
                } else {
                    tr.steadyAcceleration = false
                }
                tr.acceleration = a
                tr.velocity = (u, v)
                samples.append(VelocitySample(trackID: tr.id, frameIndex: frameIndex, x: (q.x + prev.x) / 2, y: (q.y + prev.y) / 2,
                                              t: (t + prev.t) / 2, dx: dx, dy: dy, dt: dt, u: u, v: v))
            }
            tr.points.append((q.x, q.y, t))
            if tr.points.count > keep { tr.points.removeFirst(tr.points.count - keep) }
            tr.length += 1
            tr.missed = 0
            tracks[ti] = tr
        }

        flagOutliers(&samples)
        // 🐱 A track whose last step was an outlier should not propagate that velocity as its prediction.
        if samples.contains(where: \.outlier) {
            let bad = Set(samples.filter(\.outlier).map(\.trackID))
            for k in tracks.indices where bad.contains(tracks[k].id) {
                tracks[k].velocity = nil
                tracks[k].acceleration = nil
                tracks[k].steadyAcceleration = false
            }
        }

        var ended = 0
        var kept: [Track] = []
        kept.reserveCapacity(tracks.count + particles.count)
        for (ti, var tr) in tracks.enumerated() {
            if !trackUsed[ti] {
                tr.missed += 1
                if tr.missed > p.maxMissedFrames { ended += 1; continue }
            }
            kept.append(tr)
        }
        var started = 0
        for (pi, q) in particles.enumerated() where ids[pi] == 0 {
            let id = nextID
            nextID += 1
            ids[pi] = id
            kept.append(Track(id: id, points: [(q.x, q.y, t)], length: 1, missed: 0, velocity: nil))
            started += 1
        }
        tracks = kept
        return TrackingStep(trackIDs: ids, samples: samples, started: started, ended: ended)
    }

    /// 🐱 Tracks without any prediction (the first frames, or a region without established tracks) — the two-frame
    /// 🐱 problem, where the nearest particle is usually wrong once displacements approach the particle spacing.
    /// 🐱 Neighbour-consistency vote (relaxation labelling: Baek & Lee 1996, Ohmi & Li 2000): every particle within
    /// 🐱 reach is scored by how many unpredicted neighbours (within neighborRadius / 2) can make nearly the same
    /// 🐱 displacement (Gaussian weight, σ = maxDisplacement / 8, best match per neighbour); the best-supported one
    /// 🐱 becomes the prediction, with the gate of a neighbour-predicted track. No support: left unpredicted.
    private func voteForUnpredicted(_ free: [Int], particles: [Particle], grid: CellGrid,
                                    predX: inout [Double], predY: inout [Double], gate: inout [Double]) {
        let p = parameters
        var start = [Int](repeating: 0, count: free.count + 1)
        var cdx: [Double] = [], cdy: [Double] = [], cp: [Int] = []
        for (k, ti) in free.enumerated() {
            let l = tracks[ti].last
            let reach = p.maxDisplacement * Double(1 + tracks[ti].missed)
            let r2 = reach * reach
            grid.forEach(near: l.x, l.y, radius: reach) { pi in
                let dx = particles[pi].x - l.x, dy = particles[pi].y - l.y
                if dx * dx + dy * dy <= r2 { cdx.append(dx); cdy.append(dy); cp.append(pi) }
            }
            start[k + 1] = cdx.count
        }
        let vr = max(1, p.neighborRadius / 2), vr2 = vr * vr
        let sigma = max(0.5, p.maxDisplacement / 8), inv2s2 = 1 / (2 * sigma * sigma), far2 = 9 * sigma * sigma
        let near = CellGrid(count: free.count, cell: vr, x: { self.tracks[free[$0]].last.x }, y: { self.tracks[free[$0]].last.y })
        var score: [Double] = []
        for (k, ti) in free.enumerated() where start[k + 1] > start[k] {
            let l = tracks[ti].last
            let a = start[k], b = start[k + 1]
            score.removeAll(keepingCapacity: true)
            score.append(contentsOf: repeatElement(0, count: b - a))
            near.forEach(near: l.x, l.y, radius: vr) { m in
                guard m != k, start[m + 1] > start[m] else { return }
                let o = tracks[free[m]].last
                guard (o.x - l.x) * (o.x - l.x) + (o.y - l.y) * (o.y - l.y) <= vr2 else { return }
                for j in a..<b {
                    var best = far2
                    for q in start[m]..<start[m + 1] {
                        let ex = cdx[q] - cdx[j], ey = cdy[q] - cdy[j]
                        best = min(best, ex * ex + ey * ey)
                    }
                    if best < far2 { score[j - a] += exp(-best * inv2s2) }
                }
            }
            var bj = -1
            var bs = 0.0
            for j in a..<b where score[j - a] > bs { bs = score[j - a]; bj = j }
            guard bj >= 0 else { continue }
            predX[ti] = particles[cp[bj]].x
            predY[ti] = particles[cp[bj]].y
            gate[ti] = min(p.maxDisplacement, 1.5 * p.predictionRadius) * (1 + 0.5 * Double(tracks[ti].missed))
        }
    }

    /// 🐱 Normalised median test on scattered samples (Westerweel & Scarano 2005, applied to the neighbours
    /// 🐱 within `neighborRadius`). Samples with too few neighbours are left unflagged.
    private func flagOutliers(_ samples: inout [VelocitySample]) {
        let p = parameters
        guard samples.count > p.outlierMinNeighbors else { return }
        let grid = CellGrid(count: samples.count, cell: max(1.0, p.neighborRadius / 2), x: { samples[$0].x }, y: { samples[$0].y })
        let r2 = p.neighborRadius * p.neighborRadius
        var flags = [Bool](repeating: false, count: samples.count)
        var us: [Double] = [], vs: [Double] = []
        for (i, s) in samples.enumerated() {
            us.removeAll(keepingCapacity: true)
            vs.removeAll(keepingCapacity: true)
            grid.forEach(near: s.x, s.y, radius: p.neighborRadius) { j in
                guard j != i else { return }
                let o = samples[j]
                if (o.x - s.x) * (o.x - s.x) + (o.y - s.y) * (o.y - s.y) <= r2 {
                    us.append(o.u)
                    vs.append(o.v)
                }
            }
            guard us.count >= p.outlierMinNeighbors else { continue }
            let mu = medianInPlace(&us), mv = medianInPlace(&vs)
            for k in us.indices { us[k] = abs(us[k] - mu) }
            for k in vs.indices { vs[k] = abs(vs[k] - mv) }
            let ru = medianInPlace(&us), rv = medianInPlace(&vs)
            let eps = p.outlierEpsilonPx / max(s.dt, 1e-9)
            let r = max(abs(s.u - mu) / (ru + eps), abs(s.v - mv) / (rv + eps))
            flags[i] = r > p.outlierThreshold
        }
        for i in samples.indices { samples[i].outlier = flags[i] }
    }
}

@inline(__always) func median(_ a: [Double]) -> Double {
    let s = a.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
}

/// 🐱 Same value as `median`, in O(n) by quickselect (reorders `a`). The outlier test takes four medians per sample.
func medianInPlace(_ a: inout [Double]) -> Double {
    let n = a.count
    guard n > 0 else { return .nan }
    let k = n / 2
    return a.withUnsafeMutableBufferPointer { b -> Double in
        var lo = 0, hi = n - 1
        while hi > lo {
            let mid = (lo + hi) / 2
            if b[mid] < b[lo] { b.swapAt(mid, lo) }
            if b[hi] < b[lo] { b.swapAt(hi, lo) }
            if b[hi] < b[mid] { b.swapAt(hi, mid) }
            let pivot = b[mid]
            var i = lo, j = hi
            while i <= j {
                while i <= hi && b[i] < pivot { i += 1 }
                while j >= lo && b[j] > pivot { j -= 1 }
                if i <= j { b.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { break }
        }
        // 🐱 b[k] is the k-th smallest and everything before it is ≤ b[k]
        if n % 2 == 1 { return b[k] }
        var lower = b[0]
        for i in 1..<k { lower = max(lower, b[i]) }
        return 0.5 * (lower + b[k])
    }
}

/// 🐱 Points binned into square cells by counting sort: neighbourhood queries without hashing or per-cell arrays.
struct CellGrid {
    private var cell = 1.0, x0 = 0.0, y0 = 0.0, nx = 0, ny = 0
    private var start: [Int32] = []
    private var items: [Int32] = []

    init(count: Int, cell: Double, x: (Int) -> Double, y: (Int) -> Double) {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for i in 0..<count {
            let px = x(i), py = y(i)
            guard px.isFinite, py.isFinite else { continue }
            minX = min(minX, px); maxX = max(maxX, px)
            minY = min(minY, py); maxY = max(maxY, py)
        }
        guard minX <= maxX else { return }
        var c = max(cell, 1e-3)
        // 🐱 bounded memory however far apart the points are
        while ((maxX - minX) / c + 1) * ((maxY - minY) / c + 1) > Double(4 * count + 1024) { c *= 2 }
        self.cell = c
        x0 = minX
        y0 = minY
        nx = Int((maxX - minX) / c) + 1
        ny = Int((maxY - minY) / c) + 1
        var cellOf = [Int32](repeating: -1, count: count)
        var start = [Int32](repeating: 0, count: nx * ny + 1)
        for i in 0..<count {
            let px = x(i), py = y(i)
            guard px.isFinite, py.isFinite else { continue }
            let k = min(ny - 1, Int((py - y0) / c)) * nx + min(nx - 1, Int((px - x0) / c))
            cellOf[i] = Int32(k)
            start[k + 1] += 1
        }
        for k in 0..<(nx * ny) { start[k + 1] += start[k] }
        var fill = start
        var items = [Int32](repeating: 0, count: Int(start[nx * ny]))
        for i in 0..<count where cellOf[i] >= 0 {
            let k = Int(cellOf[i])
            items[Int(fill[k])] = Int32(i)
            fill[k] += 1
        }
        self.start = start
        self.items = items
    }

    /// 🐱 Calls `body` with every point in the cells overlapping the square of half-size `radius` around (x, y).
    @inline(__always) func forEach(near x: Double, _ y: Double, radius r: Double, _ body: (Int) -> Void) {
        guard nx > 0, x.isFinite, y.isFinite, r.isFinite else { return }
        let fx0 = (x - r - x0) / cell, fx1 = (x + r - x0) / cell
        let fy0 = (y - r - y0) / cell, fy1 = (y + r - y0) / cell
        guard fx1 >= 0, fy1 >= 0, fx0 < Double(nx), fy0 < Double(ny) else { return }
        let gx0 = fx0 <= 0 ? 0 : Int(fx0), gx1 = fx1 >= Double(nx - 1) ? nx - 1 : Int(fx1)
        let gy0 = fy0 <= 0 ? 0 : Int(fy0), gy1 = fy1 >= Double(ny - 1) ? ny - 1 : Int(fy1)
        for gy in gy0...gy1 {
            let row = gy * nx
            // 🐱 cells are stored row-major, so one row of cells is one contiguous run of items
            for s in Int(start[row + gx0])..<Int(start[row + gx1 + 1]) { body(Int(items[s])) }
        }
    }
}

/// 🐱 Assignment of rows (tracks) to columns (particles) along candidate edges, each row matched at most once or left
/// 🐱 unmatched at `missCost`, each column used at most once, minimising the total cost. Edges are added row by row.
/// 🐱 Exact solver: successive shortest augmenting paths with dual potentials (the Hungarian / Jonker–Volgenant
/// 🐱 augmentation, as in scipy's linear_sum_assignment) on the sparse candidate graph, with one private "unmatched"
/// 🐱 column per row. Each search stops at the first free column; every row's own unmatched column is free, so a
/// 🐱 search never reaches beyond reduced cost `missCost` and stays local even inside large connected groups.
struct AssignmentSolver {
    private var rowStart: [Int] = [0]
    private var col: [Int32] = []
    private var cost: [Double] = []
    private var nRows = 0, nCols = 0
    // 🐱 solver state
    private var u: [Double] = [], v: [Double] = [], dist: [Double] = []
    private var pathRow: [Int32] = [], col4row: [Int32] = [], row4col: [Int32] = []
    private var scanned: [Bool] = []
    private var touched: [Int32] = [], sr: [Int32] = [], sc: [Int32] = []
    private var heap: [(d: Double, j: Int32)] = []
    private var parent: [Int32] = []

    mutating func begin(rows: Int, columns: Int) {
        nRows = 0
        nCols = columns
        rowStart.removeAll(keepingCapacity: true)
        rowStart.reserveCapacity(rows + 1)
        rowStart.append(0)
        col.removeAll(keepingCapacity: true)
        cost.removeAll(keepingCapacity: true)
    }

    @inline(__always) mutating func addEdge(column: Int, cost c: Double) {
        col.append(Int32(column))
        cost.append(c)
    }

    mutating func endRow() {
        rowStart.append(col.count)
        nRows += 1
    }

    /// 🐱 Closest (cheapest) edges first; returns the column of each row or -1.
    mutating func solveGreedy() -> [Int] {
        prepare()
        greedy(rows: Array(0..<nRows))
        return result()
    }

    /// 🐱 Exact minimum total cost within every connected group of at most `maxGroupSize` rows + columns,
    /// 🐱 closest-first in larger groups. Returns the column of each row or -1.
    mutating func solve(missCost: Double, maxGroupSize: Int) -> [Int] {
        prepare()
        let nodes = nRows + nCols
        parent = (0..<nodes).map { Int32($0) }
        for r in 0..<nRows {
            for e in rowStart[r]..<rowStart[r + 1] { union(r, nRows + Int(col[e])) }
        }
        var size = [Int32](repeating: 0, count: nodes)
        var counted = [Bool](repeating: false, count: nCols)
        for r in 0..<nRows where rowStart[r + 1] > rowStart[r] {
            size[find(r)] += 1
            for e in rowStart[r]..<rowStart[r + 1] where !counted[Int(col[e])] {
                counted[Int(col[e])] = true
                size[find(r)] += 1
            }
        }
        var oversized: [Int] = []
        for r in 0..<nRows where rowStart[r + 1] > rowStart[r] {
            if Int(size[find(r)]) > maxGroupSize { oversized.append(r) } else { augment(r, missCost: missCost) }
        }
        if !oversized.isEmpty { greedy(rows: oversized) }
        return result()
    }

    private mutating func prepare() {
        let nc = nCols + nRows   // 🐱 particle columns, then one "unmatched" column per row
        u = [Double](repeating: 0, count: nRows)
        v = [Double](repeating: 0, count: nc)
        dist = [Double](repeating: .infinity, count: nc)
        pathRow = [Int32](repeating: -1, count: nc)
        scanned = [Bool](repeating: false, count: nc)
        row4col = [Int32](repeating: -1, count: nc)
        col4row = [Int32](repeating: -1, count: nRows)
    }

    private func result() -> [Int] {
        (0..<nRows).map { r in
            let c = Int(col4row[r])
            return c >= 0 && c < nCols ? c : -1
        }
    }

    private mutating func greedy(rows: [Int]) {
        var edges: [(c: Double, r: Int32, j: Int32)] = []
        for r in rows {
            for e in rowStart[r]..<rowStart[r + 1] { edges.append((cost[e], Int32(r), col[e])) }
        }
        edges.sort { $0.c < $1.c }
        for e in edges where col4row[Int(e.r)] < 0 && row4col[Int(e.j)] < 0 {
            col4row[Int(e.r)] = e.j
            row4col[Int(e.j)] = e.r
        }
    }

    private mutating func find(_ a: Int) -> Int {
        var a = a
        while Int(parent[a]) != a {
            parent[a] = parent[Int(parent[a])]
            a = Int(parent[a])
        }
        return a
    }

    private mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[ra] = Int32(rb) }
    }

    /// 🐱 Adds row `cur` to the matching along a shortest augmenting path (reduced costs stay ≥ 0).
    private mutating func augment(_ cur: Int, missCost: Double) {
        var minVal = 0.0
        var i = cur
        var sink = -1
        sr.removeAll(keepingCapacity: true)
        sc.removeAll(keepingCapacity: true)
        touched.removeAll(keepingCapacity: true)
        heap.removeAll(keepingCapacity: true)
        while sink < 0 {
            sr.append(Int32(i))
            let ui = u[i]
            for e in rowStart[i]..<rowStart[i + 1] {
                relax(Int(col[e]), minVal + cost[e] - ui, from: i)
            }
            relax(nCols + i, minVal + missCost - ui, from: i)
            var j = -1
            while !heap.isEmpty {
                let top = heapPop()
                let k = Int(top.j)
                if !scanned[k] && top.d == dist[k] { j = k; break }
            }
            guard j >= 0 else { break }   // 🐱 unreachable: the row's own unmatched column is always free
            minVal = dist[j]
            scanned[j] = true
            sc.append(Int32(j))
            if row4col[j] < 0 { sink = j } else { i = Int(row4col[j]) }
        }
        if sink >= 0 {
            u[cur] += minVal
            for k in sr.dropFirst() {
                let r = Int(k)
                u[r] += minVal - dist[Int(col4row[r])]
            }
            for k in sc {
                let j = Int(k)
                v[j] -= minVal - dist[j]
            }
            var j = sink
            while true {
                let r = Int(pathRow[j])
                row4col[j] = Int32(r)
                let previous = Int(col4row[r])
                col4row[r] = Int32(j)
                if r == cur { break }
                j = previous
            }
        }
        for k in touched {
            dist[Int(k)] = .infinity
            scanned[Int(k)] = false
        }
    }

    @inline(__always) private mutating func relax(_ j: Int, _ reducedWithoutV: Double, from i: Int) {
        if scanned[j] { return }
        let r = reducedWithoutV - v[j]
        if r < dist[j] {
            if dist[j] == .infinity { touched.append(Int32(j)) }
            dist[j] = r
            pathRow[j] = Int32(i)
            heapPush(r, Int32(j))
        }
    }

    private mutating func heapPush(_ d: Double, _ j: Int32) {
        heap.append((d, j))
        var c = heap.count - 1
        while c > 0 {
            let p = (c - 1) / 2
            if heap[p].d <= heap[c].d { break }
            heap.swapAt(p, c)
            c = p
        }
    }

    private mutating func heapPop() -> (d: Double, j: Int32) {
        let top = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var c = 0
            let n = heap.count
            while true {
                let l = 2 * c + 1, r = l + 1
                var m = c
                if l < n && heap[l].d < heap[m].d { m = l }
                if r < n && heap[r].d < heap[m].d { m = r }
                if m == c { break }
                heap.swapAt(m, c)
                c = m
            }
        }
        return top
    }
}
