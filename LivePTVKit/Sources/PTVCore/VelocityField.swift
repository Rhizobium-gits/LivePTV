import Accelerate
import Foundation

public struct FieldParameters: Codable, Equatable, Sendable {
    /// 🐱 Grid cell size in px.
    public var cellSize: Double = 32
    /// 🐱 Samples older than this (s) are forgotten: the field is a moving temporal average.
    public var window: Double = 1.0
    /// 🐱 Cells need at least this many samples to be reported.
    public var minSamples = 3
    /// 🐱 Normalised median test (Westerweel & Scarano 2005): residual threshold...
    public var outlierThreshold = 2.0
    /// 🐱 ...and noise floor ε in px/s (≈ 0.1 px displacement × frame rate).
    public var outlierEpsilon = 3.0

    public init() {}
}

public struct FieldCell: Codable, Equatable, Sendable {
    public var i: Int
    public var j: Int
    /// 🐱 Cell centre, full-frame px.
    public var x: Double
    public var y: Double
    /// 🐱 Mean velocity, px/s.
    public var u: Double
    public var v: Double
    public var stdU: Double
    public var stdV: Double
    public var count: Int
    /// 🐱 Enough samples and not rejected as outlier.
    public var valid: Bool
    public var outlier: Bool
}

public struct FieldSnapshot: Codable, Sendable {
    public var time: Double
    public var cellSize: Double
    public var columns: Int
    public var rows: Int
    public var originX: Double
    public var originY: Double
    /// 🐱 Row-major, `rows * columns` entries.
    public var cells: [FieldCell]

    public func cell(i: Int, j: Int) -> FieldCell? {
        guard i >= 0, j >= 0, i < columns, j < rows else { return nil }
        return cells[j * columns + i]
    }

    public var validCount: Int { cells.reduce(0) { $0 + ($1.valid ? 1 : 0) } }
}

/// 🐱 Bins Lagrangian samples into an Eulerian grid over a sliding time window.
public final class VelocityFieldAccumulator {
    public private(set) var parameters: FieldParameters
    public private(set) var roi: PixelROI
    public let columns: Int
    public let rows: Int
    private var bins: [[(t: Double, u: Double, v: Double)]]
    private var heads: [Int]

    public init(roi: PixelROI, parameters: FieldParameters = FieldParameters()) {
        self.roi = roi
        self.parameters = parameters
        columns = max(1, Int(ceil(Double(roi.width) / parameters.cellSize)))
        rows = max(1, Int(ceil(Double(roi.height) / parameters.cellSize)))
        bins = Array(repeating: [], count: columns * rows)
        heads = Array(repeating: 0, count: columns * rows)
    }

    public func reset() {
        for k in bins.indices { bins[k].removeAll(keepingCapacity: true); heads[k] = 0 }
    }

    public func add(_ samples: [VelocitySample]) {
        let cs = parameters.cellSize
        for s in samples where !s.outlier {
            let i = Int(floor((s.x - Double(roi.x)) / cs)), j = Int(floor((s.y - Double(roi.y)) / cs))
            guard i >= 0, j >= 0, i < columns, j < rows else { continue }
            bins[j * columns + i].append((s.t, s.u, s.v))
        }
    }

    private func prune(before cutoff: Double) {
        for k in bins.indices {
            var h = heads[k]
            let b = bins[k]
            while h < b.count && b[h].t < cutoff { h += 1 }
            if h > 64 && h * 2 > b.count {
                bins[k].removeFirst(h)
                h = 0
            }
            heads[k] = h
        }
    }

