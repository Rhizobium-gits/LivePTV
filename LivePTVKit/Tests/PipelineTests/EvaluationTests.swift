import CameraKit
import Foundation
import PTVCore
import Testing
@testable import Pipeline

@Suite(.serialized) struct EvaluationTests {
    private func run(_ cfg: TestVideoSource.Configuration, _ settings: AnalysisSettings) async throws -> (AnalysisPipeline.RecordingResult, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("liveptv-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = TestVideoSource(configuration: cfg)
        let pipeline = AnalysisPipeline(source: source, settings: settings)
        pipeline.attach(recorder: try ExperimentRecorder(parent: parent, label: "eval", source: source.info, settings: settings,
                                                         streamParameters: nil, cameraInfo: [:], archivePreviewStream: false))
        try await source.startPreview()
        pipeline.start()
        while pipeline.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let result = try #require(await pipeline.finishRecording())
        return (result, parent)
    }

    @Test func vortexSessionEvaluation() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 90
        cfg.particleCount = 900
        cfg.flow = .lambOseen(circulation: 60_000, coreRadius: 60)
        var settings = AnalysisSettings()
        settings.method = .ptv
        settings.evaluation.cellSize = 32
        settings.evaluation.minSamplesPerCell = 15
        let (result, parent) = try await run(cfg, settings)
        defer { try? FileManager.default.removeItem(at: parent) }
        let e = try #require(result.evaluation)
        for f in ["evaluation.json", "mean_field.csv", "speed_histogram.csv", "figure_summary.png", "figure_summary.pdf",
                  "figure_profiles.png", "figure_profiles.pdf", "profiles.csv", "figure_timeseries.png", "timeseries.csv",
                  "overlay_on_image.png", "report.html"] {
            #expect(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent(f).path), "\(f) missing")
        }
        #expect(e.field.coveragePercent > 80)
        #expect(e.tracking.outlierPercent < 2)
        // 🐱 Analytic centre vorticity −Γ/(π r_c²) (clockwise on screen ⇒ negative); the 32-px grid smooths the peak.
        let rows = try String(contentsOf: result.folder.appendingPathComponent("mean_field.csv"), encoding: .utf8).split(separator: "\n").dropFirst()
        var centre: Double?
        var best = Double.infinity
        for r in rows {
            let c = r.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let x = Double(c[2]), let y = Double(c[3]), let w = Double(c[17]) else { continue }
            let d = hypot(x - 320, y - 240)
            if d < best { best = d; centre = w }
        }
        let expected = -60_000 / (Double.pi * 60 * 60)
        let w0 = try #require(centre)
        #expect(w0 < 0)
        #expect(abs(w0 - expected) / abs(expected) < 0.25)
        // 🐱 incompressible planar flow: divergence small compared with vorticity
        #expect((e.field.divergenceMeanAbs ?? 1) < 0.25 * (e.field.vorticityMeanAbs ?? 0))
        let html = try String(contentsOf: result.folder.appendingPathComponent("report.html"), encoding: .utf8)
        #expect(html.contains("data:image/png;base64,") && html.contains("Verdict"))
    }

