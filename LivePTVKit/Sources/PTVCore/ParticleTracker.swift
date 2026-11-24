import Foundation

public struct TrackerParameters: Codable, Equatable, Sendable {
    /// 🐱 Search radius (px) when nothing better is known: the largest displacement expected between frames.
    public var maxDisplacement: Double = 12
    /// 🐱 Search radius (px) around the constant-velocity prediction of an established track.
    public var predictionRadius: Double = 4
    /// 🐱 New tracks borrow the median velocity of established tracks within this radius (px) as their
    /// 🐱 prediction. This is what keeps nearest-neighbour ambiguity low at realistic seeding densities.
    public var neighborPrediction = true
    public var neighborRadius: Double = 40
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
/// 🐱  1. prediction: own constant velocity, else the median velocity of established neighbours, else none;
/// 🐱  2. gated search around the prediction;
/// 🐱  3. globally greedy assignment (closest pairs first, each particle / track used once);
/// 🐱  4. velocity samples from real timestamps (correct across dropped frames);
/// 🐱  5. normalised median test flags samples that disagree with their neighbours.
public final class ParticleTracker {
    public var parameters: TrackerParameters
    public private(set) var tracks: [Track] = []
    private var nextID = 1
    private var lastTime: Double?

    public init(parameters: TrackerParameters = TrackerParameters()) { self.parameters = parameters }

    public func reset() {
        tracks.removeAll()
        lastTime = nil
    }

    @inline(__always) private static func key(_ gx: Int, _ gy: Int) -> Int { gx &* 73_856_093 ^ gy &* 19_349_663 }

