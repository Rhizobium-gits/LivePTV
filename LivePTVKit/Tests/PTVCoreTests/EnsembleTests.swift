import Foundation
import Testing
@testable import PTVCore

/// 🐱 Ensemble correlation vs. averaging per-pair vectors, on faint, sparse, Brownian particle images
/// 🐱 (the micro-/nano-PIV situation it was invented for).
@Suite struct EnsembleTests {
    struct Pair { let a: PIVImage; let b: PIVImage; let camera: (Double, Double) }

    /// 🐱 Independent particle pattern per pair (the flow brings new particles), drift (u, v) px per pair,
    /// 🐱 Brownian steps σB per particle, optional random camera shift of frame b.
    private func pairs(_ count: Int, drift: (Double, Double), seeding: Int, brownian: Double, noise: Double, peak: Double,
                       cameraStd: Double = 0, engine: PIVEngine, seed: UInt64) -> [Pair] {
        let (w, h) = (256, 192)
        var rng = Synth(state: seed)
        var out: [Pair] = []
        for _ in 0..<count {
            let pts: [(Double, Double)] = (0..<(w * h / seeding)).map { _ in (rng.unit() * Double(w - 6) + 3, rng.unit() * Double(h - 6) + 3) }
            let cam = (cameraStd * rng.gauss(), cameraStd * rng.gauss())
            let moved: [(Double, Double)] = pts.map { p in
                (p.0 + drift.0 + brownian * rng.gauss() + cam.0, p.1 + drift.1 + brownian * rng.gauss() + cam.1)
            }.filter { $0.0 >= 0 && $0.1 >= 0 && $0.0 <= Double(w - 1) && $0.1 <= Double(h - 1) }
            let a = Synth.render(pts, w: w, h: h, sigma: 1.0, peak: peak, background: 10, noise: noise, rng: &rng)
            let b = Synth.render(moved, w: w, h: h, sigma: 1.0, peak: peak, background: 10, noise: noise, rng: &rng)
            out.append(Pair(a: engine.prepare(a), b: engine.prepare(b), camera: cam))
        }
        return out
    }

    private func rms(_ f: PIVField, _ drift: (Double, Double), inner: Bool = true) -> (rms: Double, valid: Double) {
        var se = 0.0, n = 0
        for k in 0..<f.count where f.status[k] == .valid {
            if inner && (f.x(k) < 40 || f.y(k) < 40 || f.x(k) > 216 || f.y(k) > 152) { continue }
            se += pow(f.dx[k] - drift.0, 2) + pow(f.dy[k] - drift.1, 2)
            n += 1
        }
        return (sqrt(se / Double(max(1, n))), Double(f.validCount) / Double(f.count))
    }

