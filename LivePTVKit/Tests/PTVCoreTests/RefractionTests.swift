import Foundation
import Testing
@testable import PTVCore

/// 🐱 The ray tracer against independent closed-form optics, and the whole chain (images seen through a bottle →
/// 🐱 PIV → correction) against a known flow.
@Suite struct RefractionTests {
    /// 🐱 Independent 2-D reference for a parallel ray at lateral offset xp (mm) through a cylinder (outer ro, inner ri),
    /// 🐱 using angle bookkeeping instead of vectors: a ray inside a circle of radius r with incidence θ keeps the
    /// 🐱 perpendicular distance r·sin θ from the axis; each refraction turns it by (θin − θout) towards the axis.
    static func reference(_ xp: Double, ro: Double, ri: Double, nW: Double, nF: Double, p: Double) -> Double? {
        guard abs(xp) < ro else { return nil }
        let sgn: Double = xp < 0 ? -1 : 1
        let x = abs(xp)
        let th1 = asin(x / ro), th2 = asin(sin(th1) / nW)
        let s3 = ro * sin(th2) / ri
        guard s3 < 1 else { return nil }
        let th3 = asin(s3)
        let s4 = nW * sin(th3) / nF
        guard s4 < 1 else { return nil }
        let th4 = asin(s4)
        let alpha = (th1 - th2) + (th3 - th4)
        // 🐱 line m·q = ri·sin θ4 with m = (cos α, −sin α); at q.y = p
        return sgn * (ri * sin(th4) + p * sin(alpha)) / cos(alpha)
    }

    private func bottle(p: Double = 0, distance: Double? = nil, axis: ContainerGeometry.Axis = .vertical) -> ContainerGeometry {
        var g = ContainerGeometry()
        g.shape = .cylinder
        g.axis = axis
        // 🐱 600 px across the outer silhouette → 0.1 mm/px for a 60 mm bottle
        g.outline = axis == .vertical ? PixelROI(x: 100, y: 50, width: 600, height: 500) : PixelROI(x: 50, y: 100, width: 500, height: 600)
        g.frameWidth = 800
        g.frameHeight = 700
        g.outerDiameterMM = 60
        g.wallThicknessMM = 2
        g.wallIndex = 1.474
        g.fluidIndex = 1.333
        g.planeOffsetMM = p
        g.cameraDistanceMM = distance
        g.wallMarginMM = 0.5
        return g
    }

    @Test func cylinderMatchesClosedForm() throws {
        for p in [0.0, 6.0] {
            let map = try #require(RefractionMap(geometry: bottle(p: p), calibrationMMPerPixel: nil))
            let s0 = try #require(map.mmPerPixel)
            #expect(abs(s0 - 0.1) < 1e-9)
            let lc = 100 - 0.5 + 300.0
            var worst = 0.0, checked = 0
            for u in stride(from: 110.0, through: 690.0, by: 7.3) {
                let xp = (u - lc) * s0
                guard let ref = Self.reference(xp, ro: 30, ri: 28, nW: 1.474, nF: 1.333, p: p),
                      let m = map.map(x: u, y: 300) else { continue }
                worst = max(worst, abs((m.x - lc) * s0 - ref))
                #expect(abs(m.y - 300) < 1e-9)          // 🐱 parallel rays: nothing changes along the axis
                checked += 1
            }
            print(String(format: "REFRACTION p=%.0f mm: %d points, worst |ray tracer − closed form| = %.2e mm", p, checked, worst))
            #expect(checked > 60)
            #expect(worst < 0.005)
        }
    }

    @Test func centreMagnificationIsOneOverN() throws {
        // 🐱 thin wall: a filled bottle seen from far shrinks lateral distances by 1/n near its axis
        var g = bottle()
        g.wallThicknessMM = 0.01
        let map = try #require(RefractionMap(geometry: g, calibrationMMPerPixel: nil))
        let m = try #require(map.centreMagnification)
        print(String(format: "REFRACTION centre magnification %.4f (1/n = %.4f)", m, 1 / 1.333))
        #expect(abs(m - 1 / 1.333) < 0.002)
    }

    @Test func perspectiveAxialMagnificationMatchesParaxial() throws {
        // 🐱 along the axis the cylinder acts like a flat interface: Z = tanψ·(D − Ro + t/nW + Ri/nF)
        let map = try #require(RefractionMap(geometry: bottle(distance: 300), calibrationMMPerPixel: nil))
        let centre = 100 - 0.5 + 300.0
        let g = try #require(map.magnification(x: centre, y: 350))
        let inAir: Double = 300 - 30
        let inGlass: Double = 2 / 1.474
        let inWater: Double = 28 / 1.333
        let expected: Double = (inAir + inGlass + inWater) / 300
        print(String(format: "REFRACTION perspective axial magnification %.4f (paraxial %.4f), lateral %.4f", g.1, expected, g.0))
        #expect(abs(g.1 - expected) < 0.002)
        // 🐱 far camera → orthographic limit
        let far = try #require(RefractionMap(geometry: bottle(distance: 100_000), calibrationMMPerPixel: nil))
        let ortho = try #require(RefractionMap(geometry: bottle(), calibrationMMPerPixel: nil))
        let mFar = try #require(far.centreMagnification)
        let mOrtho = try #require(ortho.centreMagnification)
        #expect(abs(mFar - mOrtho) < 0.002)
    }

