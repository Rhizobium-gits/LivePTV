import CameraKit
import CoreMedia
import Foundation
import PTVCore
import Testing
@testable import Pipeline

/// 🐱 Thread-safe collector for pipeline callbacks.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [VelocitySample] = []
    private var _frames = 0
    func add(_ r: FrameResult) { lock.withLock { _samples += r.samples; _frames += 1 } }
    var samples: [VelocitySample] { lock.withLock { _samples } }
    var frames: Int { lock.withLock { _frames } }
}

private func ptvSettings() -> AnalysisSettings {
    var s = AnalysisSettings()
    s.method = .ptv
    return s
}

private func runSynthetic(_ cfg: TestVideoSource.Configuration, settings: AnalysisSettings = ptvSettings(),
                          recorderParent: URL? = nil) async throws -> (TestVideoSource, AnalysisPipeline, Collected, URL?) {
    let source = TestVideoSource(configuration: cfg)
    let pipeline = AnalysisPipeline(source: source, settings: settings)
    let got = Collected()
    pipeline.onResult = { got.add($0) }
    if let parent = recorderParent {
        let rec = try ExperimentRecorder(parent: parent, label: "unit test", source: source.info, settings: settings,
                                         streamParameters: nil, cameraInfo: ["camera": "synthetic"], archivePreviewStream: false)
        pipeline.attach(recorder: rec)
    }
    try await source.startPreview()
    pipeline.start()
    while pipeline.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
    let folder = await pipeline.finishRecording()?.folder
    return (source, pipeline, got, folder)
}

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("liveptv-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite(.serialized) struct PipelineAccuracyTests {
    @Test func uniformFlowRecoveredEndToEnd() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 40
        cfg.flow = .uniform(u: 90, v: -45)   // 🐱 3 px and -1.5 px per frame at 30 fps
        cfg.noiseStd = 2
        let (_, pipeline, got, _) = try await runSynthetic(cfg)
        let all = got.samples
        let s = all.filter { !$0.outlier }
        #expect(got.frames == 40)
        #expect(s.count > 30 * 300)
        // 🐱 Flagged samples are a small minority (mostly the first frames, before neighbours give a predictor).
        #expect(Double(all.count - s.count) / Double(all.count) < 0.02)
        // 🐱 Gross errors (> 1 px/frame) that survive the outlier test are rare.
        #expect(Double(s.filter { hypot($0.u - 90, $0.v + 45) > 30 }.count) / Double(s.count) < 0.001)
        let errU: [Double] = s.map { $0.u - 90 }
        let errV: [Double] = s.map { $0.v + 45 }
        var sumSq = 0.0
        for k in errU.indices { sumSq += errU[k] * errU[k] + errV[k] * errV[k] }
        let rms = sqrt(sumSq / Double(s.count))
        // 🐱 ≈0.04 px localisation error per frame pair → ≈1–3 px/s at 30 fps.
        #expect(rms < 4)
        let medianU = errU.sorted()[s.count / 2]
        #expect(abs(medianU) < 0.5)
        #expect(pipeline.metrics.streamGapFrames == 0)
        #expect(pipeline.metrics.analysisDrops == 0)
    }

    @Test func vortexFieldMatchesGroundTruth() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 60
        cfg.particleCount = 900
        cfg.flow = .lambOseen(circulation: 60_000, coreRadius: 60)
        var settings = ptvSettings()
        settings.field.cellSize = 40
        settings.field.window = 10
        let source = TestVideoSource(configuration: cfg)
        let (_, pipeline, got, _) = try await runSynthetic(cfg, settings: settings)
        _ = pipeline
        let s = got.samples.filter { !$0.outlier }
        #expect(Double(s.count) / Double(got.samples.count) > 0.97)
        var se = 0.0, sref = 0.0
        for v in s {
            let truth = source.groundTruthVelocity(x: v.x, y: v.y)
            se += (v.u - truth.u) * (v.u - truth.u) + (v.v - truth.v) * (v.v - truth.v)
            sref += truth.u * truth.u + truth.v * truth.v
        }
        let relative = sqrt(se / sref)
        let absoluteRMS = sqrt(se / Double(s.count))
        #expect(s.count > 20_000)
        // 🐱 Same noise floor as the uniform case (≈0.07 px/frame), i.e. no flow-dependent bias. Relative to this
        // 🐱 field's RMS speed (≈55 px/s) that is ≈4 %.
        #expect(absoluteRMS < 3)
        #expect(relative < 0.05)
    }

    @Test func droppedFramesAreCountedFromTimestamps() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 150
        cfg.dropProbability = 0.1
        cfg.particleCount = 50
        let source = TestVideoSource(configuration: cfg)
        let pipeline = AnalysisPipeline(source: source)
        let raws = RawCollector()
        pipeline.onResult = { raws.add($0.frame.timing.sourceTimestampRaw ?? -1) }
        try await source.startPreview()
        pipeline.start()
        while pipeline.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let r = raws.values
        let expectedMissing = Int(r.last! - r.first! + 1) - r.count
        #expect(expectedMissing > 10)
        #expect(pipeline.metrics.streamGapFrames == expectedMissing)
        #expect(pipeline.metrics.framesAnalyzed == r.count)
    }
}

final class RawCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Int64] = []
    func add(_ x: Int64) { lock.withLock { v.append(x) } }
    var values: [Int64] { lock.withLock { v } }
}

