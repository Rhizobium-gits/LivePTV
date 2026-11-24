import Accelerate
import Foundation

/// 🐱 Ensemble-correlation settings (PIV).
public struct EnsembleParameters: Codable, Equatable, Sendable {
    /// 🐱 Average correlation planes over many frame pairs instead of averaging vectors (Meinhart, Wereley &
    /// 🐱 Santiago 2000; the standard for micro-PIV). Random particle pairings and noise average out of the
    /// 🐱 correlation plane while the true displacement peak adds up, so faint, sparse or Brownian particles still
    /// 🐱 give a clean peak. Assumes a steady (or slowly changing) flow.
    public var enabled = false
    /// 🐱 Live view memory in pairs (exponential average). Recordings sum every pair from start to stop.
    public var livePairs = 60
    /// 🐱 Highest ÷ second-highest correlation peak; below this the ensemble vector is invalid.
    public var minPeakRatio = 1.3
    /// 🐱 A window needs at least this many contributing pairs.
    public var minPairs = 5

    public init() {}
}

/// 🐱 Result of an ensemble correlation (full-frame px, on the per-pair PIV final-pass grid).
public struct EnsembleField: Sendable {
    /// 🐱 Displacement per pair; `dt` is the mean pair interval, so dx / dt is the velocity.
    public var field: PIVField
    /// 🐱 Peak ratio (detectability) per window.
    public var peakRatio: [Float]
    /// 🐱 Contributing pairs per window.
    public var pairs: [Int]
    /// 🐱 Pairs added in total.
    public var totalPairs: Int
    public var pairSpacing: Int

    public var validPercent: Double { 100 * Double(field.validCount) / Double(max(1, field.count)) }
}

/// 🐱 Ensemble correlation on the final-pass grid of `PIVEngine`.
/// 🐱
/// 🐱 Each window keeps the running average of its normalised correlation planes. For the planes of different pairs
/// 🐱 to add up coherently, every window uses a fixed integer offset (from the per-pair PIV, then re-centred on the
/// 🐱 ensemble result while not recording) and no sub-pixel window shifting; only the camera-shake displacement of
/// 🐱 each pair is applied (bilinear) to the second window, so camera shake does not smear the peak.
/// 🐱 Two accumulators: `live` (exponential, for the screen) and `session` (plain sum from recording start to stop).
public final class EnsembleCorrelator: @unchecked Sendable {
    public let window: Int
    public let step: Int
    public let pairSpacing: Int
    public let columns: Int
    public let rows: Int
    let width: Int, height: Int, originX: Int, originY: Int, scale: Int

    private let lock = NSLock()
    private let nn: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var live: [Float]
    private var liveCount: [Int32]
    private var liveAdded = 0
    private var liveDt = 0.0
    private var session: [Float] = []
    private var sessionCount: [Int32] = []
    private var sessionAdded = 0
    private var sessionDtSum = 0.0
    private var _sessionOwner: ObjectIdentifier?
    /// 🐱 integer window offsets, analysed px
    private var offX: [Int32]
    private var offY: [Int32]

