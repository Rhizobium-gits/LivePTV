import CoreGraphics
import Foundation
import Testing
@testable import CameraKit
@testable import Pipeline
@testable import PTVCore

/// 🐱 Example sessions for the README: synthetic scenes with a known flow, run through the real pipeline and recorder,
/// 🐱 the recording folders (figures, report, CSV, VTK) copied to $LIVEPTV_SHOWCASE_DIR/<scene>. Skipped unless that
/// 🐱 variable is set. Each scene prints the relative RMS error of its mean field against the exact flow.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVEPTV_SHOWCASE_DIR"] != nil, "set LIVEPTV_SHOWCASE_DIR"),
       .serialized)
struct ShowcaseTests {
    static var outDir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIVEPTV_SHOWCASE_DIR"]!) }

    private func run(_ cfg: TestVideoSource.Configuration, _ settings: AnalysisSettings, label: String, scene: String) async throws -> AnalysisPipeline.RecordingResult {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("liveptv-showcase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = TestVideoSource(configuration: cfg)
        let pipeline = AnalysisPipeline(source: source, settings: settings)
        pipeline.attach(recorder: try ExperimentRecorder(parent: parent, label: label, source: source.info, settings: settings,
                                                         streamParameters: nil, cameraInfo: [:], archivePreviewStream: false))
        try await source.startPreview()
        pipeline.start()
        while pipeline.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let result = try #require(await pipeline.finishRecording())
        let dst = Self.outDir.appendingPathComponent(scene)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: result.folder, to: dst)
        try? FileManager.default.removeItem(at: parent)
        return result
    }

