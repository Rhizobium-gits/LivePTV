import Foundation

/// 🐱 The transparent container the flow is seen through. A filled round bottle is a cylindrical lens: across its axis
/// 🐱 the fluid looks wider than it is (≈ n_fluid × near the axis for a distant camera) and increasingly stretched
/// 🐱 towards the walls, while along the axis nothing changes. A flat-walled tank shifts the apparent depth, so a
/// 🐱 calibration made on the outer wall (or in air) does not hold in the measurement plane. Both are corrected by
/// 🐱 tracing the camera ray of every image point through the walls (`RefractionMap`).
public struct ContainerGeometry: Codable, Equatable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, cylinder, rectangular
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .none: return "None (no container correction)"
            case .cylinder: return "Round bottle / tube (cylinder)"
            case .rectangular: return "Flat-walled tank / cuvette"
            }
        }
    }

    public enum Axis: String, Codable, CaseIterable, Sendable, Identifiable {
        case vertical, horizontal
        public var id: String { rawValue }
    }

    public var shape: Shape = .none
    /// 🐱 Direction of the cylinder axis in the image.
    public var axis: Axis = .vertical
    /// 🐱 Outline drawn on the image, full-frame px. Cylinder: the two sides parallel to the axis are the OUTER
    /// 🐱 silhouette of the bottle; the other two bound the usable fluid (below the free surface and meniscus, above
    /// 🐱 the bottom). Flat tank: the fluid region seen through the front wall.
    public var outline: PixelROI?
    /// 🐱 Frame size when the outline was drawn (the optical axis is taken through the frame centre).
    public var frameWidth = 0
    public var frameHeight = 0
    /// 🐱 Cylinder: outer diameter (mm). It also sets the length scale: mm per px = diameter ÷ silhouette width.
    public var outerDiameterMM = 60.0
    public var wallThicknessMM = 2.0
    /// 🐱 Refractive indices (589 nm): borosilicate glass 1.474, soda-lime 1.52, PMMA 1.49, PET 1.575, PS 1.59;
    /// 🐱 water 1.333 (20 °C), seawater 1.34, glycerol 1.473.
    public var wallIndex = 1.474
    public var fluidIndex = 1.333
    /// 🐱 Measurement plane: cylinder — offset from the axis towards the camera (mm; 0 = the plane through the axis,
    /// 🐱 the usual light-sheet position); flat tank — depth behind the inner face of the front wall (mm).
    public var planeOffsetMM = 0.0
    /// 🐱 Camera (entrance pupil) distance: cylinder — to the axis; flat tank — to the outer face of the front wall
    /// 🐱 (mm). Nil = distant camera (parallel rays), adequate when the distance is > ~10 × the container size.
    public var cameraDistanceMM: Double?
    /// 🐱 Band inside the inner wall that is excluded (mm): mirror images of tracers in the wall and the extreme
    /// 🐱 stretching right at the wall.
    public var wallMarginMM = 1.0
    public var correctRefraction = true
    /// 🐱 Flat tank: the mm/px calibration was made on the outer face of the front wall (or in air at that distance),
    /// 🐱 not in the measurement plane. Then the magnification of the plane is corrected (needs the camera distance).
    public var calibratedAtWall = false

    public init() {}

    public var isConfigured: Bool {
        guard shape != .none, let o = outline else { return false }
        return o.width > 4 && o.height > 4
    }
}

/// 🐱 Apparent image position (full-frame px) → position in the measurement plane, expressed in "true pixels":
/// 🐱 multiplied by `mmPerPixel` they are millimetres, so everything downstream keeps working in pixel units.
/// 🐱
/// 🐱 Each camera ray is traced in 3-D with Snell's law in vector form, t = η·d + (η·cos θᵢ − √(1 − η²·sin²θᵢ))·n,
/// 🐱 through air → wall → fluid, to its intersection with the measurement plane. The result is tabulated (lookup
/// 🐱 table, bilinear interpolation). Displacements are corrected by mapping both ends of every vector, so velocity
/// 🐱 magnitude and direction come out in the plane's true geometry; the session-averaged field is finally resampled on
/// 🐱 a regular grid in true coordinates (`rectify`).
public final class RefractionMap: @unchecked Sendable {
    public let geometry: ContainerGeometry
    /// 🐱 mm per true pixel (cylinder: from the silhouette; flat tank: the calibration). Nil = uncalibrated.
    public let mmPerPixel: Double?
    /// 🐱 Mapping is the identity (no correction): only the usable region (masks) applies.
    public let isIdentity: Bool
    /// 🐱 d(true)/d(apparent) across the container at its centre (≈ 1/n_fluid for a thin-walled bottle seen from far).
    public private(set) var centreMagnification: Double?