    /// 🐱 `image`: any frame of the stream (geometry); `initial`: per-pair field (full-frame px) for the offsets.
    public init?(image: PIVImage, parameters p: PIVParameters, pairSpacing: Int, initial: PIVField?) {
        let w = PIVEngine.effectiveWindow(p.finalWindow)
        let st = max(1, Int((Double(w) * (1 - p.overlap)).rounded()))
        guard image.width >= w + 2, image.height >= w + 2 else { return nil }
        window = w
        step = st
        self.pairSpacing = pairSpacing
        columns = (image.width - w) / st + 1
        rows = (image.height - w) / st + 1
        width = image.width; height = image.height; originX = image.originX; originY = image.originY; scale = image.scale
        nn = w * w
        log2n = vDSP_Length(log2(Double(w)))
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        setup = s
        let n = columns * rows
        live = [Float](repeating: 0, count: n * nn)
        liveCount = [Int32](repeating: 0, count: n)
        offX = [Int32](repeating: 0, count: n)
        offY = [Int32](repeating: 0, count: n)
        if let f = initial, f.columns == columns, f.rows == rows {
            let inv = 1 / Double(scale)
            var k = 0
            while k < n {
                if f.isMeasured(k) {
                    offX[k] = Int32((f.dx[k] * inv).rounded())
                    offY[k] = Int32((f.dy[k] * inv).rounded())
                }
                k += 1
            }
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// 🐱 Same analysed geometry, window, step and pair spacing (otherwise a new correlator is needed).
    public func matches(image: PIVImage, parameters p: PIVParameters, pairSpacing k: Int) -> Bool {
        let w = PIVEngine.effectiveWindow(p.finalWindow)
        return image.width == width && image.height == height && image.originX == originX && image.originY == originY
            && image.scale == scale && w == window && max(1, Int((Double(w) * (1 - p.overlap)).rounded())) == step && k == pairSpacing
    }

    public var sessionOwner: ObjectIdentifier? { lock.withLock { _sessionOwner } }
    public var livePairs: Int { lock.withLock { liveAdded } }
    /// 🐱 Pairs summed in the running recording (0 when none).
    public var sessionPairs: Int { lock.withLock { _sessionOwner == nil ? 0 : sessionAdded } }

    /// 🐱 Start summing every pair (a recording). Window offsets stay fixed until the session ends.
    public func beginSession(owner: ObjectIdentifier) {
        lock.withLock {
            _sessionOwner = owner
            session = [Float](repeating: 0, count: columns * rows * nn)
            sessionCount = [Int32](repeating: 0, count: columns * rows)
            sessionAdded = 0
            sessionDtSum = 0
        }
    }

    /// 🐱 Ensemble over the whole session (nil if `owner` does not own it or nothing was added); frees the sum.
    public func endSession(owner: ObjectIdentifier, parameters p: PIVParameters) -> EnsembleField? {
        lock.withLock {
            defer {
                _sessionOwner = nil
                session = []
                sessionCount = []
            }
            guard _sessionOwner == owner, sessionAdded > 0 else { return nil }
            return result(planes: session, counts: sessionCount, added: sessionAdded, dt: sessionDtSum / Double(sessionAdded),
                          normaliseByCount: true, parameters: p, adaptOffsets: false)
        }
    }

    public func discardSession() {
        lock.withLock {
            _sessionOwner = nil
            session = []
            sessionCount = []
        }
    }

    /// 🐱 Add one pair. `shift(x, y)`: camera-motion displacement over the pair at an analysed-image point
    /// 🐱 (analysed px), applied to the second window; nil = none.
    public func add(a: PIVImage, b: PIVImage, dt: Double, parameters p: PIVParameters,
                    shift: ((Double, Double) -> (Double, Double))? = nil) {
        guard a.width == width, a.height == height, b.width == width, b.height == height, dt > 0 else { return }
        lock.withLock {
            let cols = columns, rows = rows, w = window, st = step, W = width, H = height, nn = nn
            let alpha = 1 / Float(max(1, p.ensemble.livePairs))
            let minContrast = p.minWindowContrast
            let sessionOn = _sessionOwner != nil && !session.isEmpty
            let setup = setup
            live.withUnsafeMutableBufferPointer { LPb in
                liveCount.withUnsafeMutableBufferPointer { LCb in
                    session.withUnsafeMutableBufferPointer { SPb in
                        sessionCount.withUnsafeMutableBufferPointer { SCb in
                            offX.withUnsafeBufferPointer { OXb in
                                offY.withUnsafeBufferPointer { OYb in
                                    a.pixels.withUnsafeBufferPointer { Ab in
                                        b.pixels.withUnsafeBufferPointer { Bb in
                                            let LP = LPb.baseAddress!, LC = LCb.baseAddress!, OX = OXb.baseAddress!, OY = OYb.baseAddress!
                                            let SP = SPb.baseAddress, SC = SCb.baseAddress
                                            let A = Ab.baseAddress!, B = Bb.baseAddress!
                                            DispatchQueue.concurrentPerform(iterations: rows) { j in
                                                var work = CorrelationWork(size: w)
                                                var i = 0
                                                while i < cols {
                                                    defer { i += 1 }
                                                    let k = j * cols + i
                                                    let ox = Int(OX[k]), oy = Int(OY[k])
                                                    // 🐱 A at an integer position (symmetric about the window), sliding inward at edges
                                                    guard let ax = Self.place(i * st - ox / 2, shift: ox, window: w, size: W),
                                                          let ay = Self.place(j * st - oy / 2, shift: oy, window: w, size: H) else { continue }
                                                    var sx = 0.0, sy = 0.0
                                                    if let shift {
                                                        let d = shift(Double(i * st) + Double(w) / 2, Double(j * st) + Double(w) / 2)
                                                        sx = d.0
                                                        sy = d.1
                                                    }
                                                    let bx = Double(ax + ox) + sx, by = Double(ay + oy) + sy
                                                    guard bx >= 0, by >= 0, bx <= Double(W - w - 1), by <= Double(H - w - 1) else { continue }
                                                    work.fill(A, W, x0: Double(ax), y0: Double(ay), into: true)
                                                    work.fill(B, W, x0: bx, y0: by, into: false)
                                                    guard work.correlationPlane(setup: setup, minContrast: minContrast) else { continue }
                                                    work.re.withUnsafeBufferPointer { R in
                                                        let plane = R.baseAddress!
                                                        let dst = LP + k * nn
                                                        let c = LC[k]
                                                        var wgt = 1 / Float(c + 1)
                                                        if wgt < alpha { wgt = alpha }
                                                        // 🐱 dst += wgt · (plane − dst)
                                                        vDSP_vintb(dst, 1, plane, 1, &wgt, dst, 1, vDSP_Length(nn))
                                                        LC[k] = c + 1
                                                        if sessionOn, let SP, let SC {
                                                            let sdst = SP + k * nn
                                                            vDSP_vadd(sdst, 1, plane, 1, sdst, 1, vDSP_Length(nn))
                                                            SC[k] += 1
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            liveAdded += 1
            liveDt = liveAdded == 1 ? dt : liveDt + Double(max(alpha, 1 / Float(liveAdded))) * (dt - liveDt)
            if sessionOn {
                sessionAdded += 1
                sessionDtSum += dt
            }
        }
    }

    /// 🐱 Current live ensemble field. With `adaptOffsets` (not during a recording), windows whose result has moved
    /// 🐱 two or more pixels from their offset are re-centred and restart their average.
    public func liveField(parameters p: PIVParameters, adaptOffsets: Bool) -> EnsembleField? {
        lock.withLock {
            guard liveAdded > 0 else { return nil }
            return result(planes: live, counts: liveCount, added: liveAdded, dt: liveDt, normaliseByCount: false,
                          parameters: p, adaptOffsets: adaptOffsets && _sessionOwner == nil)
        }
    }

    /// 🐱 Integer version of `PIVEngine.place`.
    private static func place(_ start: Int, shift: Int, window w: Int, size: Int) -> Int? {
        let span = size - w - 1
        let lo = max(0, -shift), hi = min(span, span - shift)
        guard lo <= hi else { return nil }
        return min(max(start, lo), hi)
    }

    /// 🐱 Peaks of all planes → validated field (lock held).
    private func result(planes: [Float], counts: [Int32], added: Int, dt: Double, normaliseByCount: Bool,
                        parameters p: PIVParameters, adaptOffsets: Bool) -> EnsembleField? {
        let cols = columns, rows = rows, n = cols * rows, w = window, nn = nn
        guard planes.count == n * nn, counts.count == n, dt > 0 else { return nil }
        var dx = [Double](repeating: 0, count: n), dy = dx
        var peakHeight = [Float](repeating: 0, count: n), ratio = peakHeight
        var status = [PIVField.Status](repeating: .invalid, count: n)
        let minPairs = Int32(max(1, p.ensemble.minPairs))
        let minRatio = Float(p.ensemble.minPeakRatio)
        let quarter = Double(w) / 4 + 1
        // 🐱 residual of the peak relative to the window offset (analysed px)
        var resX = [Double](repeating: 0, count: n), resY = resX
        planes.withUnsafeBufferPointer { Pb in
            counts.withUnsafeBufferPointer { Cb in
                offX.withUnsafeBufferPointer { OXb in
                    offY.withUnsafeBufferPointer { OYb in
                        dx.withUnsafeMutableBufferPointer { DXb in
                            dy.withUnsafeMutableBufferPointer { DYb in
                                peakHeight.withUnsafeMutableBufferPointer { Hb in
                                    ratio.withUnsafeMutableBufferPointer { Rb in
                                        status.withUnsafeMutableBufferPointer { Sb in
                                            resX.withUnsafeMutableBufferPointer { RXb in
                                                resY.withUnsafeMutableBufferPointer { RYb in
                                                    let P = Pb.baseAddress!, C = Cb.baseAddress!, OX = OXb.baseAddress!, OY = OYb.baseAddress!
                                                    let DX = DXb.baseAddress!, DY = DYb.baseAddress!, HT = Hb.baseAddress!, RT = Rb.baseAddress!
                                                    let ST = Sb.baseAddress!, RX = RXb.baseAddress!, RY = RYb.baseAddress!
                                                    DispatchQueue.concurrentPerform(iterations: rows) { j in
                                                        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: nn)
                                                        defer { scratch.deallocate() }
                                                        var i = 0
                                                        while i < cols {
                                                            defer { i += 1 }
                                                            let k = j * cols + i
                                                            let c = C[k]
                                                            guard c >= minPairs else { continue }
                                                            let pk = CorrelationWork.findPeak(P + k * nn, n: w, ratioScratch: scratch)
                                                            let h = normaliseByCount ? pk.height / Float(c) : pk.height
                                                            DX[k] = Double(OX[k]) + pk.dx
                                                            DY[k] = Double(OY[k]) + pk.dy
                                                            RX[k] = pk.dx
                                                            RY[k] = pk.dy
                                                            HT[k] = h
                                                            RT[k] = pk.ratio
                                                            if h > 0.02 && pk.ratio >= minRatio && abs(pk.dx) < quarter && abs(pk.dy) < quarter {
                                                                ST[k] = .valid
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if adaptOffsets {
            var k = 0
            while k < n {
                if status[k] == .valid && counts[k] >= max(minPairs, 10) {
                    let tx = Int32(dx[k].rounded()), ty = Int32(dy[k].rounded())
                    if abs(tx - offX[k]) >= 2 || abs(ty - offY[k]) >= 2 {
                        offX[k] = tx
                        offY[k] = ty
                        liveCount[k] = 0
                        // 🐱 restart this window's average (the old planes belong to the old offset)
                        live.withUnsafeMutableBufferPointer { vDSP_vclr($0.baseAddress! + k * nn, 1, vDSP_Length(nn)) }
                    }
                }
                k += 1
            }
        }
        var f = PIVField(columns: cols, rows: rows, originX: Double(w) / 2, originY: Double(w) / 2, step: Double(step), windowSize: w,
                         dx: dx, dy: dy, dt: dt, status: status, correlation: peakHeight)
        PIVEngine.validate(&f, threshold: p.validationThreshold, epsilon: p.validationEpsilonPx, replace: p.replaceInvalid)
        let image = PIVImage(width: width, height: self.height, originX: originX, originY: originY, scale: scale, pixels: [])
        return EnsembleField(field: PIVEngine.toFullFrame(f, image: image), peakRatio: ratio, pairs: counts.map { Int($0) },
                             totalPairs: added, pairSpacing: pairSpacing)
    }
}

extension PIVField {
    /// 🐱 As a field snapshot (velocities px/s) for display and heatmaps; replaced vectors are flagged as outliers.
    public func snapshot(time: Double, counts: [Int]? = nil) -> FieldSnapshot {
        let g = cellGrid
        var cells: [FieldCell] = []
        cells.reserveCapacity(count)
        let inv = dt > 0 ? 1 / dt : 0
        var k = 0
        while k < count {
            let st = status[k]
            cells.append(FieldCell(i: k % columns, j: k / columns, x: x(k), y: y(k), u: dx[k] * inv, v: dy[k] * inv, stdU: 0, stdV: 0,
                                   count: counts?[k] ?? (st == .valid ? 1 : 0), valid: st == .valid, outlier: st == .replaced))
            k += 1
        }
        return FieldSnapshot(time: time, cellSize: g.cellSize, columns: columns, rows: rows, originX: g.originX, originY: g.originY, cells: cells)
    }
}

extension EnsembleField {
    /// 🐱 As per-cell statistics on the PIV grid (velocities px/s, vorticity / divergence from the valid vectors),
    /// 🐱 so the session figures and tables can show the ensemble result. Fluctuation fields are 0: an ensemble
    /// 🐱 correlation measures the mean displacement only.
    public func cellStatistics() -> [CellStatistics] {
        let f = field
        let inv = f.dt > 0 ? 1 / f.dt : 0
        var u: [Double?] = [], v: [Double?] = []
        u.reserveCapacity(f.count)
        v.reserveCapacity(f.count)
        for k in 0..<f.count {
            let ok = f.status[k] == .valid
            u.append(ok ? f.dx[k] * inv : nil)
            v.append(ok ? f.dy[k] * inv : nil)
        }
        let d = FieldDerivatives.compute(columns: f.columns, rows: f.rows, spacing: f.step, u: u, v: v)
        return (0..<f.count).map { k in
            let uu = f.dx[k] * inv, vv = f.dy[k] * inv
            return CellStatistics(i: k % f.columns, j: k / f.columns, x: f.x(k), y: f.y(k), count: pairs[k], meanU: uu, meanV: vv,
                                  stdU: 0, stdV: 0, covUV: 0, meanSpeed: hypot(uu, vv), standardErrorU: 0, standardErrorV: 0,
                                  relativeUncertainty: nil, vorticity: d.vorticity[k], divergence: d.divergence[k], valid: f.status[k] == .valid)
        }
    }
}