@Suite(.serialized) struct RecordingTests {
    @Test func sessionFolderContainsAllFiles() async throws {
        var cfg = TestVideoSource.Configuration()
        cfg.realTime = false
        cfg.frameLimit = 20
        cfg.particleCount = 100
        var settings = ptvSettings()
        settings.calibration = Calibration(mmPerPixel: 0.02, note: "test")
        let parent = tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let (_, _, got, folder) = try await runSynthetic(cfg, settings: settings, recorderParent: parent)
        let dir = try #require(folder)
        for f in ["session.json", "frames.csv", "particles.csv", "velocities.csv", "field.csv", "events.csv", "latency_probe.csv"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path), "\(f) missing")
        }
        let frames = try String(contentsOf: dir.appendingPathComponent("frames.csv"), encoding: .utf8).split(separator: "\n")
        #expect(frames.count == 21)
        let velocities = try String(contentsOf: dir.appendingPathComponent("velocities.csv"), encoding: .utf8).split(separator: "\n")
        #expect(velocities.count == got.samples.count + 1)
        // 🐱 physical units are written when a calibration exists
        let firstVelocity = velocities[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(firstVelocity.count == 13 && !firstVelocity[10].isEmpty)

        let json = try Data(contentsOf: dir.appendingPathComponent("session.json"))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let meta = try dec.decode(SessionMetadata.self, from: json)
        #expect(meta.summary?.metrics.framesAnalyzed == 20)
        #expect(meta.summary?.velocitySamples == got.samples.count)
        #expect(meta.settings.calibration.mmPerPixel == 0.02)
        #expect(meta.endedAt != nil)
    }

    @Test func previewStreamArchiveRoundTrips() async throws {
        let url = try #require(Bundle.module.url(forResource: "testsrc_160x120_30f", withExtension: "h264"))
        let stream = try Data(contentsOf: url)
        let units = accessUnits(stream)
        #expect(units.count == 30)

        let parent = tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let rec = try ExperimentRecorder(parent: parent, label: "archive", source: SourceInfo(kind: .insta360WiFi, name: "mock", address: "-", isLive: true),
                                         settings: AnalysisSettings(), streamParameters: nil, cameraInfo: [:], archivePreviewStream: true)
        var expectedRaw = Data()
        for (i, u) in units.enumerated() {
            let bytes = AnnexB.join(u)
            expectedRaw += bytes
            rec.archive(CompressedAccessUnit(codec: .h264, annexB: bytes, sourceTimestampRaw: 5_000_000 + Int64(i) * 33_333,
                                             receivedHostTime: Double(i) * 0.034, isKeyFrame: AnnexB.containsKeyFrame(u, codec: .h264)))
        }
        let (dir, _) = await rec.finish(metrics: PipelineMetrics(), sourceStatistics: SourceStatistics(), latencyResults: [])

        // 🐱 Raw stream is bit-exact.
        #expect(try Data(contentsOf: dir.appendingPathComponent("preview.h264")) == expectedRaw)
        let index = try String(contentsOf: dir.appendingPathComponent("preview_index.csv"), encoding: .utf8).split(separator: "\n")
        #expect(index.count == 31)

        // 🐱 MP4 re-opens through the normal file source with camera-clock timing.
        let file = VideoFileSource(url: dir.appendingPathComponent("preview.mp4"), pacing: .asFastAsPossible)
        try await file.startPreview()
        var pts: [Double] = []
        while let f = await file.nextFrame() {
            #expect(f.width == 160 && f.height == 120)
            pts.append(f.presentationTime)
        }
        #expect(pts.count == 30)
        for (a, b) in zip(pts, pts.dropFirst()) { #expect(abs((b - a) - 0.033333) < 0.0005) }
    }

    private func accessUnits(_ stream: Data) -> [[Data]] {
        var units: [[Data]] = []
        var cur: [Data] = []
        var has = false
        for nal in AnnexB.split(stream) {
            let t = AnnexB.type(of: nal, codec: .h264)
            let vcl = AnnexB.isVCL(t, codec: .h264)
            let first = vcl && nal.count > 1 && (nal[nal.startIndex + 1] & 0x80) != 0
            if has && (!vcl || first) { units.append(cur); cur = []; has = false }
            cur.append(nal)
            if vcl { has = true }
        }
        if !cur.isEmpty { units.append(cur) }
        return units
    }
}

@Suite struct LatencyProbeTests {
    @Test func measuresDelayAfterCalibrationCycles() {
        let probe = LatencyProbe()
        probe.begin()
        let latency = 0.120
        var t = 100.0
        var bright = false
        var frame = 0
        var measured: [LatencyProbe.Measurement] = []
        for _ in 0..<8 {
            bright.toggle()
            probe.screenChanged(toBright: bright, hostTime: t)
            // 🐱 Frames every 33 ms; the camera sees the change `latency` seconds later.
            for k in 0..<15 {
                let ft = t + Double(k) * 0.0333
                let seenBright = ft - t >= latency ? bright : !bright
                if let m = probe.observe(meanLuma: seenBright ? 200 : 20, frameIndex: frame, frameReceivedHostTime: ft, analysisEndHostTime: ft + 0.01) {
                    measured.append(m)
                }
                frame += 1
            }
            t += 1
        }
        #expect(measured.count == 6)   // 🐱 first two changes calibrate the levels
        for m in measured {
            #expect(m.toReceiveMs >= 120 && m.toReceiveMs < 120 + 34)
        }
        #expect(probe.medianToResultMs! > probe.medianToReceiveMs!)
    }
}