    private enum Kind { case identity, separable, general }
    private let kind: Kind
    private let vertical: Bool
    // 🐱 usable region in apparent px for the identity case
    private let box: (x0: Double, y0: Double, x1: Double, y1: Double)
    // 🐱 axial bounds (apparent px) for the separable case
    private let axialBounds: (Double, Double)
    // 🐱 lookup table: separable → 1-D over the lateral coordinate; general → 2-D grid
    private let lx0: Double, ly0: Double, lstep: Double
    private let lcols: Int, lrows: Int
    private var lu: [Double] = [], lv: [Double] = []
    private var lok: [UInt8] = [], luse: [UInt8] = []

    /// 🐱 Reference scale of a configured cylinder (mm per px), or nil.
    public static func cylinderScale(_ g: ContainerGeometry) -> Double? {
        guard g.shape == .cylinder, g.isConfigured, let o = g.outline else { return nil }
        let wpx = Double(g.axis == .vertical ? o.width : o.height)
        let ro = g.outerDiameterMM / 2
        guard wpx > 4, ro > 0 else { return nil }
        if let d = g.cameraDistanceMM, d > ro * 1.05 {
            let tanA = ro / (d * d - ro * ro).squareRoot()
            let f = (wpx / 2) / tanA
            return d / f
        }
        return 2 * ro / wpx
    }

