import Foundation
import Testing
@testable import PTVCore

@Suite struct PIVTests {
    /// 🐱 Dense random particle field (PIV seeding: ~10 particles per 32×32 window).
    private func particles(_ n: Int, w: Int, h: Int, seed: UInt64) -> [(Double, Double)] {
        var rng = Synth(state: seed)
        return (0..<n).map { _ in (rng.unit() * Double(w + 40) - 20, rng.unit() * Double(h + 40) - 20) }
    }

    private func render(_ p: [(Double, Double)], _ w: Int, _ h: Int, seed: UInt64) -> LumaImage {
        var rng = Synth(state: seed)
        let W = Double(w), H = Double(h)
        // 🐱 keep only particles whose image overlaps the frame (Synth.render needs in-frame centres)
        let inside: [(Double, Double)] = p.filter { q in q.0 >= 0 && q.1 >= 0 && q.0 <= W - 1 && q.1 <= H - 1 }
        return Synth.render(inside, w: w, h: h, sigma: 1.0, peak: 160, background: 10, noise: 2, rng: &rng)
    }

    @Test func uniformSubpixelShift() throws {
        let (w, h) = (256, 192)
        let p = particles(Int(Double(w * h) / 100), w: w, h: h, seed: 1)
        let a = render(p, w, h, seed: 2)
        let b = render(p.map { ($0.0 + 3.3, $0.1 - 1.7) }, w, h, seed: 3)
        let f = try #require(PIVEngine().compute(a: a, b: b, dt: 1.0 / 30))
        #expect(f.windowSize == 32 && f.step == 16)
        #expect(Double(f.validCount) / Double(f.count) > 0.95)
        let idx: [Int] = (0..<f.count).filter { f.status[$0] == .valid }
        let ex: [Double] = idx.map { f.dx[$0] - 3.3 }
        let ey: [Double] = idx.map { f.dy[$0] + 1.7 }
        var sq = 0.0
        for k in ex.indices { sq += ex[k] * ex[k] + ey[k] * ey[k] }
        let rms = sqrt(sq / Double(idx.count))
        #expect(rms < 0.1)
        #expect(abs(ex.reduce(0, +) / Double(ex.count)) < 0.05)   // 🐱 sign convention and no bias
        #expect(f.correlation.max()! > 0.5)
    }

    @Test func largeShiftNeedsMultiPass() throws {
        let (w, h) = (320, 256)
        let p = particles(Int(Double(w * h) / 100), w: w, h: h, seed: 4)
        let a = render(p, w, h, seed: 5)
        let b = render(p.map { ($0.0 + 12.4, $0.1 + 5.2) }, w, h, seed: 6)
        // 🐱 32-px single pass: 12.4 px is beyond the quarter-window rule and mostly fails
        var single = PIVParameters(); single.windowSizes = [32]
        let fs = try #require(PIVEngine(parameters: single).compute(a: a, b: b, dt: 1))
        let goodSingle = (0..<fs.count).filter { fs.status[$0] == .valid && abs(fs.dx[$0] - 12.4) < 0.5 }.count
        // 🐱 64 → 32 with window offset recovers it
        let f = try #require(PIVEngine().compute(a: a, b: b, dt: 1))
        let good = (0..<f.count).filter { f.status[$0] == .valid && abs(f.dx[$0] - 12.4) < 0.3 && abs(f.dy[$0] - 5.2) < 0.3 }.count
        #expect(Double(good) / Double(f.count) > 0.85)
        #expect(good > goodSingle)
    }

    @Test func rotationFieldMatchesAnalytic() throws {
        let (w, h) = (320, 320)
        let omega = 0.03   // 🐱 rad per frame → up to ~4.8 px at the corners of the inner region
        let p = particles(Int(Double(w * h) / 90), w: w, h: h, seed: 7)
        let a = render(p, w, h, seed: 8)
        let moved = p.map { q -> (Double, Double) in
            let x = q.0 - 160, y = q.1 - 160
            return (160 + x * cos(omega) - y * sin(omega), 160 + x * sin(omega) + y * cos(omega))
        }
        let b = render(moved, w, h, seed: 9)
        let f = try #require(PIVEngine().compute(a: a, b: b, dt: 1))
        var se = 0.0, n = 0
        for k in 0..<f.count where f.status[k] == .valid {
            let x = f.x(k) - 160, y = f.y(k) - 160
            let tx = x * cos(omega) - y * sin(omega) - x, ty = x * sin(omega) + y * cos(omega) - y
            se += (f.dx[k] - tx) * (f.dx[k] - tx) + (f.dy[k] - ty) * (f.dy[k] - ty)
            n += 1
        }
        let notValid = (0..<f.count).filter { f.status[$0] != .valid }
        let interior = notValid.filter { f.x($0) > 40 && f.x($0) < 280 && f.y($0) > 40 && f.y($0) < 280 }
        // 🐱 Rejections only where particles enter/leave the frame (loss of pairs), never in the interior.
        #expect(interior.isEmpty)
        #expect(n > Int(Double(f.count) * 0.85))
        #expect(sqrt(se / Double(n)) < 0.2)
    }

    @Test func boxBlurMatchesNaiveReference() {
        let (w, h, r) = (23, 17, 3)
        var rng = Synth(state: 77)
        let img = (0..<(w * h)).map { _ in Float(rng.unit() * 255) }
        let fast = PIVEngine.boxBlur(img, w, h, radius: r)
        func at(_ x: Int, _ y: Int) -> Float { img[min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))] }
        var worst: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                // 🐱 separable box with replicated edges = mean over the clamped (2r+1)² neighbourhood
                var s: Float = 0
                for dy in -r...r { for dx in -r...r { s += at(x + dx, y + dy) } }
                worst = max(worst, abs(s / Float((2 * r + 1) * (2 * r + 1)) - fast[y * w + x]))
            }
        }
        #expect(worst < 1e-3)
    }

    @Test func emptyRegionIsFlaggedNotInvented() throws {
        let (w, h) = (256, 128)
        // 🐱 particles only in the left half: right-half windows have no pattern
        let p = particles(400, w: w / 2 - 20, h: h, seed: 10)
        let a = render(p, w, h, seed: 11)
        let b = render(p.map { ($0.0 + 2, $0.1) }, w, h, seed: 12)
        var params = PIVParameters()
        params.replaceInvalid = false
        let f = try #require(PIVEngine(parameters: params).compute(a: a, b: b, dt: 1))
        let right = (0..<f.count).filter { f.x($0) > 200 }
        #expect(right.allSatisfy { f.status[$0] == .invalid })
    }
}
