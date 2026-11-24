import Accelerate
import Foundation

/// 🐱 Hot per-vector loops written with raw pointers, `while` loops and concrete arithmetic only.
/// 🐱
/// 🐱 Swift Playgrounds builds the app without optimisation. There, generic standard-library code (`sorted`, `map`,
/// 🐱 `reduce`, `for … in` over ranges, arrays of tuples) is 10–100× slower than in a release build, while raw
/// 🐱 pointer access and arithmetic on concrete types stay fast. These kernels keep the live analysis fast in
/// 🐱 both builds.
public enum GridKernels {
    /// 🐱 Median of `n` (≤ 16) values; sorts `p` in place (insertion sort).
    @inline(__always)
    public static func median(_ p: UnsafeMutablePointer<Double>, _ n: Int) -> Double {
        var i = 1
        while i < n {
            let v = p[i]
            var j = i - 1
            while j >= 0 && p[j] > v {
                p[j + 1] = p[j]
                j -= 1
            }
            p[j + 1] = v
            i += 1
        }
        let h = n / 2
        return n % 2 == 1 ? p[h] : 0.5 * (p[h - 1] + p[h])
    }

    /// 🐱 Values of the usable 8-neighbours of (i, j) into su/sv; returns how many.
    @inline(__always)
    static func gather(_ i: Int, _ j: Int, _ cols: Int, _ rows: Int,
                       _ U: UnsafePointer<Double>, _ V: UnsafePointer<Double>, _ ok: UnsafePointer<UInt8>,
                       _ su: UnsafeMutablePointer<Double>, _ sv: UnsafeMutablePointer<Double>) -> Int {
        var m = 0
        var jj = j - 1
        while jj <= j + 1 {
            if jj >= 0 && jj < rows {
                var ii = i - 1
                while ii <= i + 1 {
                    if ii >= 0 && ii < cols && (ii != i || jj != j) {
                        let q = jj * cols + ii
                        if ok[q] != 0 {
                            su[m] = U[q]
                            sv[m] = V[q]
                            m += 1
                        }
                    }
                    ii += 1
                }
            }
            jj += 1
        }
        return m
    }

    /// 🐱 Normalised median test (Westerweel & Scarano 2005) on a regular grid. Only usable cells are tested and
    /// 🐱 used as neighbours; cells with fewer than three usable neighbours are not tested. Returns 1 for outliers.
    public static func medianTestOutliers(u: [Double], v: [Double], usable: [UInt8], columns cols: Int, rows: Int,
                                          threshold: Double, epsilon: Double) -> [UInt8] {
        let n = cols * rows
        var out = [UInt8](repeating: 0, count: n)
        guard n > 0, u.count >= n, v.count >= n, usable.count >= n else { return out }
        let scratch = UnsafeMutablePointer<Double>.allocate(capacity: 32)
        defer { scratch.deallocate() }
        let su = scratch, sv = scratch + 8, ru = scratch + 16, rv = scratch + 24
        u.withUnsafeBufferPointer { ub in
            v.withUnsafeBufferPointer { vb in
                usable.withUnsafeBufferPointer { okb in
                    out.withUnsafeMutableBufferPointer { ob in
                        let U = ub.baseAddress!, V = vb.baseAddress!, OK = okb.baseAddress!, O = ob.baseAddress!
                        var j = 0
                        while j < rows {
                            var i = 0
                            while i < cols {
                                let k = j * cols + i
                                if OK[k] != 0 {
                                    let m = gather(i, j, cols, rows, U, V, OK, su, sv)
                                    if m >= 3 {
                                        let mu = median(su, m), mv = median(sv, m)
                                        var t = 0
                                        while t < m {
                                            ru[t] = fabs(su[t] - mu)
                                            rv[t] = fabs(sv[t] - mv)
                                            t += 1
                                        }
                                        let a = fabs(U[k] - mu) / (median(ru, m) + epsilon)
                                        let b = fabs(V[k] - mv) / (median(rv, m) + epsilon)
                                        if a > threshold || b > threshold { O[k] = 1 }
                                    }
                                }
                                i += 1
                            }
                            j += 1
                        }
                    }
                }
            }
        }
        return out
    }

    /// 🐱 For every target cell with at least three usable neighbours: the neighbours' median (u, v).
    /// 🐱 `found[k] == 1` where a replacement was computed.
    public static func neighbourMedians(u: [Double], v: [Double], usable: [UInt8], targets: [UInt8], columns cols: Int, rows: Int)
        -> (u: [Double], v: [Double], found: [UInt8]) {
        let n = cols * rows
        var mu = [Double](repeating: 0, count: n), mv = mu
        var found = [UInt8](repeating: 0, count: n)
        guard n > 0, u.count >= n, v.count >= n, usable.count >= n, targets.count >= n else { return (mu, mv, found) }
        let scratch = UnsafeMutablePointer<Double>.allocate(capacity: 16)
        defer { scratch.deallocate() }
        let su = scratch, sv = scratch + 8
        u.withUnsafeBufferPointer { ub in
            v.withUnsafeBufferPointer { vb in
                usable.withUnsafeBufferPointer { okb in
                    targets.withUnsafeBufferPointer { tb in
                        mu.withUnsafeMutableBufferPointer { mub in
                            mv.withUnsafeMutableBufferPointer { mvb in
                                found.withUnsafeMutableBufferPointer { fb in
                                    let U = ub.baseAddress!, V = vb.baseAddress!, OK = okb.baseAddress!, T = tb.baseAddress!
                                    let MU = mub.baseAddress!, MV = mvb.baseAddress!, F = fb.baseAddress!
                                    var j = 0
                                    while j < rows {
                                        var i = 0
                                        while i < cols {
                                            let k = j * cols + i
                                            if T[k] != 0 {
                                                let m = gather(i, j, cols, rows, U, V, OK, su, sv)
                                                if m >= 3 {
                                                    MU[k] = median(su, m)
                                                    MV[k] = median(sv, m)
                                                    F[k] = 1
                                                }
                                            }
                                            i += 1
                                        }
                                        j += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return (mu, mv, found)
    }

    /// 🐱 Median of an arbitrary array without generic sorting (vDSP sort on a copy).
    public static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var s = values
        vDSP_vsortD(&s, vDSP_Length(s.count), 1)
        let h = s.count / 2
        return s.count % 2 == 1 ? s[h] : 0.5 * (s[h - 1] + s[h])
    }

    /// 🐱 Sorted copy (ascending) via vDSP.
    public static func sorted(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values }
        var s = values
        vDSP_vsortD(&s, vDSP_Length(s.count), 1)
        return s
    }
}