    /// 🐱 Nil when no container is configured. `calibrationMMPerPixel`: the analysis calibration (used by flat tanks).
    public init?(geometry g: ContainerGeometry, calibrationMMPerPixel: Double?) {
        guard g.isConfigured, let o = g.outline else { return nil }
        geometry = g
        vertical = g.axis == .vertical
        let ox0 = Double(o.x) - 0.5, oy0 = Double(o.y) - 0.5
        let ox1 = Double(o.x + o.width) - 0.5, oy1 = Double(o.y + o.height) - 0.5

        switch g.shape {
        case .none:
            return nil
        case .rectangular:
            let s = calibrationMMPerPixel
            mmPerPixel = s
            let marginPx = s.map { g.wallMarginMM / $0 } ?? 4
            box = (ox0 + marginPx, oy0 + marginPx, ox1 - marginPx, oy1 - marginPx)
            axialBounds = (0, 0)
            let correct = g.correctRefraction && g.calibratedAtWall && s != nil && (g.cameraDistanceMM ?? 0) > 0
            if !correct {
                kind = .identity
                isIdentity = true
                lx0 = 0; ly0 = 0; lstep = 1; lcols = 0; lrows = 0
                centreMagnification = 1
                return
            }
            kind = .general
            isIdentity = false
            let sw = s!, L = g.cameraDistanceMM!
            let cx = g.frameWidth > 0 ? Double(g.frameWidth) / 2 : (ox0 + ox1) / 2
            let cy = g.frameHeight > 0 ? Double(g.frameHeight) / 2 : (oy0 + oy1) / 2
            let f = L / sw
            let t = max(0, g.wallThicknessMM), dp = max(0, g.planeOffsetMM)
            let nW = g.wallIndex, nF = g.fluidIndex
            let b = box
            let trace: (Double, Double) -> (Double, Double, Bool)? = { x, y in
                let d0 = Ray.normalize(SIMD3((x - cx) / f, (y - cy) / f, 1))
                let n = SIMD3<Double>(0, 0, -1)
                var p = d0 * (L / d0.z)
                guard let d1 = Ray.refract(d0, normal: n, from: 1, to: nW) else { return nil }
                p += d1 * (t / d1.z)
                guard let d2 = Ray.refract(d1, normal: n, from: nW, to: nF) else { return nil }
                p += d2 * (dp / d2.z)
                return (cx + p.x / sw, cy + p.y / sw, x >= b.x0 && x <= b.x1 && y >= b.y0 && y <= b.y1)
            }
            let span = max(ox1 - ox0, oy1 - oy0)
            lstep = max(2, (span / 160).rounded())
            lx0 = ox0 - 2 * lstep; ly0 = oy0 - 2 * lstep
            lcols = Int(((ox1 - ox0) / lstep).rounded(.up)) + 5
            lrows = Int(((oy1 - oy0) / lstep).rounded(.up)) + 5
            buildGeneral(trace)
            centreMagnification = magnification(x: (ox0 + ox1) / 2, y: (oy0 + oy1) / 2)?.0

        case .cylinder:
            guard let s0 = Self.cylinderScale(g) else { return nil }
            mmPerPixel = s0
            box = (ox0, oy0, ox1, oy1)
            let lat0 = vertical ? ox0 : oy0, lat1 = vertical ? ox1 : oy1
            let ax0 = vertical ? oy0 : ox0, ax1 = vertical ? oy1 : ox1
            axialBounds = (ax0, ax1)
            let lc = (lat0 + lat1) / 2
            let ro = g.outerDiameterMM / 2, ri = ro - g.wallThicknessMM
            guard ri > 0 else { return nil }
            let p = g.planeOffsetMM
            guard abs(p) < ri else { return nil }
            let halfChord = (ri * ri - p * p).squareRoot()
            let nW = g.wallIndex, nF = g.fluidIndex
            let margin = max(0, g.wallMarginMM)
            let frameAxial = Double(vertical ? g.frameHeight : g.frameWidth)
            let ac = frameAxial > 0 ? frameAxial / 2 : (ax0 + ax1) / 2
            let perspective = (g.cameraDistanceMM ?? 0) > ro * 1.05
            let D = g.cameraDistanceMM ?? 0
            let f = perspective ? D / s0 : 0
            let correct = g.correctRefraction
            // 🐱 (lateral, axial) apparent → (lateral, axial) true px, and whether the point is usable
            let trace: (Double, Double) -> (Double, Double, Bool)? = { l, a in
                let origin: SIMD3<Double>, dir0: SIMD3<Double>
                if perspective {
                    origin = SIMD3(0, D, 0)
                    dir0 = Ray.normalize(SIMD3((l - lc) / f, -1, (a - ac) / f))
                } else {
                    origin = SIMD3((l - lc) * s0, ro + 1, (a - ac) * s0)
                    dir0 = SIMD3(0, -1, 0)
                }
                guard let t1 = Ray.cylinderHit(origin, dir0, radius: ro) else { return nil }
                let q: SIMD3<Double>
                if correct {
                    var pos = origin + dir0 * t1
                    guard let d1 = Ray.refract(dir0, normal: SIMD3(pos.x, pos.y, 0) / ro, from: 1, to: nW) else { return nil }
                    guard let t2 = Ray.cylinderHit(pos, d1, radius: ri) else { return nil }   // 🐱 nil: the ray stays in the wall
                    pos += d1 * t2
                    guard let d2 = Ray.refract(d1, normal: SIMD3(pos.x, pos.y, 0) / ri, from: nW, to: nF) else { return nil }
                    guard d2.y < 0, pos.y >= p else { return nil }
                    q = pos + d2 * ((p - pos.y) / d2.y)
                } else {
                    // 🐱 refraction ignored: the straight ray to the plane (positions as seen; the wall band is still masked)
                    q = origin + dir0 * ((p - origin.y) / dir0.y)
                }
                guard q.x * q.x + p * p <= ri * ri else { return nil }
                let usable = abs(q.x) <= halfChord - margin && a >= ax0 && a <= ax1
                return (lc + q.x / s0, perspective ? ac + q.z / s0 : a, usable)
            }
            isIdentity = false
            let span = lat1 - lat0
            if perspective {
                kind = .general
                let span2 = max(span, ax1 - ax0)
                lstep = max(2, (span2 / 160).rounded())
                let x0 = (vertical ? lat0 : ax0) - 2 * lstep, y0 = (vertical ? ax0 : lat0) - 2 * lstep
                lx0 = x0; ly0 = y0
                lcols = Int(((vertical ? span : ax1 - ax0) / lstep).rounded(.up)) + 5
                lrows = Int(((vertical ? ax1 - ax0 : span) / lstep).rounded(.up)) + 5
                let v = vertical
                buildGeneral { x, y in
                    guard let r = v ? trace(x, y) : trace(y, x) else { return nil }
                    return v ? (r.0, r.1, r.2) : (r.1, r.0, r.2)
                }
            } else {
                kind = .separable
                // 🐱 parallel rays: the lateral mapping does not depend on the axial position → 1-D table
                lstep = max(0.25, (span / 2000))
                lx0 = lat0 - 2 * lstep; ly0 = 0
                lcols = Int((span / lstep).rounded(.up)) + 5
                lrows = 1
                lu = [Double](repeating: 0, count: lcols)
                lok = [UInt8](repeating: 0, count: lcols)
                luse = lok
                let amid = (ax0 + ax1) / 2
                var c = 0
                while c < lcols {
                    if let r = trace(lx0 + Double(c) * lstep, amid) {
                        lu[c] = r.0
                        lok[c] = 1
                        luse[c] = r.2 ? 1 : 0
                    }
                    c += 1
                }
            }
            let mid = (lat0 + lat1) / 2, am = (ax0 + ax1) / 2
            centreMagnification = vertical ? magnification(x: mid, y: am)?.0 : magnification(x: am, y: mid)?.1
        }
    }