    @Test func pivVortexEndToEnd() async throws {
        // 🐱 Dense PIV seeding (~20 particle images per 32×32 window) in a Lamb–Oseen vortex.
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 60
        cfg.particleCount = 6000
        cfg.particleSigma = 1.0
        cfg.flow = .lambOseen(circulation: 60_000, coreRadius: 60)
        var settings = AnalysisSettings()
        #expect(settings.method == .piv)   // 🐱 PIV is the default
        settings.evaluation.minSamplesPerCell = 20
        settings.calibration = Calibration(mmPerPixel: 0.01, note: "test")
        let (result, parent) = try await run(cfg, settings)
        defer { try? FileManager.default.removeItem(at: parent) }
        let e = try #require(result.evaluation)
        let q = try #require(e.piv)
        #expect(q.finalWindowPx == 32 && q.vectorSpacingPx == 16)
        #expect(q.validPercent > 95)
        #expect((q.correlationMedian ?? 0) > 0.6)
        #expect(e.diffusion == nil)   // 🐱 PIV windows carry no Brownian information
        for f in ["figure_summary.png", "figure_summary.pdf", "figure_profiles.pdf", "figure_timeseries.pdf", "piv_vectors.csv", "report.html"] {
            #expect(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent(f).path), "\(f) missing")
        }
        // 🐱 time-averaged PIV velocity vs the analytic field at every valid vector position
        let truth = TestVideoSource(configuration: cfg)
        let rows = try String(contentsOf: result.folder.appendingPathComponent("mean_field.csv"), encoding: .utf8).split(separator: "\n").dropFirst()
        var se = 0.0, sref = 0.0, n = 0
        var centre: (d: Double, w: Double)?
        for r in rows {
            let c = r.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard c[5] == "1", let x = Double(c[2]), let y = Double(c[3]), let u = Double(c[6]), let v = Double(c[7]) else { continue }
            let t = truth.groundTruthVelocity(x: x, y: y)
            se += (u - t.u) * (u - t.u) + (v - t.v) * (v - t.v)
            sref += t.u * t.u + t.v * t.v
            n += 1
            if let w = Double(c[17]) {
                let d = hypot(x - 320, y - 240)
                if centre == nil || d < centre!.d { centre = (d, w) }
            }
        }
        #expect(n > 600)
        #expect(sqrt(se / sref) < 0.05)
        let expected = -60_000 / (Double.pi * 60 * 60)
        #expect(abs(centre!.w - expected) / abs(expected) < 0.2)
    }


    @Test func ensembleCorrelationOnFaintSparseParticles() async throws {
        // 🐱 Faint, sparse particles with Brownian motion in a vortex, slight camera shake and a static border:
        // 🐱 single pairs struggle; the ensemble over the recording gives the mean flow.
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 120
        cfg.particleCount = 900
        cfg.particleSigma = 1.0
        cfg.peakIntensity = 32
        cfg.noiseStd = 9
        cfg.brownianD = 4
        cfg.flow = .lambOseen(circulation: 40_000, coreRadius: 60)
        var settings = AnalysisSettings()
        settings.piv.ensemble.enabled = true
        settings.piv.autoPairSpacing = false
        settings.shake.enabled = false
        settings.evaluation.minSamplesPerCell = 5
        let (result, parent) = try await run(cfg, settings)
        defer { try? FileManager.default.removeItem(at: parent) }
        let q = try #require(result.evaluation?.piv)
        let en = try #require(q.ensemble)
        for f in ["ensemble_field.csv", "figure_ensemble.png", "figure_ensemble.pdf", "report.html"] {
            #expect(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent(f).path), "\(f) missing")
        }
        let truth = TestVideoSource(configuration: cfg)
        func error(_ file: String, valid: String, u: String, v: String) throws -> (rel: Double, n: Int) {
            var se = 0.0, sref = 0.0, n = 0
            for c in try table(result.folder.appendingPathComponent(file)) where c[valid] == "valid" || c[valid] == "1" {
                guard let x = Double(c["x_px"]!), let y = Double(c["y_px"]!), let uu = Double(c[u]!), let vv = Double(c[v]!),
                      x > 60, y > 60, x < 580, y < 420 else { continue }
                let t = truth.groundTruthVelocity(x: x, y: y)
                se += (uu - t.u) * (uu - t.u) + (vv - t.v) * (vv - t.v)
                sref += t.u * t.u + t.v * t.v
                n += 1
            }
            return (sqrt(se / max(sref, 1e-12)), n)
        }
        let ens = try error("ensemble_field.csv", valid: "status", u: "u_px_s", v: "v_px_s")
        let avg = try error("mean_field.csv", valid: "valid", u: "mean_u_px_s", v: "mean_v_px_s")
        print(String(format: "ENSEMBLE E2E: %d pairs, per-pair valid %.0f %% | vector average rel rms %.3f (%d cells) | ensemble rel rms %.3f (%d cells), valid %.0f %%, peak ratio %.2f",
                     en.pairs, q.validPercent, avg.rel, avg.n, ens.rel, ens.n, en.validPercent, en.medianPeakRatio ?? 0))
        // 🐱 measured (v7: Lanczos window shifting, running-mean background): single pairs 13 % valid (37 % with bilinear
        // 🐱 shifting, whose implicit smoothing lets noisier windows pass); vector average 11.7 % rel. RMS (13.4 % before);
        // 🐱 ensemble 8.7 %, 98 % valid
        #expect(en.pairs > 100 && en.pairSpacingFrames == 1 && en.windowPx == 32)
        #expect(en.validPercent > 95)
        #expect(ens.rel < 0.12)
        #expect(ens.rel < 0.85 * avg.rel)
        #expect(ens.n >= avg.n)
    }