    private func table(_ url: URL) throws -> [[String: String]] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        guard let head = lines.first else { return [] }
        return lines.dropFirst().filter { $0.count == head.count }.map { Dictionary(uniqueKeysWithValues: zip(head, $0)) }
    }

    /// 🐱 Relative RMS error of a field file against the exact flow, cells at least `margin` px from the frame edge.
    private func error(_ scene: String, file: String = "mean_field.csv", cfg: TestVideoSource.Configuration, margin: Double = 40,
                       valid: String = "valid", u: String = "mean_u_px_s", v: String = "mean_v_px_s") throws -> (rel: Double, n: Int) {
        let truth = TestVideoSource(configuration: cfg)
        var se = 0.0, sref = 0.0, n = 0
        for c in try table(Self.outDir.appendingPathComponent(scene).appendingPathComponent(file)) where c[valid] == "1" || c[valid] == "valid" {
            guard let x = Double(c["x_px"] ?? ""), let y = Double(c["y_px"] ?? ""), let uu = Double(c[u] ?? ""), let vv = Double(c[v] ?? ""),
                  x > margin, y > margin, x < Double(cfg.width) - margin, y < Double(cfg.height) - margin else { continue }
            let t = truth.groundTruthVelocity(x: x, y: y)
            se += (uu - t.u) * (uu - t.u) + (vv - t.v) * (vv - t.v)
            sref += t.u * t.u + t.v * t.v
            n += 1
        }
        return ((se / max(sref, 1e-12)).squareRoot(), n)
    }

    private func base(width: Int, height: Int, flow: SyntheticFlow, frames: Int = 150, density: Double = 1.0 / 55) -> TestVideoSource.Configuration {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.width = width
        cfg.height = height
        cfg.frameLimit = frames
        cfg.particleCount = Int(Double(width * height) * density)
        cfg.particleSigma = 0.9
        cfg.peakIntensity = 150
        cfg.noiseStd = 3
        cfg.flow = flow
        return cfg
    }

    private func pivSettings(mmPerPixel: Double = 0.05) -> AnalysisSettings {
        var s = AnalysisSettings()
        s.shake.enabled = false
        s.calibration = Calibration(mmPerPixel: mmPerPixel, note: "synthetic")
        s.evaluation.minSamplesPerCell = 10
        return s
    }

    /// 🐱 Counter-rotating vortex pair: a jet between two vortices, opposite vorticity.
    @Test func vortexPair() async throws {
        let cfg = base(width: 1024, height: 640, flow: .vortexPair(circulation: 70_000, coreRadius: 45, separation: 260))
        _ = try await run(cfg, pivSettings(), label: "counter-rotating vortex pair (synthetic)", scene: "vortex_pair")
        let e = try error("vortex_pair", cfg: cfg)
        print(String(format: "SHOWCASE vortex_pair: mean field rel rms %.4f (%d cells)", e.rel, e.n))
    }

    /// 🐱 Taylor–Green vortex array: twelve cells of alternating rotation.
    @Test func vortexArray() async throws {
        let cfg = base(width: 960, height: 720, flow: .taylorGreen(uMax: 80, cell: 240))
        _ = try await run(cfg, pivSettings(), label: "Taylor-Green vortex array (synthetic)", scene: "vortex_array")
        let e = try error("vortex_array", cfg: cfg)
        print(String(format: "SHOWCASE vortex_array: mean field rel rms %.4f (%d cells)", e.rel, e.n))
    }

    /// 🐱 Plane Poiseuille flow: the centre-line profile against the parabola.
    @Test func channelFlow() async throws {
        let cfg = base(width: 960, height: 480, flow: .poiseuille(uMax: 120))
        _ = try await run(cfg, pivSettings(), label: "plane Poiseuille channel flow (synthetic)", scene: "channel")
        let e = try error("channel", cfg: cfg, margin: 20)
        print(String(format: "SHOWCASE channel: mean field rel rms %.4f (%d cells)", e.rel, e.n))
    }

    /// 🐱 Faint, sparse, Brownian tracers in a vortex: single pairs fail, ensemble correlation recovers the mean flow.
    @Test func faintParticlesEnsemble() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 150
        cfg.particleCount = 900
        cfg.particleSigma = 1.0
        cfg.peakIntensity = 32
        cfg.noiseStd = 9
        cfg.brownianD = 4
        cfg.flow = .lambOseen(circulation: 40_000, coreRadius: 60)
        var s = pivSettings(mmPerPixel: 0.002)
        s.piv.ensemble.enabled = true
        s.piv.autoPairSpacing = false
        s.evaluation.minSamplesPerCell = 5
        _ = try await run(cfg, s, label: "faint sparse tracers: ensemble correlation (synthetic, µPIV-like)", scene: "faint_ensemble")
        let pairs = try error("faint_ensemble", cfg: cfg, margin: 60)
        let ens = try error("faint_ensemble", file: "ensemble_field.csv", cfg: cfg, margin: 60, valid: "status", u: "u_px_s", v: "v_px_s")
        print(String(format: "SHOWCASE faint_ensemble: averaged single pairs rel rms %.4f (%d cells) | ensemble %.4f (%d cells)",
                     pairs.rel, pairs.n, ens.rel, ens.n))
    }

    /// 🐱 Camera shake with a static textured border: compensated and not.
    @Test func cameraShake() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 120
        cfg.particleCount = 7000
        cfg.particleSigma = 1.0
        cfg.flow = .lambOseen(circulation: 40_000, coreRadius: 50)
        cfg.staticMarginFraction = 0.18
        cfg.shakeStdPx = 0.5
        cfg.shakeRotationStd = 0.0008
        var on = pivSettings()
        on.shake.enabled = true
        on.evaluation.minSamplesPerCell = 20
        _ = try await run(cfg, on, label: "vortex filmed by a shaking camera: compensated (synthetic)", scene: "shake_compensated")
        var off = on
        off.shake.enabled = false
        _ = try await run(cfg, off, label: "vortex filmed by a shaking camera: not compensated (synthetic)", scene: "shake_uncompensated")
        let a = try error("shake_compensated", cfg: cfg, margin: 0.18 * 640 + 40)
        let b = try error("shake_uncompensated", cfg: cfg, margin: 0.18 * 640 + 40)
        // 🐱 the static border must look still: its velocity fluctuation is the shake that is left
        func borderStd(_ scene: String) throws -> Double {
            var v: [Double] = []
            for c in try table(Self.outDir.appendingPathComponent(scene).appendingPathComponent("mean_field.csv")) where c["valid"] == "1" {
                guard let x = Double(c["x_px"]!), let y = Double(c["y_px"]!), let su = Double(c["std_u_px_s"]!), let sv = Double(c["std_v_px_s"]!) else { continue }
                if x < 0.18 * 640 - 10 || x > 0.82 * 640 + 10 || y < 0.18 * 480 - 10 || y > 0.82 * 480 + 10 { v.append(((su * su + sv * sv) / 2).squareRoot()) }
            }
            return GridKernels.median(of: v) ?? -1
        }
        print(String(format: "SHOWCASE shake: mean field rel rms compensated %.4f, uncompensated %.4f | static border std %.2f vs %.2f px/s",
                     a.rel, b.rel, try borderStd("shake_compensated"), try borderStd("shake_uncompensated")))
    }

    /// 🐱 Real microscopy video (trackpy's `bulk_water` sample: 1 µm latex spheres diffusing in water, 24 fps,
    /// 🐱 2.85 px/µm, dark particles on a bright background), given as a video file in $LIVEPTV_REAL_BROWNIAN.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVEPTV_REAL_BROWNIAN"] != nil, "set LIVEPTV_REAL_BROWNIAN"))
    func realBrownianVideo() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIVEPTV_REAL_BROWNIAN"]!)
        var s = AnalysisSettings()
        s.method = .ptv
        s.detector.polarity = .darkOnBright
        s.calibration = Calibration(mmPerPixel: 1 / 2850, note: "1 µm = 2.85 px (trackpy bulk_water sample)")
        s.evaluation.cellSize = 64
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("liveptv-showcase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = VideoFileSource(url: url, pacing: .asFastAsPossible)
        let pipeline = AnalysisPipeline(source: source, settings: s)
        pipeline.attach(recorder: try ExperimentRecorder(parent: parent, label: "1 µm latex spheres in water (trackpy bulk_water, real video)",
                                                         source: source.info, settings: s, streamParameters: nil, cameraInfo: [:],
                                                         archivePreviewStream: false))
        try await source.startPreview()
        pipeline.start()
        while pipeline.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let r = try #require(await pipeline.finishRecording())
        let dst = Self.outDir.appendingPathComponent("real_brownian")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: r.folder, to: dst)
        try? FileManager.default.removeItem(at: parent)
        if let d = r.evaluation?.diffusion {
            print(String(format: "SHOWCASE real_brownian: D %.4f ± %.4f px²/s = %.4f µm²/s, localisation σ %.3f px, Stokes–Einstein %.0f nm (20 °C water), %d / %d step pairs",
                         d.estimate.d, d.estimate.standardError, d.estimate.d / (2.85 * 2.85), d.estimate.localizationNoisePx ?? -1,
                         d.stokesEinsteinDiameterNm ?? -1, d.estimate.pairsLag1, d.estimate.pairsLag2))
        } else {
            print("SHOWCASE real_brownian: no diffusion estimate")
        }
    }

    /// 🐱 PTV of Brownian particles drifting slowly: diffusion coefficient and Stokes–Einstein diameter.
    @Test func brownianPTV() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 300
        cfg.particleCount = 500
        cfg.flow = .uniform(u: 6, v: 0)
        cfg.brownianD = 3.0
        var s = AnalysisSettings()
        s.method = .ptv
        s.detector.backgroundSubtraction = false
        s.calibration = Calibration(mmPerPixel: 0.0005, note: "0.5 µm/px (microscope-like)")
        s.evaluation.cellSize = 64
        let r = try await run(cfg, s, label: "Brownian particles, PTV (synthetic, microscope-like)", scene: "brownian_ptv")
        if let d = r.evaluation?.diffusion {
            print(String(format: "SHOWCASE brownian_ptv: D %.3f px²/s (true 3.000), Stokes–Einstein %.0f nm (true 572)",
                         d.estimate.d, d.stokesEinsteinDiameterNm ?? -1))
        }
    }
}