    // 🐱 MARK: table

    /// 🐱 Fills the 2-D table: `trace(x, y)` → (true x, true y, usable) for apparent full-frame px.
    private func buildGeneral(_ trace: (Double, Double) -> (Double, Double, Bool)?) {
        let n = lcols * lrows
        lu = [Double](repeating: 0, count: n)
        lv = lu
        lok = [UInt8](repeating: 0, count: n)
        luse = lok
        var j = 0
        while j < lrows {
            var i = 0
            while i < lcols {
                let k = j * lcols + i
                if let r = trace(lx0 + Double(i) * lstep, ly0 + Double(j) * lstep) {
                    lu[k] = r.0
                    lv[k] = r.1
                    lok[k] = 1
                    luse[k] = r.2 ? 1 : 0
                }
                i += 1
            }
            j += 1
        }
    }

    // 🐱 MARK: mapping

    /// 🐱 Apparent full-frame px → true px (multiply by `mmPerPixel` for mm). Nil where the ray does not reach the
    /// 🐱 measurement plane inside the fluid.
    public func map(x: Double, y: Double) -> (x: Double, y: Double)? {
        switch kind {
        case .identity:
            return (x, y)
        case .separable:
            let l = vertical ? x : y
            guard let m = interp1D(l) else { return nil }
            return vertical ? (m, y) : (x, m)
        case .general:
            return interp2D(x, y)
        }
    }

    /// 🐱 Inside the fluid, outside the wall band, within the outline.
    public func isUsable(x: Double, y: Double) -> Bool {
        switch kind {
        case .identity:
            return x >= box.x0 && x <= box.x1 && y >= box.y0 && y <= box.y1
        case .separable:
            let l = vertical ? x : y, a = vertical ? y : x
            guard a >= axialBounds.0, a <= axialBounds.1 else { return false }
            let f = (l - lx0) / lstep
            let i0 = Int(floor(f))
            guard i0 >= 0, i0 + 1 < lcols else { return false }
            return luse[i0] == 1 && luse[i0 + 1] == 1
        case .general:
            let fx = (x - lx0) / lstep, fy = (y - ly0) / lstep
            let i0 = Int(floor(fx)), j0 = Int(floor(fy))
            guard i0 >= 0, j0 >= 0, i0 + 1 < lcols, j0 + 1 < lrows else { return false }
            let k = j0 * lcols + i0
            return luse[k] == 1 && luse[k + 1] == 1 && luse[k + lcols] == 1 && luse[k + lcols + 1] == 1
        }
    }

