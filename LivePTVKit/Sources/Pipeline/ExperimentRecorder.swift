import CameraKit
import CoreGraphics
import Foundation
import PTVCore

/// 🐱 Buffered CSV writer. Numbers are written with explicit precision and '.' as decimal separator.
final class CSVWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private let flushBytes = 256 * 1024

    init(url: URL, header: [String]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        row(header)
    }

    func row(_ fields: [String]) {
        buffer.append(contentsOf: fields.joined(separator: ",").utf8)
        buffer.append(0x0A)
        if buffer.count >= flushBytes { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        flush()
        try? handle.synchronize()
        try? handle.close()
    }

    static func fmt(_ v: Double, _ digits: Int) -> String {
        v.isFinite ? String(format: "%.\(digits)f", v) : ""
    }

    static func fmtOptional(_ v: Double?, _ digits: Int) -> String { v.map { fmt($0, digits) } ?? "" }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

/// 🐱 Everything needed to interpret the numbers later, written as session.json.
public struct SessionMetadata: Codable, Sendable {
    public struct Device: Codable, Sendable {
        public var model: String
        public var system: String
    }

    public struct CameraRecording: Codable, Sendable {
        public var requestedHostTime: Double?
        public var acknowledgedHostTime: Double?
        public var stopRequestedHostTime: Double?
        public var stoppedHostTime: Double?
        public var cameraFile: String?
        public var error: String?

        public init() {}
    }

    public struct Summary: Codable, Sendable {
        public var metrics: PipelineMetrics
        public var sourceStatistics: SourceStatistics
        public var velocitySamples: Int
        public var fieldSnapshots: Int
        public var latencyProbe: [LatencyProbe.Measurement]
        public var previewArchive: [String]
        public var previewArchiveError: String?
        public var evaluation: SessionEvaluation?
        /// 🐱 Settings in effect when the recording ended (calibration may have been entered during the run).
        public var settingsAtEnd: AnalysisSettings?
    }

    public var schema = "liveptv.session/1"
    public var sessionID = UUID()
    public var label: String
    public var notes: String
    public var appVersion: String
    public var device: Device
    public var clockAnchor: HostClock.Anchor
    public var hostClock = "CLOCK_UPTIME_RAW seconds (all *_host_s columns)"
    public var startedAt: Date
    public var endedAt: Date?
    public var source: SourceInfo
    public var streamParameters: StreamParameters?
    public var cameraInfo: [String: String]
    public var timestampUnit: String?
    public var settings: AnalysisSettings
    public var cameraRecording: CameraRecording?
    public var files: [String: String]
    public var summary: Summary?
}

/// 🐱 Writes one experiment session into its own folder (visible in the Files app on iPad).
/// 🐱 All file I/O happens on a private serial queue so analysis never waits for storage.
public final class ExperimentRecorder: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "liveptv.recorder", qos: .utility)
    private var metadata: SessionMetadata
    private let frames: CSVWriter
    private let particles: CSVWriter
    private let velocities: CSVWriter
    private let field: CSVWriter
    private let latency: CSVWriter
    private let events: CSVWriter
    private let archiver: StreamArchiver?
    private var sampleCount = 0
    private var fieldStats: SessionFieldStatistics?
    private var aggregate = FrameAggregate()
    private var snapshotCount = 0
    private var finished = false

    /// 🐱 Creates `<parent>/<yyyyMMdd-HHmmss>_<label>/`.
    public init(parent: URL, label: String, notes: String = "", source: SourceInfo, settings: AnalysisSettings,
                streamParameters: StreamParameters?, cameraInfo: [String: String], archivePreviewStream: Bool) throws {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let safe = label.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        directory = parent.appendingPathComponent("\(stamp.string(from: Date()))_\(safe.isEmpty ? "session" : safe)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let dir = directory
        func csv(_ name: String, _ header: [String]) throws -> CSVWriter {
            try CSVWriter(url: dir.appendingPathComponent(name), header: header)
        }
        frames = try csv("frames.csv", ["frame_index", "segment", "timestamp_quality", "source_ts_raw", "pts_s", "received_host_s",
                                        "assembled_host_s", "decoded_host_s", "analysis_start_host_s", "analysis_end_host_s",
                                        "assembly_wait_ms", "decode_ms", "receive_to_result_ms", "analysis_ms", "missing_frames_before", "roi_x", "roi_y", "roi_w", "roi_h",
                                        "mean_luma", "threshold", "n_particles", "n_tracks", "n_samples", "analysis_drops_total",
                                        "stream_gap_frames_total", "decode_errors_total", "processing_fps",
                                        "piv_pair_spacing", "piv_scale", "shake_applied", "shake_tx_px", "shake_ty_px", "shake_rotation_mrad",
                                        "shake_scale_ppm", "shake_background_windows", "shake_residual_px"])
        particles = try csv("particles.csv", ["frame_index", "pts_s", "track_id", "x_px", "y_px", "peak", "mass", "area_px"])
        velocities = try csv("velocities.csv", ["frame_index", "track_id", "t_s", "x_px", "y_px", "dx_px", "dy_px", "dt_s",
                                                "u_px_s", "v_px_s", "u_mm_s", "v_mm_s", "outlier"])
        field = try csv("field.csv", ["snapshot", "t_s", "i", "j", "x_px", "y_px", "u_px_s", "v_px_s", "std_u_px_s", "std_v_px_s",
                                      "count", "valid", "outlier", "u_mm_s", "v_mm_s"])
        latency = try csv("latency_probe.csv", ["screen_change_host_s", "to_bright", "frame_index", "frame_received_host_s",
                                                "analysis_end_host_s", "to_receive_ms", "to_result_ms"])
        events = try csv("events.csv", ["host_s", "utc", "level", "message"])
        archiver = archivePreviewStream ? StreamArchiver(directory: dir) : nil

        let info = Bundle.main.infoDictionary
        metadata = SessionMetadata(
            label: label, notes: notes,
            appVersion: "\(info?["CFBundleShortVersionString"] ?? "dev") (\(info?["CFBundleVersion"] ?? "0"))",
            device: .init(model: Self.deviceModel(), system: ProcessInfo.processInfo.operatingSystemVersionString),
            clockAnchor: HostClock.Anchor(), startedAt: Date(), source: source, streamParameters: streamParameters,
            cameraInfo: cameraInfo, settings: settings,
            files: [
                "session.json": "this file",
                "frames.csv": "one row per analysed frame: timing, latency, counts, drops",
                "particles.csv": "every detected particle (full-frame px, origin top-left, y down)",
                "velocities.csv": "Lagrangian velocity samples between consecutive observations of a track (midpoint position/time); outlier=1 rows failed the normalised median test and are excluded from field.csv",
                "field.csv": "gridded Eulerian field snapshots (moving temporal average, normalised-median-test flags)",
                "latency_probe.csv": "screen-flash latency measurements, if a latency test was run",
                "events.csv": "connection and diagnostic log",
            ])
        writeMetadata()
    }

    private static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private func writeMetadata() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        if let data = try? enc.encode(metadata) {
            try? data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        }
    }

    // 🐱 MARK: per-frame records (called from the analysis thread; work is queued)

    struct FrameRecord {
        var frameIndex: Int
        var segment: Int
        var quality: String
        var sourceRaw: Int64?
        var pts: Double
        var received: Double
        var assembled: Double
        var decoded: Double
        var analysisStart: Double
        var analysisEnd: Double
        var missingBefore: Int
        var roi: PixelROI
        var meanLuma: Double
        var threshold: Float
        var particles: [Particle]
        var trackIDs: [Int]
        var tracks: Int
        var samples: [VelocitySample]
        var metrics: PipelineMetrics
        var mmPerPixel: Double?
        var method: AnalysisMethod = .ptv
        var piv: PIVField?
        var saveInstantaneous = false
        var pairSpacing = 1
        var pivScale = 1
        var shake: ShakeEstimate?
        var excludeFromStatistics = false
        /// 🐱 Share of the analysed image masked in this frame (glare, glints, container, exclusions).
        var maskStatistics: MaskStatistics?
        /// 🐱 Fractional parts of the raw valid displacements (analysed px, 20 bins over −0.5…0.5): peak locking.
        var subpixelHistogram: [Int]?
    }

    private var pivVectors: CSVWriter?

    func record(_ r: FrameRecord) {
        queue.async { [self] in
            guard !finished else { return }
            let f: (Double, Int) -> String = CSVWriter.fmt
            frames.row([String(r.frameIndex), String(r.segment), r.quality, r.sourceRaw.map(String.init) ?? "", f(r.pts, 6),
                        f(r.received, 6), f(r.assembled, 6), f(r.decoded, 6), f(r.analysisStart, 6), f(r.analysisEnd, 6),
                        f((r.assembled - r.received) * 1000, 2), f((r.decoded - r.assembled) * 1000, 2),
                        f((r.analysisEnd - r.received) * 1000, 2),
                        f((r.analysisEnd - r.analysisStart) * 1000, 2), String(r.missingBefore),
                        String(r.roi.x), String(r.roi.y), String(r.roi.width), String(r.roi.height), f(r.meanLuma, 2),
                        f(Double(r.threshold), 2), String(r.particles.count), String(r.tracks), String(r.samples.count),
                        String(r.metrics.analysisDrops), String(r.metrics.streamGapFrames), String(r.metrics.decodeErrors),
                        CSVWriter.fmtOptional(r.metrics.processingFPS, 2),
                        r.method == .piv ? String(r.pairSpacing) : "", r.method == .piv ? String(r.pivScale) : "",
                        r.shake.map { $0.applied ? "1" : "0" } ?? "", r.shake.map { f($0.tx, 4) } ?? "", r.shake.map { f($0.ty, 4) } ?? "",
                        r.shake.map { f($0.rotation * 1000, 4) } ?? "", r.shake.map { f($0.scale * 1e6, 1) } ?? "",
                        r.shake.map { String($0.backgroundWindows) } ?? "", r.shake.map { f($0.residualRMSPx, 4) } ?? ""])
            for (k, p) in r.particles.enumerated() {
                particles.row([String(r.frameIndex), f(r.pts, 6), k < r.trackIDs.count ? String(r.trackIDs[k]) : "",
                               f(p.x, 3), f(p.y, 3), f(Double(p.peak), 1), f(Double(p.mass), 1), String(p.area)])
            }
            if r.method == .piv, r.saveInstantaneous, let p = r.piv {
                if pivVectors == nil {
                    pivVectors = try? CSVWriter(url: directory.appendingPathComponent("piv_vectors.csv"), header: [
                        "frame_index", "pts_s", "i", "j", "x_px", "y_px", "dx_px", "dy_px", "dt_s", "u_px_s", "v_px_s", "status", "correlation", "u_mm_s", "v_mm_s",
                        "sigma_dx_px", "sigma_dy_px"])
                    metadata.files["piv_vectors.csv"] = "instantaneous PIV fields (every n-th pair; x, y apparent image position, displacements corrected for refraction when a container is set): status 0 valid, 1 replaced by neighbour median, 2 invalid, 3 masked; sigma = random uncertainty from correlation statistics"
                }
                let hasSigma = p.sigmaX.count == p.count
                for k in 0..<p.count {
                    let u = p.dx[k] / p.dt, v = p.dy[k] / p.dt
                    pivVectors?.row([String(r.frameIndex), f(r.pts, 6), String(k % p.columns), String(k / p.columns), f(p.x(k), 1), f(p.y(k), 1),
                                     f(p.dx[k], 4), f(p.dy[k], 4), f(p.dt, 6), f(u, 3), f(v, 3), String(p.status[k].rawValue), f(Double(p.correlation[k]), 3),
                                     r.mmPerPixel.map { f(u * $0, 5) } ?? "", r.mmPerPixel.map { f(v * $0, 5) } ?? "",
                                     hasSigma && p.isMeasured(k) ? f(Double(p.sigmaX[k]), 4) : "", hasSigma && p.isMeasured(k) ? f(Double(p.sigmaY[k]), 4) : ""])
                }
            }
            for s in r.samples where r.method == .ptv {
                velocities.row([String(s.frameIndex), String(s.trackID), f(s.t, 6), f(s.x, 3), f(s.y, 3), f(s.dx, 4), f(s.dy, 4),
                                f(s.dt, 6), f(s.u, 3), f(s.v, 3),
                                r.mmPerPixel.map { f(s.u * $0, 4) } ?? "", r.mmPerPixel.map { f(s.v * $0, 4) } ?? "",
                                s.outlier ? "1" : "0"])
            }
            sampleCount += r.samples.count
            aggregate.add(r)
            guard !r.excludeFromStatistics else { return }
            if fieldStats == nil {
                let ev = metadata.settings.evaluation
                if r.method == .piv {
                    // 🐱 PIV: one statistics cell per vector position
                    if let p = r.piv { fieldStats = SessionFieldStatistics(grid: p.cellGrid, minSamples: ev.minSamplesPerCell) }
                } else {
                    fieldStats = SessionFieldStatistics(grid: GridGeometry(roi: r.roi, cellSize: ev.cellSize), minSamples: ev.minSamplesPerCell)
                }
            }
            fieldStats?.add(r.samples, frameIndex: r.frameIndex, nominalInterval: r.metrics.sourceFPS.map { 1 / $0 },
                            includeDiffusion: r.method == .ptv)
        }
    }

    func record(field snap: FieldSnapshot, mmPerPixel: Double?) {
        queue.async { [self] in
            guard !finished else { return }
            let f: (Double, Int) -> String = CSVWriter.fmt
            for c in snap.cells where c.count > 0 {
                field.row([String(snapshotCount), f(snap.time, 6), String(c.i), String(c.j), f(c.x, 1), f(c.y, 1), f(c.u, 3), f(c.v, 3),
                           f(c.stdU, 3), f(c.stdV, 3), String(c.count), c.valid ? "1" : "0", c.outlier ? "1" : "0",
                           mmPerPixel.map { f(c.u * $0, 4) } ?? "", mmPerPixel.map { f(c.v * $0, 4) } ?? ""])
            }
            snapshotCount += 1
        }
    }

    func record(latency m: LatencyProbe.Measurement) {
        queue.async { [self] in
            guard !finished else { return }
            let f: (Double, Int) -> String = CSVWriter.fmt
            latency.row([f(m.screenChangeHostTime, 6), m.toBright ? "1" : "0", String(m.frameIndex), f(m.frameReceivedHostTime, 6),
                         f(m.analysisEndHostTime, 6), f(m.toReceiveMs, 2), f(m.toResultMs, 2)])
        }
    }

    public func log(_ level: LogLevel, _ message: String) {
        let t = HostClock.now()
        queue.async { [self] in
            guard !finished else { return }
            let utc = ISO8601DateFormatter().string(from: metadata.clockAnchor.wallClock(forHostTime: t))
            events.row([CSVWriter.fmt(t, 6), utc, level.rawValue, CSVWriter.quote(message)])
        }
    }

    func archive(_ au: CompressedAccessUnit) {
        queue.async { [self] in
            guard !finished else { return }
            archiver?.append(au)
        }
    }

    public func update(streamParameters: StreamParameters?, timestampUnit: String?, cameraInfo: [String: String]?) {
        queue.async { [self] in
            if let streamParameters { metadata.streamParameters = streamParameters }
            if let timestampUnit { metadata.timestampUnit = timestampUnit }
            if let cameraInfo { metadata.cameraInfo.merge(cameraInfo) { _, new in new } }
            writeMetadata()
        }
    }

    public func update(cameraRecording: SessionMetadata.CameraRecording) {
        queue.async { [self] in
            metadata.cameraRecording = cameraRecording
            writeMetadata()
        }
    }

    /// 🐱 Flush and close everything, then evaluate the whole measurement (evaluation.json, mean_field.csv,
    /// 🐱 speed_histogram.csv, heatmap_*.png, report.html). Returns the session folder and the evaluation.
    @discardableResult
    func finish(metrics: PipelineMetrics, sourceStatistics: SourceStatistics, latencyResults: [LatencyProbe.Measurement],
                settings: AnalysisSettings? = nil, background: CGImage? = nil, frameSize: CGSize? = nil,
                ensemble: EnsembleField? = nil, mask: MaskOverlay? = nil) async -> (URL, SessionEvaluation?) {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                finished = true
                c.resume()
            }
        }
        await archiver?.finish()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                [frames, particles, velocities, field, latency, events].forEach { $0.close() }
                pivVectors?.close()
                metadata.endedAt = Date()
                if let archiver {
                    for f in archiver.files { metadata.files[f] = f.hasSuffix(".mp4")
                        ? "compressed preview stream remuxed without re-encoding, camera-clock timing (re-open for offline analysis)"
                        : f.hasSuffix(".csv") ? "byte offset, size, raw camera timestamp and arrival time of each picture in the raw stream"
                        : "compressed preview stream exactly as received (Annex B)" }
                }
                let evaluation = writeEvaluation(metrics: metrics, settings: settings ?? metadata.settings, background: background,
                                                 frameSize: frameSize, ensemble: ensemble, mask: mask)
                metadata.summary = .init(metrics: metrics, sourceStatistics: sourceStatistics, velocitySamples: sampleCount,
                                         fieldSnapshots: snapshotCount, latencyProbe: latencyResults,
                                         previewArchive: archiver?.files ?? [], previewArchiveError: archiver?.mp4Error,
                                         evaluation: evaluation, settingsAtEnd: settings)
                writeMetadata()
                resultEvaluation = evaluation
                c.resume()
            }
        }
        return (directory, resultEvaluation)
    }

    private var resultEvaluation: SessionEvaluation?

    static func ensembleSummary(_ e: EnsembleField, cells ec: [CellStatistics], vectorAverage va: [CellStatistics], sameGrid: Bool) -> SessionEvaluation.EnsembleSummary {
        let f = e.field
        let ratios = (0..<f.count).filter { f.status[$0] == .valid }.map { Double(e.peakRatio[$0]) }.filter(\.isFinite)
        let peaks = (0..<f.count).filter { f.status[$0] == .valid }.map { Double(f.correlation[$0]) }
        var difference: Double?
        if sameGrid, ec.count == va.count {
            var diffs: [Double] = [], speeds: [Double] = []
            for k in 0..<ec.count where ec[k].valid && va[k].valid {
                diffs.append(hypot(ec[k].meanU - va[k].meanU, ec[k].meanV - va[k].meanV))
                speeds.append(va[k].speedOfMean)
            }
            if let d = GridKernels.median(of: diffs), let t = GridKernels.median(of: speeds), t > 1e-9 { difference = d / t }
        }
        return SessionEvaluation.EnsembleSummary(
            pairs: e.totalPairs, pairSpacingFrames: e.pairSpacing, windowPx: f.windowSize, validPercent: e.validPercent,
            replacedPercent: 100 * Double(f.replacedCount) / Double(max(1, f.count)),
            medianPeakRatio: GridKernels.median(of: ratios), medianPeakCorrelation: GridKernels.median(of: peaks),
            differenceFromVectorAverage: difference)
    }

    /// 🐱 Runs on the recorder queue at the end of a recording.
    private func writeEvaluation(metrics: PipelineMetrics, settings: AnalysisSettings, background: CGImage?, frameSize: CGSize?,
                                 ensemble: EnsembleField?, mask: MaskOverlay?) -> SessionEvaluation? {
        guard let stats = fieldStats else { return nil }
        aggregate.finishTracks(olderThan: Int.max)
        // 🐱 statistics live on the image grid (apparent positions, true velocities); with a container they are
        // 🐱 resampled on a regular grid in the measurement plane for the figures, tables and derived quantities
        let imageCells = stats.cells()
        var cells = imageCells, grid = stats.grid
        let refraction = RefractionMap(geometry: settings.container, calibrationMMPerPixel: settings.calibration.mmPerPixel)
        var rectified = false
        if let map = refraction, let r = map.rectify(cells: imageCells, grid: stats.grid) {
            cells = r.cells
            grid = r.grid
            rectified = true
        }
        var evaluation = SessionEvaluator.evaluate(stats: stats, cells: cells, frames: aggregate, metrics: metrics, settings: settings,
                                                   grid: grid, refraction: refraction, rectified: rectified)
        var ensembleCells: [CellStatistics]?
        var ensembleGrid: GridGeometry?
        if let e = ensemble, evaluation.piv != nil {
            let ec = e.cellStatistics()
            ensembleCells = ec
            ensembleGrid = e.field.cellGrid
            if let map = refraction, let r = map.rectify(cells: ec, grid: e.field.cellGrid) {
                ensembleCells = r.cells
                ensembleGrid = r.grid
            }
            evaluation.piv?.ensemble = Self.ensembleSummary(e, cells: ec, vectorAverage: imageCells, sameGrid: e.field.cellGrid == stats.grid)
            if let en = evaluation.piv?.ensemble, en.validPercent < 80 {
                evaluation.warnings.append(String(format: "Only %.0f %% of ensemble-correlation vectors are valid after %d pairs. Record longer, or check seeding / focus in the empty regions.", en.validPercent, en.pairs))
            }
        }
        let mm = settings.effectiveMMPerPixel
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        func write(_ name: String, _ data: Data?, _ description: String) {
            guard let data else { return }
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
            metadata.files[name] = description
        }
        write("evaluation.json", try? enc.encode(evaluation), "end-of-measurement evaluation: all numbers, warnings and verdict")
        write("mean_field.csv", ReportRenderer.meanFieldCSV(cells, mmPerPixel: mm).data(using: .utf8),
              rectified ? "time-averaged field on a regular grid in true measurement-plane coordinates (refraction corrected): mean, std, standard error, single-vector uncertainty, vorticity, divergence"
                        : "time-averaged field per cell over the whole recording: mean, std, standard error, single-vector uncertainty, vorticity, divergence")
        if rectified {
            write("mean_field_image_grid.csv", ReportRenderer.meanFieldCSV(imageCells, mmPerPixel: mm).data(using: .utf8),
                  "same statistics on the camera-image grid (x, y = apparent image position; velocities already refraction corrected; vorticity/divergence NOT corrected for the lens distortion — use mean_field.csv)")
        }
        write("mean_field.vtk", ReportRenderer.vtk(cells, grid: grid, mmPerPixel: mm, title: "LivePTV mean field \(metadata.label)").data(using: .utf8),
              "time-averaged field as a VTK structured-points file (ParaView / VisIt)")
        let unit = SpeedUnit.choose(mmPerPixel: mm, typicalPxPerSecond: stats.speeds.percentile(0.5) ?? 0)
        write("speed_histogram.csv", ReportRenderer.histogramCSV(stats.speeds.values, unit: unit).data(using: .utf8),
              "distribution of individual sample speeds")

        var images: [(title: String, file: String, png: Data)] = []
        let method = settings.method == .piv ? "PIV" : "PTV"
        let fieldData = FigureRenderer.FieldData(cells: cells, grid: grid, speedUnit: unit, mmPerPixel: mm)
        if let fig = FigureRenderer.summary(fieldData, title: "\(metadata.label.isEmpty ? "Session" : metadata.label): time-averaged velocity field (\(method), \(String(format: "%.1f", evaluation.measurement.cameraTimeS)) s)") {
            write("figure_summary.png", fig.png, "summary figure: (a) speed + vectors, (b) streamlines, (c) vorticity, (d) divergence")
            write("figure_summary.pdf", fig.pdf, "same figure as vector PDF (for papers/slides)")
            images.append(("Time-averaged velocity field", "figure_summary.png / .pdf", fig.png))
        }
        if let e = ensemble, let ec = ensembleCells {
            write("ensemble_field.csv", ReportRenderer.ensembleCSV(e, mmPerPixel: mm).data(using: .utf8),
                  "ensemble-correlation field (correlation planes averaged over all recorded pairs): displacement per pair, velocity, peak height and ratio, pairs per window")
            let eu = SpeedUnit.choose(mmPerPixel: mm, typicalPxPerSecond: GridKernels.median(of: ec.filter(\.valid).map(\.speedOfMean)) ?? 0)
            let data = FigureRenderer.FieldData(cells: ec, grid: ensembleGrid ?? e.field.cellGrid, speedUnit: eu, mmPerPixel: mm)
            if let fig = FigureRenderer.summary(data, title: "\(metadata.label.isEmpty ? "Session" : metadata.label): ensemble-correlation field (\(e.totalPairs) pairs, \(e.pairSpacing) frame\(e.pairSpacing == 1 ? "" : "s") apart)") {
                write("figure_ensemble.png", fig.png, "ensemble-correlation field: (a) speed + vectors, (b) streamlines, (c) vorticity, (d) divergence")
                write("figure_ensemble.pdf", fig.pdf, "same figure as vector PDF")
                images.append(("Ensemble-correlation field (µPIV)", "figure_ensemble.png / .pdf", fig.png))
            }
        }
        if let (fig, csv) = FigureRenderer.profiles(cells: cells, grid: grid, unit: unit, mmPerPixel: mm) {
            write("figure_profiles.png", fig.png, "velocity profiles along the centre lines with ±2 SE")
            write("figure_profiles.pdf", fig.pdf, "same figure as vector PDF")
            write("profiles.csv", csv.data(using: .utf8), "numbers behind figure_profiles")
            images.append(("Velocity profiles along the centre lines", "figure_profiles.png / .pdf", fig.png))
        }
        if let (fig, csv) = FigureRenderer.timeSeries(bins: aggregate.timeBins, unit: unit) {
            write("figure_timeseries.png", fig.png, "spatially averaged speed over time (steady-state check)")
            write("figure_timeseries.pdf", fig.pdf, "same figure as vector PDF")
            write("timeseries.csv", csv.data(using: .utf8), "numbers behind figure_timeseries")
            images.append(("Spatially averaged speed over time", "figure_timeseries.png / .pdf", fig.png))
        }
        // 🐱 the last camera frame with the mean field on top, to relate the field to the scene
        let size = frameSize ?? CGSize(width: stats.grid.originX + Double(stats.grid.columns) * stats.grid.cellSize,
                                       height: stats.grid.originY + Double(stats.grid.rows) * stats.grid.cellSize)
        if let layer = HeatmapLayer.from(session: imageCells, grid: stats.grid, quantity: .speed, unit: unit),
           let png = ReportRenderer.heatmapPNG(layer: layer, background: background, frameSize: size,
                                               title: "Mean speed over the camera image", arrows: imageCells) {
            write("overlay_on_image.png", png, "time-averaged speed and vectors drawn over the last camera frame")
            images.append(("Mean field over the camera image", "overlay_on_image.png", png))
        }
        // 🐱 measurement quality: masks, single-vector uncertainty, peak locking, container magnification
        if settings.method == .piv || mask != nil {
            let q = FigureRenderer.QualityInputs(
                background: background, frameSize: size, mask: mask, cells: imageCells, grid: stats.grid, unit: unit, mmPerPixel: mm,
                subpixel: evaluation.piv?.subpixelHistogram, peakLocking: evaluation.piv?.peakLockingIndex,
                diameterPx: evaluation.piv?.particleImageDiameterPx, uncertaintyMedianPx: evaluation.piv?.uncertaintyMedianPx,
                profile: refraction.map { $0.isIdentity ? [] : $0.lateralProfile() } ?? [], containerTitle: refraction?.summary)
            if let fig = FigureRenderer.quality(q, title: "\(metadata.label.isEmpty ? "Session" : metadata.label): measurement quality") {
                write("figure_quality.png", fig.png, "measurement quality: (a) masks, (b) single-vector uncertainty, (c) sub-pixel histogram / peak locking, (d) container magnification or noise share")
                write("figure_quality.pdf", fig.pdf, "same figure as vector PDF")
                images.append(("Measurement quality", "figure_quality.png / .pdf", fig.png))
            }
        }
        let methods = ReportRenderer.methodsText(evaluation, settings: settings, rectified: rectified)
        write("methods.txt", methods.data(using: .utf8), "generated methods paragraph describing the processing of this session (for papers / lab notes)")
        write("report.html", ReportRenderer.html(evaluation, label: metadata.label, images: images, methods: methods).data(using: .utf8),
              "human-readable evaluation report with figures (opens in Files / any browser)")
        return evaluation
    }
}
