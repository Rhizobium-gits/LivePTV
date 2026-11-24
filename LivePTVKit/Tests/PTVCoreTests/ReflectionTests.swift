import Foundation
import Testing
@testable import PTVCore

/// 🐱 A bottle-like scene: a static reflection stripe on the glass, a saturated hot spot, and a moving glint (free-
/// 🐱 surface sparkle) over a uniform flow of tracers. Without corrections the static structures pull vectors towards
/// 🐱 zero and the glint drags them along; with background removal and the masks they do not.
@Suite struct ReflectionTests {
    static let (w, h) = (320, 240)
    static let flow = (2.4, 0.6)

    /// 🐱 Frame t of the scene (grey levels, clipped to 0…255 like a camera).
    static func frame(_ t: Int, tracers: [(Double, Double)], seed: UInt64) -> LumaImage {
        var noise = Synth(state: seed &+ UInt64(t) &* 7919)
        var img = [Float](repeating: 15, count: w * h)
        // 🐱 static stripe (reflection of a window on the glass) with soft edges, and a hot spot
        for y in 0..<h {
            for x in 0..<w {
                let d = abs(Double(x) - 157)
                let stripe = d < 14 ? 190.0 : d < 20 ? 190 * (20 - d) / 6 : 0
                let spot = hypot(Double(x) - 60, Double(y) - 60) < 10 ? 240.0 : 0
                img[y * w + x] += Float(stripe + spot)
            }
        }
        // 🐱 tracers move with the flow
        for p in tracers {
            let x = p.0 + flow.0 * Double(t), y = p.1 + flow.1 * Double(t)
            guard x > 3, y > 3, x < Double(w) - 4, y < Double(h) - 4 else { continue }
            for yy in Int(y) - 3...Int(y) + 4 {
                for xx in Int(x) - 3...Int(x) + 4 {
                    let ex = Double(xx) - x, ey = Double(yy) - y
                    img[yy * w + xx] += Float(90 * exp(-(ex * ex + ey * ey) / (2 * 0.9 * 0.9)))
                }
            }
        }
        // 🐱 moving saturated glint
        let gx = 280 - 4 * Double(t), gy = 170 + Double(t)
        for y in 0..<h { for x in 0..<w where hypot(Double(x) - gx, Double(y) - gy) < 7 { img[y * w + x] = 255 } }
        for i in img.indices { img[i] = min(255, max(0, (img[i] + Float(2 * noise.gauss())).rounded())) }
        return LumaImage(width: w, height: h, pixels: img)
    }

    @Test func reflectionsAndGlintsDoNotBiasTheFlow() throws {
        var rng = Synth(state: 5)
        // 🐱 tracers spread over the area the flow will cover during the sequence
        var tracers: [(Double, Double)] = []
        let spanX = Double(Self.w + 120), spanY = Double(Self.h + 40)
        for _ in 0..<2600 {
            let x: Double = rng.unit() * spanX - 120
            let y: Double = rng.unit() * spanY - 30
            tracers.append((x, y))
        }
        let frames = (0..<40).map { Self.frame($0, tracers: tracers, seed: 3) }
        var p = PIVParameters()
        p.replaceInvalid = false
        let engine = PIVEngine(parameters: p)
        let suppressor = ReflectionSuppressor()
        var corrected: [PIVImage] = []
        for f in frames {
            let r = suppressor.process(f, staticMask: nil)
            corrected.append(engine.prepare(r.image, mask: r.mask))
        }
        func score(_ fields: [PIVField]) -> (rms: Double, bad: Double, valid: Int, masked: Int) {
            var se = 0.0, bad = 0, n = 0, masked = 0
            for f in fields {
                for k in 0..<f.count {
                    if f.status[k] == .masked { masked += 1 }
                    guard f.status[k] == .valid else { continue }
                    let e = hypot(f.dx[k] - Self.flow.0, f.dy[k] - Self.flow.1)
                    se += e * e; n += 1
                    if e > 0.5 { bad += 1 }
                }
            }
            return ((se / Double(max(1, n))).squareRoot(), Double(bad) / Double(max(1, n)), n, masked)
        }
        // 🐱 pairs after the running mean's warm-up
        var raw: [PIVField] = [], fixed: [PIVField] = []
        for t in 32..<39 {
            raw.append(try #require(engine.compute(a: frames[t], b: frames[t + 1], dt: 1)))
            fixed.append(try #require(engine.compute(a: corrected[t], b: corrected[t + 1], dt: 1)))
        }
        let a = score(raw), b = score(fixed)
        let st = suppressor.lastStatistics
        print(String(format: "REFLECTION uncorrected: rms %.3f px, %.1f %% of valid vectors off by > 0.5 px (%d valid) | corrected: rms %.3f px, %.1f %% off (%d valid, %d masked) | masked image %.1f %% (glare %.1f, glints %.1f)",
                     a.rms, a.bad * 100, a.valid, b.rms, b.bad * 100, b.valid, b.masked, st.maskedPercent, st.glarePercent, st.saturatedPercent))
        // 🐱 measured (0.8, image deformation): uncorrected rms 0.170 px with 2.2 % of the valid vectors off by > 0.5 px
        // 🐱 (the median test already removes the worst); corrected rms 0.030 px, none off, 12 % of the image masked
        // 🐱 (glare 11.7 %, glint 1.4 %). Window shift (≤ 0.7): 0.158 / 0.024 px. Cells next to the masks must be filled
        // 🐱 before deforming (ImageDeformation.filledEverywhere): left at 0 they bent the field and gave 0.058 px.
        #expect(a.bad > 0.01)
        #expect(b.bad < 0.002)
        #expect(b.rms < 0.04)
        #expect(b.rms < a.rms / 4)
        #expect(st.glarePercent > 5 && st.saturatedPercent > 0.3)
    }

    @Test func staticMaskFromExclusions() throws {
        let m = try #require(StaticMask.build(width: 100, height: 80, originX: 10, originY: 20, scale: 2,
                                              exclusions: [PixelROI(x: 10, y: 20, width: 40, height: 40)], container: nil))
        // 🐱 analysed pixel (i, j) covers full-frame centre 10 + (i + 0.5)·2 − 0.5
        #expect(m[0] == 0 && m[19] == 0 && m[20] == 1)
        #expect(m[19 * 100] == 0 && m[20 * 100] == 1)
        #expect(StaticMask.build(width: 10, height: 10, originX: 0, originY: 0, scale: 1, exclusions: [], container: nil) == nil)
    }
}