    private func interp1D(_ l: Double) -> Double? {
        let f = (l - lx0) / lstep
        let i0 = Int(floor(f))
        guard i0 >= 0, i0 + 1 < lcols, lok[i0] == 1, lok[i0 + 1] == 1 else { return nil }
        let t = f - Double(i0)
        return lu[i0] * (1 - t) + lu[i0 + 1] * t
    }

    private func interp2D(_ x: Double, _ y: Double) -> (x: Double, y: Double)? {
        let fx = (x - lx0) / lstep, fy = (y - ly0) / lstep
        let i0 = Int(floor(fx)), j0 = Int(floor(fy))
        guard i0 >= 0, j0 >= 0, i0 + 1 < lcols, j0 + 1 < lrows else { return nil }
        let k = j0 * lcols + i0
        guard lok[k] == 1, lok[k + 1] == 1, lok[k + lcols] == 1, lok[k + lcols + 1] == 1 else { return nil }
        let tx = fx - Double(i0), ty = fy - Double(j0)
        func bl(_ a: [Double]) -> Double {
            (a[k] * (1 - tx) + a[k + 1] * tx) * (1 - ty) + (a[k + lcols] * (1 - tx) + a[k + lcols + 1] * tx) * ty
        }
        return (bl(lu), bl(lv))
    }

    /// 🐱 Local magnifications ∂X/∂x and ∂Y/∂y (true px per apparent px), central differences.
    public func magnification(x: Double, y: Double, h: Double = 0.5) -> (Double, Double)? {
        guard let xp = map(x: x + h, y: y), let xm = map(x: x - h, y: y),
              let yp = map(x: x, y: y + h), let ym = map(x: x, y: y - h) else { return nil }
        return ((xp.x - xm.x) / (2 * h), (yp.y - ym.y) / (2 * h))
    }

    /// 🐱 True px → apparent px (Newton iteration on the table; nil outside the mapped region).
    public func inverse(x tx: Double, y ty: Double) -> (x: Double, y: Double)? {
        if kind == .identity { return (tx, ty) }
        var px = tx, py = ty
        // 🐱 start from the outline centre when the identity guess is not mapped
        if map(x: px, y: py) == nil, let o = geometry.outline {
            px = Double(o.x) + Double(o.width) / 2
            py = Double(o.y) + Double(o.height) / 2
        }
        var it = 0
        while it < 40 {
            guard let m = map(x: px, y: py), let mx = map(x: px + 0.5, y: py), let my = map(x: px, y: py + 0.5) else { return nil }
            let ex = m.x - tx, ey = m.y - ty
            if abs(ex) < 1e-4 && abs(ey) < 1e-4 { return (px, py) }
            // 🐱 Jacobian by forward differences; solve J·δ = e
            let a = (mx.x - m.x) / 0.5, b = (my.x - m.x) / 0.5, c = (mx.y - m.y) / 0.5, d = (my.y - m.y) / 0.5
            let det = a * d - b * c
            guard abs(det) > 1e-12 else { return nil }
            var dx = (d * ex - b * ey) / det, dy = (a * ey - c * ex) / det
            // 🐱 damped: never jump more than 50 px, and back off if the step leaves the mapped region
            let len = hypot(dx, dy)
            if len > 50 { dx *= 50 / len; dy *= 50 / len }
            var tries = 0
            while map(x: px - dx, y: py - dy) == nil && tries < 8 { dx /= 2; dy /= 2; tries += 1 }
            px -= dx; py -= dy
            it += 1
        }
        if let m = map(x: px, y: py), abs(m.x - tx) < 1e-2, abs(m.y - ty) < 1e-2 { return (px, py) }
        return nil
    }

    // 🐱 MARK: correcting measurements