    public func snapshot(at time: Double) -> FieldSnapshot {
        prune(before: time - parameters.window)
        let cs = parameters.cellSize
        var cells: [FieldCell] = []
        cells.reserveCapacity(bins.count)
        for j in 0..<rows {
            for i in 0..<columns {
                let k = j * columns + i
                let b = bins[k]
                let n = b.count - heads[k]
                var mu = 0.0, mv = 0.0, su = 0.0, sv = 0.0
                if n > 0 {
                    for s in b[heads[k]...] { mu += s.u; mv += s.v }
                    mu /= Double(n); mv /= Double(n)
                    for s in b[heads[k]...] { su += (s.u - mu) * (s.u - mu); sv += (s.v - mv) * (s.v - mv) }
                    su = n > 1 ? sqrt(su / Double(n - 1)) : 0
                    sv = n > 1 ? sqrt(sv / Double(n - 1)) : 0
                }
                cells.append(FieldCell(i: i, j: j, x: Double(roi.x) + (Double(i) + 0.5) * cs, y: Double(roi.y) + (Double(j) + 0.5) * cs,
                                       u: mu, v: mv, stdU: su, stdV: sv, count: n, valid: n >= parameters.minSamples, outlier: false))
            }
        }
        var snap = FieldSnapshot(time: time, cellSize: cs, columns: columns, rows: rows, originX: Double(roi.x), originY: Double(roi.y), cells: cells)
        Self.normalizedMedianTest(&snap, threshold: parameters.outlierThreshold, epsilon: parameters.outlierEpsilon)
        return snap
    }

    /// 🐱 Flags (does not replace) vectors that disagree with their 3×3 neighbourhood. Cells with fewer than
    /// 🐱 three valid neighbours are not tested.
    public static func normalizedMedianTest(_ snap: inout FieldSnapshot, threshold: Double, epsilon: Double) {
        let n = snap.cells.count
        guard n == snap.columns * snap.rows, n > 0 else { return }
        var u = [Double](repeating: 0, count: n), v = u
        var usable = [UInt8](repeating: 0, count: n)
        var k = 0
        while k < n {
            let c = snap.cells[k]
            u[k] = c.u
            v[k] = c.v
            usable[k] = c.valid ? 1 : 0
            k += 1
        }
        let out = GridKernels.medianTestOutliers(u: u, v: v, usable: usable, columns: snap.columns, rows: snap.rows,
                                                 threshold: threshold, epsilon: epsilon)
        k = 0
        while k < n {
            if out[k] != 0 {
                snap.cells[k].outlier = true
                snap.cells[k].valid = false
            }
            k += 1
        }
    }
}

/// 🐱 Moving temporal average of PIV fields on their own grid (PIV mode's live and recorded field).
/// 🐱 Everything is whole-array vDSP arithmetic, so it costs well under a millisecond even in unoptimised builds.
public final class PIVFieldAverager {
    public let grid: GridGeometry
    public private(set) var parameters: FieldParameters
    /// 🐱 A cell is shown only if its vector was valid in at least this share of the fields in the window: a cell
    /// 🐱 that is valid once in 30 pairs (edge, empty region) is far more likely noise than flow.
    public var minValidFraction = 0.3
    private var entries: [(time: Double, u: [Double], v: [Double], mask: [Double])] = []

    public init(grid: GridGeometry, parameters: FieldParameters) {
        self.grid = grid
        self.parameters = parameters
    }

    public var count: Int { entries.count }

    public func reset() { entries.removeAll() }

    /// 🐱 Adds one PIV field (only `.valid` vectors count) at the pair's mid time.
    public func add(_ f: PIVField, time: Double) {
        let n = grid.columns * grid.rows
        guard f.count == n, f.dt > 0 else { return }
        var mask = [Double](repeating: 0, count: n)
        f.status.withUnsafeBufferPointer { sb in
            mask.withUnsafeMutableBufferPointer { mb in
                let S = sb.baseAddress!, M = mb.baseAddress!
                var k = 0
                while k < n {
                    if S[k].rawValue == PIVField.Status.valid.rawValue { M[k] = 1 }
                    k += 1
                }
            }
        }
        var inv = 1 / f.dt
        var u = [Double](repeating: 0, count: n), v = u
        vDSP_vsmulD(f.dx, 1, &inv, &u, 1, vDSP_Length(n))
        vDSP_vsmulD(f.dy, 1, &inv, &v, 1, vDSP_Length(n))
        vDSP_vmulD(u, 1, mask, 1, &u, 1, vDSP_Length(n))
        vDSP_vmulD(v, 1, mask, 1, &v, 1, vDSP_Length(n))
        entries.append((time, u, v, mask))
        // 🐱 bound memory even if time stalls
        if entries.count > 600 { entries.removeFirst(entries.count - 600) }
    }