    @Test func horizontalAxisIsTheTransposedCase() throws {
        let v = try #require(RefractionMap(geometry: bottle(), calibrationMMPerPixel: nil))
        let h = try #require(RefractionMap(geometry: bottle(axis: .horizontal), calibrationMMPerPixel: nil))
        for a in stride(from: 120.0, through: 680.0, by: 40) {
            let mv = try #require(v.map(x: a, y: 300)), mh = try #require(h.map(x: 300, y: a))
            #expect(abs(mv.x - mh.y) < 1e-9 && abs(mh.x - 300) < 1e-9)
        }
    }

    @Test func flatTankCalibratedOnTheWall() throws {
        var g = ContainerGeometry()
        g.shape = .rectangular
        g.outline = PixelROI(x: 100, y: 80, width: 600, height: 440)
        g.frameWidth = 800
        g.frameHeight = 600
        g.wallThicknessMM = 5
        g.wallIndex = 1.49
        g.fluidIndex = 1.333
        g.planeOffsetMM = 50
        g.cameraDistanceMM = 500
        g.calibratedAtWall = true
        let map = try #require(RefractionMap(geometry: g, calibrationMMPerPixel: 0.1))
        let m = try #require(map.magnification(x: 400, y: 300))
        let wallTerm: Double = 5 / 1.49
        let fluidTerm: Double = 50 / 1.333
        let expected: Double = 1 + (wallTerm + fluidTerm) / 500
        print(String(format: "REFRACTION flat tank magnification %.4f (paraxial %.4f)", m.0, expected))
        #expect(abs(m.0 - expected) < 0.001 && abs(m.1 - expected) < 0.001)
        // 🐱 calibrated in the plane: identity mapping, only the wall band is masked
        g.calibratedAtWall = false
        let id = try #require(RefractionMap(geometry: g, calibrationMMPerPixel: 0.1))
        #expect(id.isIdentity)
        #expect(id.isUsable(x: 400, y: 300) && !id.isUsable(x: 102, y: 300))
    }

    @Test func inverseRoundTrip() throws {
        for geometry in [bottle(), bottle(p: 5, distance: 400)] {
            let map = try #require(RefractionMap(geometry: geometry, calibrationMMPerPixel: nil))
            for (x, y) in [(400.0, 300.0), (180.0, 120.0), (650.0, 500.0), (300.0, 420.0)] {
                let m = try #require(map.map(x: x, y: y))
                let back = try #require(map.inverse(x: m.x, y: m.y))
                #expect(hypot(back.x - x, back.y - y) < 1e-3)
            }
        }
    }

    /// 🐱 Particle images rendered as they appear through a 56 mm bottle (positions mapped by the inverse ray trace),
    /// 🐱 uniform flow in the measurement plane: uncorrected PIV is wrong by up to the lens factor, corrected PIV is not.
    @Test func uniformFlowSeenThroughABottle() throws {
        var g = ContainerGeometry()
        g.shape = .cylinder
        g.outline = PixelROI(x: 40, y: 20, width: 560, height: 440)
        g.frameWidth = 640
        g.frameHeight = 480
        g.outerDiameterMM = 56
        g.wallThicknessMM = 1.5
        g.wallMarginMM = 1
        let map = try #require(RefractionMap(geometry: g, calibrationMMPerPixel: nil))
        let truth = (1.6, 0.9)     // 🐱 true px per frame in the plane
        var rng = Synth(state: 77)
        // 🐱 tracers uniformly in the plane (true px), seen at their apparent positions
        var pts: [(Double, Double)] = []
        for _ in 0..<5200 { pts.append((40 + rng.unit() * 560, 20 + rng.unit() * 440)) }
        func frame(_ shift: (Double, Double), seed: UInt64) -> LumaImage {
            let apparent = pts.compactMap { p in map.inverse(x: p.0 + shift.0, y: p.1 + shift.1).map { ($0.x, $0.y) } }
            var r = Synth(state: seed)
            return Synth.render(apparent, w: 640, h: 480, sigma: 1.0, peak: 120, background: 15, noise: 2, rng: &r)
        }
        let a = frame((0, 0), seed: 1), b = frame(truth, seed: 2)
        let mask = try #require(StaticMask.build(width: 640, height: 480, originX: 0, originY: 0, scale: 1, exclusions: [], container: map))
        let engine = PIVEngine()
        let raw = try #require(engine.compute(a: engine.prepare(a, mask: mask), b: engine.prepare(b, mask: mask), dt: 1))
        var corrected = raw
        map.correct(&corrected)
        func errors(_ f: PIVField) -> (rms: Double, worst: Double, n: Int) {
            var se = 0.0, worst = 0.0, n = 0
            for k in 0..<f.count where f.status[k] == .valid {
                let e = hypot(f.dx[k] - truth.0, f.dy[k] - truth.1)
                se += e * e; worst = max(worst, e); n += 1
            }
            return (sqrt(se / Double(max(1, n))), worst, n)
        }
        let before = errors(raw), after = errors(corrected)
        let masked = corrected.maskedCount
        print(String(format: "BOTTLE uncorrected rms %.3f px (worst %.2f), corrected rms %.3f px (worst %.2f), %d valid, %d masked windows",
                     before.rms, before.worst, after.rms, after.worst, after.n, masked))
        #expect(before.rms > 0.3)            // 🐱 the lens effect is large
        #expect(after.rms < 0.08)
        #expect(after.n > corrected.count / 2)
        #expect(masked > 0)                  // 🐱 outside the fluid and the wall band
    }
}
