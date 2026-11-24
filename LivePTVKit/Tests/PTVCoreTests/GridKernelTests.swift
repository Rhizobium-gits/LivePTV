import Foundation
import Testing
@testable import PTVCore

/// 🐱 The fast (pointer / while-loop) kernels must give exactly what the straightforward versions gave.
@Suite struct GridKernelTests {
    private func naiveMedian(_ a: [Double]) -> Double {
        let s = a.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }

    /// 🐱 Reference: the previous implementation of the normalised median test.
    private func naiveOutliers(_ u: [Double], _ v: [Double], _ ok: [Bool], cols: Int, rows: Int, threshold: Double, eps: Double) -> [Bool] {
        var out = [Bool](repeating: false, count: cols * rows)
        for j in 0..<rows {
            for i in 0..<cols {
                let k = j * cols + i
                guard ok[k] else { continue }
                var nu: [Double] = [], nv: [Double] = []
                for dj in -1...1 {
                    for di in -1...1 where !(di == 0 && dj == 0) {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, jj >= 0, ii < cols, jj < rows, ok[jj * cols + ii] else { continue }
                        nu.append(u[jj * cols + ii]); nv.append(v[jj * cols + ii])
                    }
                }
                guard nu.count >= 3 else { continue }
                let mu = naiveMedian(nu), mv = naiveMedian(nv)
                let ru = naiveMedian(nu.map { abs($0 - mu) }), rv = naiveMedian(nv.map { abs($0 - mv) })
                out[k] = max(abs(u[k] - mu) / (ru + eps), abs(v[k] - mv) / (rv + eps)) > threshold
            }
        }
        return out
    }

    @Test func medianMatchesSorting() {
        var rng = SystemRandomNumberGenerator()
        for n in 1...9 {
            for _ in 0..<50 {
                let a = (0..<n).map { _ in Double.random(in: -5...5, using: &rng) }
                var b = a
                let m = b.withUnsafeMutableBufferPointer { GridKernels.median($0.baseAddress!, n) }
                #expect(m == naiveMedian(a))
            }
        }
        #expect(GridKernels.median(of: [3, 1, 2, 10]) == 2.5)
        #expect(GridKernels.median(of: []) == nil)
        #expect(GridKernels.sorted([3, -1, 2]) == [-1, 2, 3])
    }

    @Test func medianTestMatchesReference() {
        let cols = 23, rows = 17, n = cols * rows
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<5 {
            // 🐱 smooth field + noise + 5 % wild vectors + 10 % unusable cells
            var u = (0..<n).map { k in sin(Double(k % cols) / 4) * 3 + Double.random(in: -0.2...0.2, using: &rng) }
            var v = (0..<n).map { k in cos(Double(k / cols) / 3) * 2 + Double.random(in: -0.2...0.2, using: &rng) }
            for k in 0..<n where Double.random(in: 0...1, using: &rng) < 0.05 {
                u[k] += Double.random(in: -8...8, using: &rng)
                v[k] += Double.random(in: -8...8, using: &rng)
            }
            let ok = (0..<n).map { _ in Double.random(in: 0...1, using: &rng) > 0.1 }
            let fast = GridKernels.medianTestOutliers(u: u, v: v, usable: ok.map { $0 ? 1 : 0 }, columns: cols, rows: rows,
                                                      threshold: 2, epsilon: 0.1)
            let ref = naiveOutliers(u, v, ok, cols: cols, rows: rows, threshold: 2, eps: 0.1)
            #expect(fast.map { $0 != 0 } == ref, "trial \(trial)")
            #expect(ref.contains(true))
        }
    }

    @Test func validationReplacesWildVector() {
        let cols = 9, rows = 7, n = cols * rows
        var f = PIVField(columns: cols, rows: rows, originX: 16, originY: 16, step: 16, windowSize: 32,
                         dx: .init(repeating: 1.5, count: n), dy: .init(repeating: -0.5, count: n), dt: 1 / 30.0,
                         status: .init(repeating: .valid, count: n), correlation: .init(repeating: 0.9, count: n))
        let wild = 3 * cols + 4, missing = 5 * cols + 2
        f.dx[wild] = 9
        f.status[missing] = .invalid
        PIVEngine.validate(&f, threshold: 2, epsilon: 0.1, replace: true)
        #expect(f.status[wild] == .replaced && f.dx[wild] == 1.5 && f.dy[wild] == -0.5)
        #expect(f.status[missing] == .replaced && f.dx[missing] == 1.5)
        #expect(f.validCount == n - 2)
    }

    @Test func averagerMeanStdAndValidFraction() {
        let cols = 4, rows = 3, n = cols * rows
        let grid = GridGeometry(originX: 0, originY: 0, cellSize: 16, columns: cols, rows: rows)
        var fp = FieldParameters()
        fp.window = 1
        fp.minSamples = 1
        fp.outlierThreshold = 1e9   // 🐱 averaging only here; the median test is checked above
        let avg = PIVFieldAverager(grid: grid, parameters: fp)
        let dt = 0.1
        for t in 0..<10 {
            var st = [PIVField.Status](repeating: .valid, count: n)
            st[5] = t == 0 ? .valid : .invalid      // 🐱 valid in 1 of 10 fields → hidden
            st[6] = t % 2 == 0 ? .valid : .replaced  // 🐱 valid in 5 of 10 → shown, replaced ones not averaged
            let dx = [Double](repeating: t % 2 == 0 ? 1.0 : 3.0, count: n)
            let f = PIVField(columns: cols, rows: rows, originX: 8, originY: 8, step: 16, windowSize: 32,
                             dx: dx, dy: .init(repeating: 0, count: n), dt: dt, status: st, correlation: .init(repeating: 1, count: n))
            avg.add(f, time: Double(t) * 0.05)
        }
        let snap = avg.snapshot(at: 0.5)
        let c0 = snap.cells[0]
        #expect(c0.count == 10 && abs(c0.u - 20) < 1e-9)                 // 🐱 mean of 10 and 30 px/s
        #expect(abs(c0.stdU - (100.0 * 10 / 9).squareRoot()) < 1e-9)    // 🐱 sample std of ±10
        #expect(abs(c0.x - 8) < 1e-9 && abs(c0.y - 8) < 1e-9)            // 🐱 cell centre = vector position
        #expect(!snap.cells[5].valid)
        #expect(snap.cells[6].valid && snap.cells[6].count == 5 && abs(snap.cells[6].u - 10) < 1e-9)
        // 🐱 old fields leave the window
        let later = avg.snapshot(at: 1.32)
        #expect(later.cells[0].count == 3)
    }
}