    /// 🐱 Map both ends of every measured vector (apparent px) into the plane: dx, dy become true displacements, σ is
    /// 🐱 scaled by the local magnification. Vectors whose centre or ends are not usable become `masked`.
    /// 🐱 Positions stay apparent (for drawing on the camera image); see `rectify` for true positions.
    public func correct(_ f: inout PIVField) {
        guard !isIdentity else {
            var k = 0
            while k < f.count {
                if f.status[k] != .masked && !isUsable(x: f.x(k), y: f.y(k)) { f.status[k] = .masked; f.dx[k] = 0; f.dy[k] = 0 }
                k += 1
            }
            return
        }
        let hasSigma = f.sigmaX.count == f.count && f.sigmaY.count == f.count
        var k = 0
        while k < f.count {
            defer { k += 1 }
            guard f.status[k] != .masked else { continue }
            let x = f.x(k), y = f.y(k)
            guard isUsable(x: x, y: y) else { f.status[k] = .masked; f.dx[k] = 0; f.dy[k] = 0; continue }
            guard f.isMeasured(k) else { continue }
            guard let a = map(x: x - f.dx[k] / 2, y: y - f.dy[k] / 2), let b = map(x: x + f.dx[k] / 2, y: y + f.dy[k] / 2) else {
                f.status[k] = .masked; f.dx[k] = 0; f.dy[k] = 0; continue
            }
            f.dx[k] = b.x - a.x
            f.dy[k] = b.y - a.y
            if hasSigma, let m = magnification(x: x, y: y) {
                f.sigmaX[k] *= Float(abs(m.0))
                f.sigmaY[k] *= Float(abs(m.1))
            }
        }
    }

    /// 🐱 Same for Lagrangian samples (PTV); samples outside the usable fluid are dropped.
    public func correct(_ samples: [VelocitySample]) -> [VelocitySample] {
        var out: [VelocitySample] = []
        out.reserveCapacity(samples.count)
        for var s in samples {
            guard isUsable(x: s.x, y: s.y) else { continue }
            if !isIdentity {
                guard let a = map(x: s.x - s.dx / 2, y: s.y - s.dy / 2), let b = map(x: s.x + s.dx / 2, y: s.y + s.dy / 2) else { continue }
                s.dx = b.x - a.x
                s.dy = b.y - a.y
                if s.dt > 0 { s.u = s.dx / s.dt; s.v = s.dy / s.dt }
                if let sg = s.sigma, let m = magnification(x: s.x, y: s.y) { s.sigma = sg * ((m.0 * m.0 + m.1 * m.1) / 2).squareRoot() }
            }
            out.append(s)
        }
        return out
    }

    /// 🐱 Resample session statistics (cells on an apparent grid, velocities already corrected) onto a regular grid
    /// 🐱 in true coordinates with the same cell size; vorticity and divergence are recomputed there. Nil if nothing
    /// 🐱 maps (or the mapping is the identity, where the input is already correct).
    public func rectify(cells: [CellStatistics], grid: GridGeometry) -> (cells: [CellStatistics], grid: GridGeometry)? {
        guard !isIdentity, cells.count == grid.count else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for c in cells where c.valid {
            guard let m = map(x: c.x, y: c.y) else { continue }
            minX = min(minX, m.x); maxX = max(maxX, m.x); minY = min(minY, m.y); maxY = max(maxY, m.y)
        }
        guard minX.isFinite, maxX > minX || maxY > minY else { return nil }
        let h = grid.cellSize
        let cols = max(1, Int(((maxX - minX) / h).rounded()) + 1), rows = max(1, Int(((maxY - minY) / h).rounded()) + 1)
        let out = GridGeometry(originX: minX - h / 2, originY: minY - h / 2, cellSize: h, columns: cols, rows: rows)
        var result: [CellStatistics] = []
        result.reserveCapacity(out.count)
        for k in 0..<out.count {
            let c = out.center(k)
            var cell = CellStatistics(i: k % cols, j: k / cols, x: c.x, y: c.y, count: 0, meanU: 0, meanV: 0, stdU: 0, stdV: 0, covUV: 0,
                                      meanSpeed: 0, standardErrorU: 0, standardErrorV: 0, relativeUncertainty: nil,
                                      vorticity: nil, divergence: nil, valid: false)
            if let a = inverse(x: c.x, y: c.y), let s = Self.interpolate(cells, grid: grid, x: a.x, y: a.y) {
                cell.count = s.count
                cell.meanU = s.meanU; cell.meanV = s.meanV
                cell.stdU = s.stdU; cell.stdV = s.stdV; cell.covUV = s.covUV
                cell.meanSpeed = s.meanSpeed
                cell.standardErrorU = s.standardErrorU; cell.standardErrorV = s.standardErrorV
                cell.measurementUncertainty = s.measurementUncertainty
                let se = hypot(cell.standardErrorU, cell.standardErrorV)
                cell.relativeUncertainty = cell.speedOfMean > 1e-9 ? se / cell.speedOfMean : nil
                cell.valid = true
            }
            result.append(cell)
        }
        let u = result.map { $0.valid ? Optional($0.meanU) : nil }
        let v = result.map { $0.valid ? Optional($0.meanV) : nil }
        let d = FieldDerivatives.compute(columns: cols, rows: rows, spacing: h, u: u, v: v)
        for k in result.indices {
            result[k].vorticity = d.vorticity[k]
            result[k].divergence = d.divergence[k]
        }
        return (result, out)
    }