    @Test func ensembleWithCameraShake() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 120
        cfg.particleCount = 3000
        cfg.particleSigma = 1.0
        cfg.peakIntensity = 60
        cfg.noiseStd = 6
        cfg.flow = .lambOseen(circulation: 30_000, coreRadius: 50)
        cfg.staticMarginFraction = 0.18
        cfg.shakeStdPx = 0.6
        cfg.shakeRotationStd = 0.0006
        let truth = TestVideoSource(configuration: cfg)
        var settings = AnalysisSettings()
        settings.piv.ensemble.enabled = true
        settings.piv.autoPairSpacing = false
        settings.evaluation.minSamplesPerCell = 5
        func run(shake: Bool) async throws -> (rel: Double, peak: Double, valid: Double) {
            var s = settings
            s.shake.enabled = shake
            let (result, parent) = try await self.run(cfg, s)
            defer { try? FileManager.default.removeItem(at: parent) }
            let en = try #require(result.evaluation?.piv?.ensemble)
            var se = 0.0, sref = 0.0
            for c in try table(result.folder.appendingPathComponent("ensemble_field.csv")) where c["status"] == "valid" {
                guard let x = Double(c["x_px"]!), let y = Double(c["y_px"]!), let u = Double(c["u_px_s"]!), let v = Double(c["v_px_s"]!),
                      x > 0.18 * 640 + 40, y > 0.18 * 480 + 40, x < 0.82 * 640 - 40, y < 0.82 * 480 - 40 else { continue }
                let t = truth.groundTruthVelocity(x: x, y: y)
                se += (u - t.u) * (u - t.u) + (v - t.v) * (v - t.v)
                sref += t.u * t.u + t.v * t.v
            }
            return (sqrt(se / max(sref, 1e-12)), en.medianPeakCorrelation ?? 0, en.validPercent)
        }
        let with = try await run(shake: true), without = try await run(shake: false)
        print(String(format: "ENSEMBLE shake E2E: compensated rel rms %.3f, peak %.2f, valid %.0f %% | uncompensated rel rms %.3f, peak %.2f, valid %.0f %%",
                     with.rel, with.peak, with.valid, without.rel, without.peak, without.valid))
        #expect(with.rel < 0.08)
        #expect(with.peak > without.peak)
    }

    @Test func savedSettingsSurviveNewFieldsAndMigrate() throws {
        // 🐱 settings saved by an older version: no `schema`, no `ensemble`, capping on (the old default)
        var old = AnalysisSettings()
        old.calibration = Calibration(mmPerPixel: 0.0042, note: "ruler")
        old.roi = PixelROI(x: 10, y: 20, width: 300, height: 200)
        old.piv.intensityCapping = true
        var dict = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        dict.removeValue(forKey: "schema")
        var piv = try #require(dict["piv"] as? [String: Any])
        piv.removeValue(forKey: "ensemble")
        piv.removeValue(forKey: "windowInterpolation")
        piv.removeValue(forKey: "useGPU")                    // 🐱 0.7 had no GPU setting
        dict["piv"] = piv
        // 🐱 v6 had no scene corrections
        dict.removeValue(forKey: "reflections")
        dict.removeValue(forKey: "container")
        let data = try JSONSerialization.data(withJSONObject: dict)
        #expect((try? JSONDecoder().decode(AnalysisSettings.self, from: data)) == nil)   // 🐱 strict decoding would lose everything
        let merged = try #require(AnalysisSettings.decodeMerged(data))
        #expect(merged.calibration.mmPerPixel == 0.0042 && merged.roi == old.roi)
        #expect(merged.piv.ensemble == EnsembleParameters())
        #expect(merged.piv.intensityCapping == false)       // 🐱 migrated to the new default
        #expect(merged.schema == AnalysisSettings.currentSchema)
        #expect(merged.reflections == ReflectionParameters() && merged.container == ContainerGeometry())
        #expect(merged.piv.windowInterpolation == .lanczos4)
        #expect(merged.piv.useGPU)
        // 🐱 a current-schema choice is kept
        var now = AnalysisSettings()
        now.piv.intensityCapping = true
        #expect(AnalysisSettings.decodeMerged(try JSONEncoder().encode(now))?.piv.intensityCapping == true)
    }


    /// 🐱 Plumbing of the scene corrections through a recording: a round container (wall mask, length scale from the
    /// 🐱 silhouette, displacement correction, rectified grid), an exclusion, and the new outputs. The synthetic video is
    /// 🐱 not refracted, so the "corrected" field is the apparent one × the bottle's lateral magnification (≈ 1/n at the
    /// 🐱 axis): that is what is checked.
    @Test func containerCorrectionsEndToEnd() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 60
        cfg.particleCount = 4000
        cfg.particleSigma = 1.0
        cfg.flow = .uniform(u: 45, v: 0)
        var s = AnalysisSettings()
        s.evaluation.minSamplesPerCell = 5
        s.shake.enabled = false
        s.piv.autoPairSpacing = false
        s.container.shape = .cylinder
        s.container.outline = PixelROI(x: 80, y: 40, width: 480, height: 400)
        s.container.frameWidth = 640
        s.container.frameHeight = 480
        s.container.outerDiameterMM = 48
        s.container.wallThicknessMM = 0.5
        s.reflections.exclusions = [PixelROI(x: 300, y: 330, width: 60, height: 60)]
        let (result, parent) = try await run(cfg, s)
        defer { try? FileManager.default.removeItem(at: parent) }
        for f in ["figure_quality.png", "figure_quality.pdf", "mean_field.vtk", "methods.txt", "mean_field_image_grid.csv", "mean_field.csv", "report.html"] {
            #expect(FileManager.default.fileExists(atPath: result.folder.appendingPathComponent(f).path), "\(f) missing")
        }
        let e = try #require(result.evaluation)
        let c = try #require(e.corrections)
        #expect(c.refractionCorrected && c.rectifiedGrid)
        #expect(abs((e.mmPerPixel ?? 0) - 0.1) < 1e-9)                       // 🐱 48 mm over 480 px
        #expect((e.piv?.maskedPercent ?? 0) > 15)                             // 🐱 outside the bottle, wall band, exclusion
        #expect(e.piv?.uncertaintyMedianPx != nil && e.piv?.particleImageDiameterPx != nil)
        let methods = try String(contentsOf: result.folder.appendingPathComponent("methods.txt"), encoding: .utf8)
        #expect(methods.contains("Refraction by the container was corrected"))
        // 🐱 near the axis the corrected speed is the apparent one × centre magnification
        let mag = try #require(c.lateralMagnificationAtCentre)
        let rows = try table(result.folder.appendingPathComponent("mean_field_image_grid.csv")).filter { r in
            guard r["valid"] == "1", let x = Double(r["x_px"]!), let y = Double(r["y_px"]!) else { return false }
            return abs(x - 320) < 40 && abs(y - 240) < 80
        }
        let u = rows.compactMap { Double($0["mean_u_px_s"]!) }
        let mean = u.reduce(0, +) / Double(max(1, u.count))
        print(String(format: "CONTAINER E2E: masked %.1f %%, centre magnification %.4f, centre u %.2f px/s (apparent 45 → expected %.2f)",
                     e.piv?.maskedPercent ?? -1, mag, mean, 45 * mag))
        #expect(u.count >= 4)
        #expect(abs(mean - 45 * mag) < 0.05 * 45 * mag)
        let vtk = try String(contentsOf: result.folder.appendingPathComponent("mean_field.vtk"), encoding: .utf8)
        #expect(vtk.hasPrefix("# vtk DataFile Version 3.0") && vtk.contains("VECTORS velocity double"))
    }

    /// 🐱 CSV as rows of [column name: value].
    private func table(_ url: URL) throws -> [[String: String]] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        guard let head = lines.first else { return [] }
        return lines.dropFirst().filter { $0.count == head.count }.map { Dictionary(uniqueKeysWithValues: zip(head, $0)) }
    }

    /// 🐱 Mean-field error inside the fluid, and the velocity fluctuation (std) measured in the static border.
    private func fieldErrors(_ folder: URL, truth: TestVideoSource, inner: CGRect) throws -> (relRMS: Double, borderStd: Double) {
        var se = 0.0, sref = 0.0, border = 0.0, nb = 0.0
        for c in try table(folder.appendingPathComponent("mean_field.csv")) where c["valid"] == "1" {
            guard let x = Double(c["x_px"]!), let y = Double(c["y_px"]!), let u = Double(c["mean_u_px_s"]!), let v = Double(c["mean_v_px_s"]!),
                  let su = Double(c["std_u_px_s"]!), let sv = Double(c["std_v_px_s"]!) else { continue }
            if inner.contains(CGPoint(x: x, y: y)) {
                let t = truth.groundTruthVelocity(x: x, y: y)
                se += (u - t.u) * (u - t.u) + (v - t.v) * (v - t.v)
                sref += t.u * t.u + t.v * t.v
            } else if !inner.insetBy(dx: -40, dy: -40).contains(CGPoint(x: x, y: y)) {
                border += hypot(su, sv); nb += 1
            }
        }
        return (sqrt(se / max(sref, 1e-12)), border / max(nb, 1))
    }

    @Test func cameraShakeIsCompensated() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 90
        cfg.particleCount = 7000
        cfg.particleSigma = 1.0
        cfg.flow = .lambOseen(circulation: 40_000, coreRadius: 50)
        cfg.staticMarginFraction = 0.18     // 🐱 textured static border (walls)
        cfg.shakeStdPx = 0.5                // 🐱 camera vibration
        cfg.shakeRotationStd = 0.0008
        let truth = TestVideoSource(configuration: cfg)
        let inner = CGRect(x: 0.18 * 640 + 40, y: 0.18 * 480 + 40, width: 640 * 0.64 - 80, height: 480 * 0.64 - 80)

        var on = AnalysisSettings()
        on.evaluation.minSamplesPerCell = 20
        let (r1, p1) = try await run(cfg, on)
        defer { try? FileManager.default.removeItem(at: p1) }
        var off = on
        off.shake.enabled = false
        let (r2, p2) = try await run(cfg, off)
        defer { try? FileManager.default.removeItem(at: p2) }

        let withComp = try fieldErrors(r1.folder, truth: truth, inner: inner)
        let without = try fieldErrors(r2.folder, truth: truth, inner: inner)
        // 🐱 shake is estimated after the learning phase, logged in frames.csv, and removed from every vector
        let rows = try table(r1.folder.appendingPathComponent("frames.csv"))
        let applied = rows.filter { $0["shake_applied"] == "1" }.count
        #expect(applied > 50)
        #expect(withComp.relRMS < 0.08)
        // 🐱 zero-mean shake mostly averages out of the mean field but not out of the fluctuations:
        // 🐱 the static border must look still (small std) only when compensated
        #expect(without.borderStd > 4 * withComp.borderStd)
        let q = try #require(r1.evaluation?.piv)
        #expect(q.shakeCompensation && q.shakePairsCorrected > 50 && (q.shakeMedianPx ?? 0) > 0.3)
    }


    @Test func slowVortexIsNotMistakenForCameraRotation() async throws {
        // 🐱 Regression: a slow, steady vortex (≤ 0.2 px/frame) must not be absorbed as "camera rotation".
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 150
        cfg.particleCount = 6000
        cfg.particleSigma = 1.0
        cfg.flow = .lambOseen(circulation: 4_000, coreRadius: 60)
        cfg.staticMarginFraction = 0.15
        cfg.shakeStdPx = 0.6
        cfg.shakeRotationStd = 0.0005
        let truth = TestVideoSource(configuration: cfg)
        var settings = AnalysisSettings()
        settings.evaluation.minSamplesPerCell = 20
        let (result, parent) = try await run(cfg, settings)
        defer { try? FileManager.default.removeItem(at: parent) }
        let rows = try table(result.folder.appendingPathComponent("frames.csv")).filter { $0["shake_applied"] == "1" }
        let rot = rows.compactMap { Double($0["shake_rotation_mrad"]!) }
        let resid = rows.compactMap { Double($0["shake_residual_px"]!) }.sorted()
        #expect(rows.count > 80)
        #expect(abs(rot.reduce(0, +) / Double(rot.count)) < 0.6)     // 🐱 zero-mean like real vibration (was ≈ −4.5)
        // 🐱 background fits rigid motion (was ≈ 2 px when broken). Measured v7: 0.015 px without temporal background,
        // 🐱 0.069 px with the running mean (static windows re-measured on raw frames; 0.127 px without that)
        #expect(resid[resid.count / 2] < 0.1)
        let inner = CGRect(x: 0.15 * 640 + 40, y: 0.15 * 480 + 40, width: 640 * 0.7 - 80, height: 480 * 0.7 - 80)
        let err = try fieldErrors(result.folder, truth: truth, inner: inner)
        #expect(err.relRMS < 0.12)                                     // 🐱 the slow vortex is preserved
    }

    @Test func slowFlowUsesLongerPairs() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 150
        cfg.particleCount = 6000
        cfg.particleSigma = 1.0
        cfg.flow = .uniform(u: 3, v: -1.5)    // 🐱 0.1 / −0.05 px per frame: sub-pixel per frame pair
        var settings = AnalysisSettings()
        settings.evaluation.minSamplesPerCell = 10
        settings.shake.enabled = false
        let (result, parent) = try await run(cfg, settings)
        defer { try? FileManager.default.removeItem(at: parent) }
        let e = try #require(result.evaluation)
        let lastK = Int(try table(result.folder.appendingPathComponent("frames.csv")).last?["piv_pair_spacing"] ?? "") ?? 0
        #expect(lastK >= 8)                                  // 🐱 pairs spread out to make the motion measurable
        #expect(abs((e.field.meanU ?? 0) - 3) < 0.3 && abs((e.field.meanV ?? 0) + 1.5) < 0.3)
    }

    @Test func brownianDiffusionAndStokesEinsteinFromImages() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 240
        cfg.particleCount = 500
        cfg.flow = .uniform(u: 6, v: 0)   // 🐱 slow drift that must not bias D
        cfg.brownianD = 3.0               // 🐱 px²/s → one-frame step ≈ 0.45 px per axis
        var settings = AnalysisSettings()
        settings.method = .ptv
        settings.detector.backgroundSubtraction = false
        settings.calibration = Calibration(mmPerPixel: 0.0005, note: "0.5 µm/px (microscope-like)")
        settings.evaluation.cellSize = 64
        let (result, parent) = try await run(cfg, settings)
        defer { try? FileManager.default.removeItem(at: parent) }
        let e = try #require(result.evaluation)
        let d = try #require(e.diffusion)
        #expect(d.estimate.significant)
        #expect(abs(d.estimate.d - 3.0) / 3.0 < 0.08)   // 🐱 observed +3 %
        // 🐱 Stokes–Einstein with the true D: 3 px²/s × (0.5 µm)² = 0.75 µm²/s in water at 20 °C ≈ 572 nm.
        let trueSize = 1.380649e-23 * 293.15 / (3 * Double.pi * 1.002e-3 * 0.75e-12) * 1e9
        let size = try #require(d.stokesEinsteinDiameterNm)
        #expect(abs(size - trueSize) / trueSize < 0.1)
        #expect(e.field.speedUnit == "µm/s")
    }
}