    /// 🐱 Mean, standard deviation and count of the fields within `window` seconds before `time` (and always the newest
    /// 🐱 field), then the normalised median test on the means. A field is dated at its pair's mid time, half a pair
    /// 🐱 spacing back: with 1-s pairs (automatic spacing in a still scene) and a 0.25-s window, a live run showed an
    /// 🐱 empty field for seconds while every pair was measured.
    public func snapshot(at time: Double) -> FieldSnapshot {
        let cutoff = Swift.min(time - parameters.window, entries.last?.time ?? .infinity)
        if let firstKept = entries.firstIndex(where: { $0.time >= cutoff }) {
            if firstKept > 0 { entries.removeFirst(firstKept) }
        } else {
            entries.removeAll()
        }
        let n = grid.columns * grid.rows
        var su = [Double](repeating: 0, count: n), sv = su, suu = su, svv = su, cnt = su
        let N = vDSP_Length(n)
        for e in entries {
            vDSP_vaddD(su, 1, e.u, 1, &su, 1, N)
            vDSP_vaddD(sv, 1, e.v, 1, &sv, 1, N)
            vDSP_vmaD(e.u, 1, e.u, 1, suu, 1, &suu, 1, N)
            vDSP_vmaD(e.v, 1, e.v, 1, svv, 1, &svv, 1, N)
            vDSP_vaddD(cnt, 1, e.mask, 1, &cnt, 1, N)
        }
        let cs = grid.cellSize, cols = grid.columns
        let minSamples = Swift.max(Double(Swift.max(1, parameters.minSamples)), (minValidFraction * Double(entries.count)).rounded(.up))
        var cells: [FieldCell] = []
        cells.reserveCapacity(n)
        var k = 0
        while k < n {
            let c = cnt[k]
            var mu = 0.0, mv = 0.0, sdu = 0.0, sdv = 0.0
            if c > 0 {
                mu = su[k] / c
                mv = sv[k] / c
                if c > 1 {
                    sdu = (Swift.max(0, suu[k] - c * mu * mu) / (c - 1)).squareRoot()
                    sdv = (Swift.max(0, svv[k] - c * mv * mv) / (c - 1)).squareRoot()
                }
            }
            let i = k % cols, j = k / cols
            cells.append(FieldCell(i: i, j: j, x: grid.originX + (Double(i) + 0.5) * cs, y: grid.originY + (Double(j) + 0.5) * cs,
                                   u: mu, v: mv, stdU: sdu, stdV: sdv, count: Int(c), valid: c >= minSamples, outlier: false))
            k += 1
        }
        var snap = FieldSnapshot(time: time, cellSize: cs, columns: grid.columns, rows: grid.rows,
                                 originX: grid.originX, originY: grid.originY, cells: cells)
        VelocityFieldAccumulator.normalizedMedianTest(&snap, threshold: parameters.outlierThreshold, epsilon: parameters.outlierEpsilon)
        return snap
    }
}

/// 🐱 Pixel → physical units. `mmPerPixel` comes from imaging a ruler / calibration target in the
/// 🐱 measurement plane. Nil keeps everything in pixels.
public struct Calibration: Codable, Equatable, Sendable {
    public var mmPerPixel: Double?
    public var note: String

    public init(mmPerPixel: Double? = nil, note: String = "") {
        self.mmPerPixel = mmPerPixel
        self.note = note
    }

    public var unitLabel: String { mmPerPixel == nil ? "px/s" : "mm/s" }

    public func physical(_ pxPerSecond: Double) -> Double { pxPerSecond * (mmPerPixel ?? 1) }
}