    /// 🐱 Bilinear interpolation between valid cell centres; nil unless the nearest cell is valid and the valid
    /// 🐱 neighbours carry at least 75 % of the weight.
    static func interpolate(_ cells: [CellStatistics], grid g: GridGeometry, x: Double, y: Double) -> CellStatistics? {
        let fx = (x - g.originX) / g.cellSize - 0.5, fy = (y - g.originY) / g.cellSize - 0.5
        guard fx >= -0.5, fy >= -0.5, fx <= Double(g.columns) - 0.5, fy <= Double(g.rows) - 0.5 else { return nil }
        let ni = min(g.columns - 1, max(0, Int(fx.rounded()))), nj = min(g.rows - 1, max(0, Int(fy.rounded())))
        guard cells[nj * g.columns + ni].valid else { return nil }
        let cx = max(0, min(Double(g.columns - 1), fx)), cy = max(0, min(Double(g.rows - 1), fy))
        let i0 = Int(cx), j0 = Int(cy), i1 = min(g.columns - 1, i0 + 1), j1 = min(g.rows - 1, j0 + 1)
        let tx = cx - Double(i0), ty = cy - Double(j0)
        var w = 0.0
        var acc = [Double](repeating: 0, count: 11)
        var count = 0.0
        var sigmaW = 0.0
        for (i, j, wt) in [(i0, j0, (1 - tx) * (1 - ty)), (i1, j0, tx * (1 - ty)), (i0, j1, (1 - tx) * ty), (i1, j1, tx * ty)] where wt > 0 {
            let c = cells[j * g.columns + i]
            guard c.valid else { continue }
            let vals: [Double] = [c.meanU, c.meanV, c.stdU, c.stdV, c.covUV, c.meanSpeed, c.standardErrorU, c.standardErrorV, 0, 0, c.measurementUncertainty ?? 0]
            for q in 0..<vals.count { acc[q] += wt * vals[q] }
            if c.measurementUncertainty != nil { sigmaW += wt }
            count += wt * Double(c.count)
            w += wt
        }
        guard w >= 0.75 else { return nil }
        var out = cells[nj * g.columns + ni]
        out.meanU = acc[0] / w; out.meanV = acc[1] / w
        out.stdU = acc[2] / w; out.stdV = acc[3] / w; out.covUV = acc[4] / w
        out.meanSpeed = acc[5] / w
        out.standardErrorU = acc[6] / w; out.standardErrorV = acc[7] / w
        out.measurementUncertainty = sigmaW > 0 ? acc[10] / sigmaW : nil
        out.count = Int((count / w).rounded())
        return out
    }

    // 🐱 MARK: geometry for drawing and reports

    /// 🐱 Apparent lateral positions (full-frame px) where the usable fluid begins and ends (inner wall + margin),
    /// 🐱 across the axis at the outline centre; nil for flat tanks.
    public var usableLateralRange: (Double, Double)? {
        guard geometry.shape == .cylinder, let o = geometry.outline else { return nil }
        let am = vertical ? Double(o.y) + Double(o.height) / 2 : Double(o.x) + Double(o.width) / 2
        let l0 = Double(vertical ? o.x : o.y), l1 = l0 + Double(vertical ? o.width : o.height)
        var first: Double?, last: Double?
        var l = l0
        while l <= l1 {
            if vertical ? isUsable(x: l, y: am) : isUsable(x: am, y: l) {
                if first == nil { first = l }
                last = l
            }
            l += 0.5
        }
        guard let first, let last else { return nil }
        return (first, last)
    }

