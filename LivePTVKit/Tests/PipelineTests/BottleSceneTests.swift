import CameraKit
import Foundation
import PTVCore
import Testing
@testable import Pipeline

/// 🐱 The realistic case end to end: a vortex in water inside a round glass bottle, filmed from the side, with the
/// 🐱 bottle's reflections (stripes along the walls, a bright rim), a saturated hot spot and a glint sparkling along the
/// 🐱 free surface. The analysis with the container and scene corrections must recover the vortex in true plane
/// 🐱 coordinates; a naive analysis (diameter-based mm/px, no corrections) must not.
/// 🐱 Set LIVEPTV_EXAMPLE_DIR to copy the corrected session there (docs/examples/synthetic_bottle_piv).
@Suite(.serialized) struct BottleSceneTests {
    static let frame = (w: 640, h: 480)
    static let flow = SyntheticFlow.lambOseen(circulation: 32_000, coreRadius: 70)

    static func bottle() -> ContainerGeometry {
        var g = ContainerGeometry()
        g.shape = .cylinder
        g.axis = .vertical
        g.outline = PixelROI(x: 70, y: 30, width: 500, height: 420)
        g.frameWidth = frame.w
        g.frameHeight = frame.h
        g.outerDiameterMM = 60          // 🐱 → 0.12 mm per px across the silhouette
        g.wallThicknessMM = 2
        g.wallIndex = 1.474
        g.fluidIndex = 1.333
        g.wallMarginMM = 1.5
        return g
    }

    /// 🐱 What is not flow, drawn in apparent image coordinates.
    static func scene(_ t: Int, _ img: inout [Float]) {
        let (w, h) = frame
        func add(_ x: Int, _ y: Int, _ v: Float) { if x >= 0, y >= 0, x < w, y < h { img[y * w + x] += v } }
        // 🐱 static lab background with texture outside the bottle (fixed pseudo-random pattern)
        var state: UInt64 = 99
        for y in 0..<h {
            for x in 0..<w where x < 70 || x > 570 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                img[y * w + x] += 25 + Float(state >> 59)
            }
        }
        for y in 30..<450 {
            // 🐱 bright rims at the silhouette and two reflection stripes of the room lights on the glass
            for x in 70..<76 { add(x, y, 120) }
            for x in 564..<570 { add(x, y, 120) }
            for x in 96..<116 { let d = Float(abs(x - 106)); add(x, y, 170 * max(0, 1 - d / 10)) }
            for x in 515..<531 { let d = Float(abs(x - 523)); add(x, y, 110 * max(0, 1 - d / 8)) }
        }
        // 🐱 hot spot (saturated reflection of a lamp)
        for y in 110..<131 { for x in 420..<441 where hypot(Double(x - 430), Double(y - 120)) < 9 { add(x, y, 240) } }
        // 🐱 glint travelling along the free surface
        let gx = 150 + (7 * t) % 380, gy = 52 + Int(3 * sin(Double(t) / 5))
        for y in gy - 7...gy + 7 { for x in gx - 7...gx + 7 where hypot(Double(x - gx), Double(y - gy)) < 6.5 { add(x, y, 255) } }
    }

    private func run(_ cfg: TestVideoSource.Configuration, _ settings: AnalysisSettings, label: String) async throws -> (AnalysisPipeline.RecordingResult, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("liveptv-bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = TestVideoSource(configuration: cfg)
        let pipeline = AnalysisPipeline(source: source, settings: settings)
        pipeline.attach(recorder: try ExperimentRecorder(parent: parent, label: label, source: source.info, settings: settings,
                                                         streamParameters: nil, cameraInfo: [:], archivePreviewStream: false))
        try await source.startPreview()
        pipeline.start()
        while pipeline.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let result = try #require(await pipeline.finishRecording())
        return (result, parent)
    }

    private func table(_ url: URL) throws -> [[String: String]] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        guard let head = lines.first else { return [] }
        return lines.dropFirst().filter { $0.count == head.count }.map { Dictionary(uniqueKeysWithValues: zip(head, $0)) }
    }

    /// 🐱 Relative RMS error of mean_field.csv against the vortex (cells whose position is within `radius` px of the
    /// 🐱 bottle axis, i.e. inside the fluid; positions are taken as true plane positions).
    private func error(_ folder: URL, radius: Double) throws -> (rel: Double, n: Int) {
        var se = 0.0, sref = 0.0, n = 0
        for c in try table(folder.appendingPathComponent("mean_field.csv")) where c["valid"] == "1" {
            guard let x = Double(c["x_px"]!), let y = Double(c["y_px"]!), let u = Double(c["mean_u_px_s"]!), let v = Double(c["mean_v_px_s"]!),
                  abs(x - 320) < radius, y > 80, y < 420 else { continue }
            let t = Self.flow.velocity(x: x, y: y, width: Double(Self.frame.w), height: Double(Self.frame.h))
            se += (u - t.u) * (u - t.u) + (v - t.v) * (v - t.v)
            sref += t.u * t.u + t.v * t.v
            n += 1
        }
        return ((se / max(sref, 1e-12)).squareRoot(), n)
    }

    @Test func vortexInABottleWithReflections() async throws {
        let map = try #require(RefractionMap(geometry: Self.bottle(), calibrationMMPerPixel: nil))
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 150
        cfg.particleCount = 9000
        cfg.particleSigma = 1.0
        cfg.peakIntensity = 100
        cfg.background = 14
        cfg.noiseStd = 3
        cfg.flow = Self.flow
        // 🐱 tracers live in the plane through the axis; the camera sees them through the bottle
        cfg.apparentPosition = { x, y in map.inverse(x: x, y: y).map { (x: $0.x, y: $0.y) } }
        cfg.overlay = { t, img in Self.scene(t, &img) }

        var corrected = AnalysisSettings()
        corrected.container = Self.bottle()
        corrected.shake.enabled = false
        corrected.evaluation.minSamplesPerCell = 10
        var naive = AnalysisSettings()
        naive.calibration = Calibration(mmPerPixel: 0.12, note: "bottle diameter / silhouette width")
        naive.reflections.background = .off
        naive.reflections.glareMasking = false
        naive.reflections.saturationMasking = false
        naive.shake.enabled = false
        naive.evaluation.minSamplesPerCell = 10

        let (good, p1) = try await run(cfg, corrected, label: "synthetic vortex in a 60 mm glass bottle")
        defer { try? FileManager.default.removeItem(at: p1) }
        let (bad, p2) = try await run(cfg, naive, label: "naive")
        defer { try? FileManager.default.removeItem(at: p2) }
        // 🐱 the fluid interior: ±200 true px around the axis (the inner wall is at ±233 px)
        let e1 = try error(good.folder, radius: 200), e2 = try error(bad.folder, radius: 200)
        let q = try #require(good.evaluation?.piv)
        print(String(format: "BOTTLE SCENE corrected: rel rms %.3f (%d cells), masked windows %.1f %%, σ %.3f px | naive: rel rms %.3f (%d cells)",
                     e1.rel, e1.n, q.maskedPercent ?? -1, q.uncertaintyMedianPx ?? -1, e2.rel, e2.n))
        #expect(e1.n > 80)
        #expect(e1.rel < 0.10)
        #expect(e2.rel > 2.5 * e1.rel)

        if let dir = ProcessInfo.processInfo.environment["LIVEPTV_EXAMPLE_DIR"] {
            let dst = URL(fileURLWithPath: dir)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: good.folder, to: dst)
        }
    }
}