    public func update(particles: [Particle], time t: Double, frameIndex: Int) -> TrackingStep {
        let p = parameters
        if let lt = lastTime, t <= lt { reset() }   // 🐱 time did not advance: restart cleanly
        lastTime = t

        // 🐱 Established tracks (with velocity) on a grid, for neighbour prediction.
        let nCell = max(1.0, p.neighborRadius)
        var velocityGrid: [Int: [Int]] = [:]
        if p.neighborPrediction {
            for (ti, tr) in tracks.enumerated() where tr.velocity != nil && tr.missed == 0 {
                let l = tr.last
                velocityGrid[Self.key(Int(floor(l.x / nCell)), Int(floor(l.y / nCell))), default: []].append(ti)
            }
        }
        func neighborVelocity(_ x: Double, _ y: Double) -> (Double, Double)? {
            guard p.neighborPrediction else { return nil }
            var us: [Double] = [], vs: [Double] = []
            let gx = Int(floor(x / nCell)), gy = Int(floor(y / nCell))
            let r2 = p.neighborRadius * p.neighborRadius
            for dy in -1...1 {
                for dx in -1...1 {
                    for ti in velocityGrid[Self.key(gx + dx, gy + dy)] ?? [] {
                        let l = tracks[ti].last
                        if (l.x - x) * (l.x - x) + (l.y - y) * (l.y - y) <= r2, let v = tracks[ti].velocity {
                            us.append(v.u)
                            vs.append(v.v)
                        }
                    }
                }
            }
            guard us.count >= 3 else { return nil }
            return (median(us), median(vs))
        }

        // 🐱 Candidate particles on a grid sized for the largest search radius.
        let maxRadius = max(p.maxDisplacement, p.predictionRadius * 2 * (1 + Double(p.maxMissedFrames)))
        let cell = max(1.0, maxRadius)
        var grid: [Int: [Int]] = [:]
        for (i, q) in particles.enumerated() {
            grid[Self.key(Int(floor(q.x / cell)), Int(floor(q.y / cell))), default: []].append(i)
        }

        var pairs: [(d2: Double, track: Int, particle: Int)] = []
        for (ti, tr) in tracks.enumerated() {
            let last = tr.last
            let dt = t - last.t
            var px = last.x, py = last.y
            var radius = p.maxDisplacement * Double(1 + tr.missed)
            if let v = tr.velocity {
                px += v.u * dt
                py += v.v * dt
                radius = p.predictionRadius * (1 + 0.5 * Double(tr.missed))
            } else if let v = neighborVelocity(last.x, last.y) {
                px += v.0 * dt
                py += v.1 * dt
                radius = min(p.maxDisplacement, p.predictionRadius * 1.5) * (1 + 0.5 * Double(tr.missed))
            }
            let r2 = radius * radius
            let gx = Int(floor(px / cell)), gy = Int(floor(py / cell))
            let span = Int(ceil(radius / cell))
            for dy in -span...span {
                for dx in -span...span {
                    for pi in grid[Self.key(gx + dx, gy + dy)] ?? [] {
                        let ex = particles[pi].x - px, ey = particles[pi].y - py
                        let d2 = ex * ex + ey * ey
                        if d2 <= r2 { pairs.append((d2, ti, pi)) }
                    }
                }
            }
        }
        pairs.sort { $0.d2 < $1.d2 }

        var trackUsed = [Bool](repeating: false, count: tracks.count)
        var ids = [Int](repeating: 0, count: particles.count)
        var samples: [VelocitySample] = []
        for pr in pairs where !trackUsed[pr.track] && ids[pr.particle] == 0 {
            trackUsed[pr.track] = true
            var tr = tracks[pr.track]
            let prev = tr.last
            let q = particles[pr.particle]
            let dt = t - prev.t
            ids[pr.particle] = tr.id
            if dt > 0 {
                let dx = q.x - prev.x, dy = q.y - prev.y
                let u = dx / dt, v = dy / dt
                tr.velocity = (u, v)
                samples.append(VelocitySample(trackID: tr.id, frameIndex: frameIndex, x: (q.x + prev.x) / 2, y: (q.y + prev.y) / 2,
                                              t: (t + prev.t) / 2, dx: dx, dy: dy, dt: dt, u: u, v: v))
            }
            tr.points.append((q.x, q.y, t))
            let keep = max(2, p.tailLength)
            if tr.points.count > keep { tr.points.removeFirst(tr.points.count - keep) }
            tr.length += 1
            tr.missed = 0
            tracks[pr.track] = tr
        }

        flagOutliers(&samples)
        // 🐱 A track whose last step was an outlier should not propagate that velocity as its prediction.
        if samples.contains(where: \.outlier) {
            let bad = Set(samples.filter(\.outlier).map(\.trackID))
            for k in tracks.indices where bad.contains(tracks[k].id) { tracks[k].velocity = nil }
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

    /// 🐱 Normalised median test on scattered samples (Westerweel & Scarano 2005, applied to the neighbours
    /// 🐱 within `neighborRadius`). Samples with too few neighbours are left unflagged.
    private func flagOutliers(_ samples: inout [VelocitySample]) {
        let p = parameters
        guard samples.count > p.outlierMinNeighbors else { return }
        let cell = max(1.0, p.neighborRadius)
        var grid: [Int: [Int]] = [:]
        for (i, s) in samples.enumerated() {
            grid[Self.key(Int(floor(s.x / cell)), Int(floor(s.y / cell))), default: []].append(i)
        }
        let r2 = p.neighborRadius * p.neighborRadius
        var flags = [Bool](repeating: false, count: samples.count)
        for (i, s) in samples.enumerated() {
            var us: [Double] = [], vs: [Double] = []
            let gx = Int(floor(s.x / cell)), gy = Int(floor(s.y / cell))
            for dy in -1...1 {
                for dx in -1...1 {
                    for j in grid[Self.key(gx + dx, gy + dy)] ?? [] where j != i {
                        let o = samples[j]
                        if (o.x - s.x) * (o.x - s.x) + (o.y - s.y) * (o.y - s.y) <= r2 {
                            us.append(o.u)
                            vs.append(o.v)
                        }
                    }
                }
            }
            guard us.count >= p.outlierMinNeighbors else { continue }
            let mu = median(us), mv = median(vs)
            let ru = median(us.map { abs($0 - mu) }), rv = median(vs.map { abs($0 - mv) })
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