    @Test func ensembleBeatsVectorAveragingOnFaintBrownianParticles() throws {
        let engine = PIVEngine()
        let drift = (1.7, -0.8)
        let ps = pairs(40, drift: drift, seeding: 500, brownian: 0.6, noise: 9, peak: 45, engine: engine, seed: 7)

        // 🐱 (1) per-pair PIV, then average the valid vectors per window
        var sumX: [Double] = [], sumY: [Double] = [], cnt: [Int] = []
        var instValid = 0.0
        var template: PIVField?
        for p in ps {
            var q = engine.parameters
            q.replaceInvalid = false
            let e = PIVEngine(parameters: q)
            let f = try #require(e.compute(a: p.a, b: p.b, dt: 1))
            if template == nil {
                template = f
                sumX = .init(repeating: 0, count: f.count); sumY = sumX; cnt = .init(repeating: 0, count: f.count)
            }
            instValid += Double(f.validCount) / Double(f.count)
            for k in 0..<f.count where f.status[k] == .valid { sumX[k] += f.dx[k]; sumY[k] += f.dy[k]; cnt[k] += 1 }
        }
        var avg = try #require(template)
        for k in 0..<avg.count {
            avg.status[k] = cnt[k] > 0 ? .valid : .invalid
            avg.dx[k] = cnt[k] > 0 ? sumX[k] / Double(cnt[k]) : 0
            avg.dy[k] = cnt[k] > 0 ? sumY[k] / Double(cnt[k]) : 0
        }
        let vectorAverage = rms(avg, drift)

        // 🐱 (2) ensemble correlation over the same pairs (plain average: memory longer than the run)
        var p = PIVParameters()
        p.ensemble.livePairs = 1000
        let ens = try #require(EnsembleCorrelator(image: ps[0].a, parameters: p, pairSpacing: 1, initial: nil))
        ens.beginSession(owner: ObjectIdentifier(ens))
        for q in ps { ens.add(a: q.a, b: q.b, dt: 1, parameters: p) }
        let live = try #require(ens.liveField(parameters: p, adaptOffsets: false))
        let session = try #require(ens.endSession(owner: ObjectIdentifier(ens), parameters: p))
        let e = rms(live.field, drift)
        let f = live.field
        let inner = (0..<f.count).filter { f.status[$0] == .valid && f.x($0) >= 40 && f.y($0) >= 40 && f.x($0) <= 216 && f.y($0) <= 152 }
        let biasX = inner.map { f.dx[$0] - drift.0 }.reduce(0, +) / Double(inner.count)
        let biasY = inner.map { f.dy[$0] - drift.1 }.reduce(0, +) / Double(inner.count)
        let s = rms(session.field, drift)
        print(String(format: "ENSEMBLE per-pair valid %.0f %% | vector average rms %.3f px | ensemble rms %.3f px (bias %.3f, %.3f), valid %.0f %%, session rms %.3f px, median peak ratio %.1f",
                     100 * instValid / Double(ps.count), vectorAverage.rms, e.rms, biasX, biasY, e.valid * 100, s.rms,
                     live.peakRatio.filter(\.isFinite).sorted()[live.peakRatio.count / 2]))
        // 🐱 measured (v7, Lanczos window shifting): single pairs 47 % valid; vector average 0.17 px rms (0.33 px with the
        // 🐱 earlier bilinear shifting); ensemble 0.19 px, 96 % valid, no bias. The ensemble's advantage here is that
        // 🐱 every window gets a vector from one clean averaged peak; in rms it is now on par with the vector average.
        #expect(instValid / Double(ps.count) < 0.6)        // 🐱 hard images: most single pairs fail
        #expect(e.valid > 0.9)
        #expect(e.rms < 0.25)
        #expect(e.rms < 1.3 * vectorAverage.rms)
        #expect(abs(biasX) < 0.04 && abs(biasY) < 0.04)     // 🐱 overlap-corrected peak fit: no pull towards zero
        #expect(abs(s.rms - e.rms) < 1e-6)                  // 🐱 session sum = live plain average here
        #expect(live.totalPairs == 40 && session.totalPairs == 40)
        #expect(live.field.validCount > 0 && live.field.windowSize == 32 && live.field.step == 16)
    }

    @Test func cameraShiftIsRemovedBeforeAveraging() throws {
        let engine = PIVEngine()
        let drift = (1.2, 0.6)
        let ps = pairs(30, drift: drift, seeding: 150, brownian: 0.2, noise: 3, peak: 90, cameraStd: 1.5, engine: engine, seed: 21)
        var p = PIVParameters()
        p.ensemble.livePairs = 1000
        func run(_ compensate: Bool) throws -> (rms: Double, peak: Double) {
            let ens = try #require(EnsembleCorrelator(image: ps[0].a, parameters: p, pairSpacing: 1, initial: nil))
            for q in ps { ens.add(a: q.a, b: q.b, dt: 1, parameters: p, shift: compensate ? { _, _ in q.camera } : nil) }
            let f = try #require(ens.liveField(parameters: p, adaptOffsets: false)).field
            let peaks = (0..<f.count).filter { f.status[$0] == .valid }.map { Double(f.correlation[$0]) }.sorted()
            return (rms(f, drift).rms, peaks[peaks.count / 2])
        }
        let with = try run(true), without = try run(false)
        print(String(format: "ENSEMBLE shake: compensated rms %.3f px, peak %.2f | uncompensated rms %.3f px, peak %.2f",
                     with.rms, with.peak, without.rms, without.peak))
        #expect(with.rms < 0.08)
        #expect(with.peak > 1.5 * without.peak)   // 🐱 shake smears the averaged peak unless removed per pair
    }

    @Test func offsetsFollowLargeDisplacementAndGeometryIsChecked() throws {
        let engine = PIVEngine()
        let drift = (6.4, -3.2)   // 🐱 beyond a quarter window from zero offset (8 px): offsets must re-centre
        let ps = pairs(40, drift: drift, seeding: 120, brownian: 0.1, noise: 2, peak: 120, engine: engine, seed: 5)
        var p = PIVParameters()
        p.ensemble.livePairs = 20
        let ens = try #require(EnsembleCorrelator(image: ps[0].a, parameters: p, pairSpacing: 3, initial: nil))
        #expect(ens.matches(image: ps[0].b, parameters: p, pairSpacing: 3))
        #expect(!ens.matches(image: ps[0].b, parameters: p, pairSpacing: 4))
        var f: EnsembleField?
        for q in ps {
            ens.add(a: q.a, b: q.b, dt: 0.1, parameters: p)
            f = ens.liveField(parameters: p, adaptOffsets: true)
        }
        let r = rms(try #require(f).field, drift)
        #expect(r.valid > 0.9 && r.rms < 0.1)
        #expect(abs(try #require(f).field.dt - 0.1) < 1e-9)
    }
}