    /// 🐱 Lateral profile across the container at the outline centre: apparent px, true position (mm or px from the
    /// 🐱 axis) and local lateral magnification, for the quality figure.
    public func lateralProfile(samples: Int = 120) -> [(apparent: Double, truePosition: Double, magnification: Double)] {
        guard let o = geometry.outline else { return [] }
        let am = vertical ? Double(o.y) + Double(o.height) / 2 : Double(o.x) + Double(o.width) / 2
        let l0 = Double(vertical ? o.x : o.y), l1 = l0 + Double(vertical ? o.width : o.height)
        let lc = (l0 + l1) / 2
        let scale = mmPerPixel ?? 1
        var out: [(Double, Double, Double)] = []
        for k in 0...samples {
            let l = l0 + (l1 - l0) * Double(k) / Double(samples)
            let p = vertical ? (l, am) : (am, l)
            guard isUsable(x: p.0, y: p.1), let m = map(x: p.0, y: p.1), let g = magnification(x: p.0, y: p.1) else { continue }
            let t = (vertical ? m.x : m.y) - lc
            out.append((l, t * scale, vertical ? g.0 : g.1))
        }
        return out
    }

    /// 🐱 One-line description for reports.
    public var summary: String {
        let g = geometry
        switch g.shape {
        case .none: return "none"
        case .cylinder:
            let cam = g.cameraDistanceMM.map { String(format: "camera %.0f mm from the axis", $0) } ?? "distant camera"
            return String(format: "cylinder ⌀%.1f mm, wall %.2f mm (n=%.3f), fluid n=%.3f, plane %+.1f mm from the axis, %@; refraction %@; lateral magnification at the centre %.3f",
                          g.outerDiameterMM, g.wallThicknessMM, g.wallIndex, g.fluidIndex, g.planeOffsetMM, cam,
                          g.correctRefraction ? "corrected" : "NOT corrected", centreMagnification ?? .nan)
        case .rectangular:
            if isIdentity { return "flat-walled tank; calibrated in the measurement plane (no refraction correction needed); wall band masked" }
            return String(format: "flat-walled tank, wall %.2f mm (n=%.3f), fluid n=%.3f, plane %.1f mm behind the wall, camera %.0f mm from the wall; calibration on the wall corrected to the plane (magnification %.4f)",
                          g.wallThicknessMM, g.wallIndex, g.fluidIndex, g.planeOffsetMM, g.cameraDistanceMM ?? 0, centreMagnification ?? .nan)
        }
    }
}

/// 🐱 Vector helpers for the ray tracer.
enum Ray {
    static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = (v * v).sum().squareRoot()
        return l > 0 ? v / l : v
    }

    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

    /// 🐱 Snell's law in vector form; `normal` may point either way. Nil on total internal reflection.
    static func refract(_ d: SIMD3<Double>, normal: SIMD3<Double>, from n1: Double, to n2: Double) -> SIMD3<Double>? {
        var n = normalize(normal)
        var cosi = -dot(n, d)
        if cosi < 0 { n = -n; cosi = -cosi }
        let eta = n1 / n2
        let k = 1 - eta * eta * (1 - cosi * cosi)
        guard k >= 0 else { return nil }
        return normalize(d * eta + n * (eta * cosi - k.squareRoot()))
    }

    /// 🐱 Nearest positive intersection of the ray with the infinite cylinder x² + y² = r² (axis along z).
    static func cylinderHit(_ p: SIMD3<Double>, _ d: SIMD3<Double>, radius r: Double) -> Double? {
        let a = d.x * d.x + d.y * d.y
        guard a > 1e-15 else { return nil }
        let b = 2 * (p.x * d.x + p.y * d.y)
        let c = p.x * p.x + p.y * p.y - r * r
        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return nil }
        let s = disc.squareRoot()
        let t0 = (-b - s) / (2 * a), t1 = (-b + s) / (2 * a)
        if t0 > 1e-9 { return t0 }
        if t1 > 1e-9 { return t1 }
        return nil
    }
}
