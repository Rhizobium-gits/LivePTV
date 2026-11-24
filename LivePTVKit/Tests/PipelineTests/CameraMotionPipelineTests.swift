import CameraKit
import Foundation
import PTVCore
import Testing
@testable import Pipeline

/// 🐱 Camera motion end to end, through the synthetic camera and the real pipeline: a stand swaying about its foot
/// 🐱 (rotation about a point far below the picture), rolling-shutter shear with keystone, and the same sway in PTV.
@Suite(.serialized) struct CameraMotionPipelineTests {
    private func run(_ cfg: TestVideoSource.Configuration, _ settings: AnalysisSettings) async throws -> (AnalysisPipeline.RecordingResult, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("liveptv-motion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = TestVideoSource(configuration: cfg)
        let pipeline = AnalysisPipeline(source: source, settings: settings)
        pipeline.attach(recorder: try ExperimentRecorder(parent: parent, label: "camera motion", source: source.info, settings: settings,
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

    static let margin = 0.18

    private func scene() -> TestVideoSource.Configuration {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 110
        cfg.particleCount = 7000
        cfg.particleSigma = 1.0
        cfg.flow = .lambOseen(circulation: 40_000, coreRadius: 50)
        cfg.staticMarginFraction = Self.margin      // 🐱 textured static border (walls)
        return cfg
    }

    /// 🐱 Steady flow, so every fluctuation in the mean field is camera motion left over: the median standard
    /// 🐱 deviation (px/s) of the static border cells and of the flow cells.
    private func fluctuations(_ folder: URL) throws -> (border: Double, flow: Double) {
        var b: [Double] = [], f: [Double] = []
        let w = 640.0, h = 480.0, m = Self.margin
        for c in try table(folder.appendingPathComponent("mean_field.csv")) where c["valid"] == "1" {
            guard let x = Double(c["x_px"]!), let y = Double(c["y_px"]!), let su = Double(c["std_u_px_s"]!), let sv = Double(c["std_v_px_s"]!) else { continue }
            let s = ((su * su + sv * sv) / 2).squareRoot()
            if x < m * w - 10 || x > (1 - m) * w + 10 || y < m * h - 10 || y > (1 - m) * h + 10 { b.append(s) }
            else if x > m * w + 40 && x < (1 - m) * w - 40 && y > m * h + 40 && y < (1 - m) * h - 40 { f.append(s) }
        }
        return (GridKernels.median(of: b) ?? .nan, GridKernels.median(of: f) ?? .nan)
    }

    /// 🐱 The camera turns about the foot of its stand, 900 px below the picture. Automatic compensation removes it,
    /// 🐱 and the evaluation reports where the motion turned.
    @Test func standSwayingAboutItsFoot() async throws {
        var cfg = scene()
        cfg.shakePivot = (x: 320, y: 480 + 900)
        cfg.shakeRotationStd = 0.0003               // 🐱 ≈ 0.35 px at the picture
        var on = AnalysisSettings()
        on.evaluation.minSamplesPerCell = 20
        var off = on
        off.shake.enabled = false
        let (r1, p1) = try await run(cfg, on)
        defer { try? FileManager.default.removeItem(at: p1) }
        let (r2, p2) = try await run(cfg, off)
        defer { try? FileManager.default.removeItem(at: p2) }
        let a = try fluctuations(r1.folder), b = try fluctuations(r2.folder)
        let cm = try #require(r1.evaluation?.cameraMotion)
        print(String(format: "SWAY PIV: border std %.2f vs %.2f px/s, flow std %.2f vs %.2f px/s (compensated vs not) | pivot (%.0f, %.0f) R² %.2f, truth (320, 1380) | %@",
                     a.border, b.border, a.flow, b.flow, cm.pivotXPx ?? .nan, cm.pivotYPx ?? .nan, cm.pivotRSquared ?? .nan, cm.models.description))
        #expect(a.border < 0.4 * b.border)
        #expect(a.flow < 0.6 * b.flow)
        let px = try #require(cm.pivotXPx), py = try #require(cm.pivotYPx)
        #expect(hypot(px - 320, py - 1380) < 0.15 * 1000)
        #expect(cm.pivotInsideFrame == false)
        let methods = try String(contentsOf: r1.folder.appendingPathComponent("methods.txt"), encoding: .utf8)
        #expect(methods.contains("turned about a point"))
    }

    /// 🐱 Rolling-shutter shear and keystone on top of a shake: the automatic model leaves less than the similarity
    /// 🐱 model of LivePTV ≤ 0.7.
    @Test func shearAndKeystoneNeedMoreThanSimilarity() async throws {
        var cfg = scene()
        cfg.shakeStdPx = 0.2
        cfg.shakeShearStd = 0.0015                  // 🐱 ≈ 0.35 px across the picture's height
        cfg.shakeKeystoneStd = 0.0015               // 🐱 ≈ 0.25 px at the edges
        var auto = AnalysisSettings()
        auto.evaluation.minSamplesPerCell = 20
        var similarity = auto
        similarity.shake.model = .similarity
        let (r1, p1) = try await run(cfg, auto)
        defer { try? FileManager.default.removeItem(at: p1) }
        let (r2, p2) = try await run(cfg, similarity)
        defer { try? FileManager.default.removeItem(at: p2) }
        let a = try fluctuations(r1.folder), b = try fluctuations(r2.folder)
        print(String(format: "SHEAR PIV: border std %.2f vs %.2f px/s, flow std %.2f vs %.2f px/s (automatic vs similarity) | %@",
                     a.border, b.border, a.flow, b.flow, r1.evaluation?.cameraMotion?.models.description ?? ""))
        #expect(a.border < 0.8 * b.border)
        #expect(a.flow < b.flow)
    }

    /// 🐱 PTV: the same sway, particle velocities against the exact flow.
    @Test func ptvIsCorrectedToo() async throws {
        var cfg = scene()
        cfg.particleCount = 2500
        cfg.shakePivot = (x: 320, y: 480 + 900)
        cfg.shakeRotationStd = 0.0003
        var on = AnalysisSettings()
        on.method = .ptv
        on.detector.backgroundSubtraction = false
        var off = on
        off.shake.enabled = false
        let truth = TestVideoSource(configuration: cfg)
        func rms(_ folder: URL) throws -> (rms: Double, n: Int) {
            var se = 0.0, n = 0
            let w = 640.0, h = 480.0, m = Self.margin
            for c in try table(folder.appendingPathComponent("velocities.csv")) where c["outlier"] == "0" {
                guard let fi = Int(c["frame_index"]!), fi > 30, let x = Double(c["x_px"]!), let y = Double(c["y_px"]!),
                      let u = Double(c["u_px_s"]!), let v = Double(c["v_px_s"]!),
                      x > m * w + 30, x < (1 - m) * w - 30, y > m * h + 30, y < (1 - m) * h - 30 else { continue }
                let t = truth.groundTruthVelocity(x: x, y: y)
                se += (u - t.u) * (u - t.u) + (v - t.v) * (v - t.v)
                n += 1
            }
            return ((se / Double(max(1, 2 * n))).squareRoot(), n)
        }
        let (r1, p1) = try await run(cfg, on)
        defer { try? FileManager.default.removeItem(at: p1) }
        let (r2, p2) = try await run(cfg, off)
        defer { try? FileManager.default.removeItem(at: p2) }
        let a = try rms(r1.folder), b = try rms(r2.folder)
        print(String(format: "SWAY PTV: velocity RMS error %.2f px/s compensated (%d samples) vs %.2f px/s not (%d) | %@",
                     a.rms, a.n, b.rms, b.n, r1.evaluation?.cameraMotion?.text ?? "no camera-motion summary"))
        #expect(a.n > 1000)
        #expect(a.rms < 0.6 * b.rms)
        #expect(r1.evaluation?.cameraMotion != nil)
    }
}
