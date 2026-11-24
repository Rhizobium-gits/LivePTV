import CameraKit
import CoreImage
import CoreVideo
import Foundation
import PTVCore

public enum AnalysisMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 🐱 Particle image velocimetry: cross-correlation of interrogation windows → dense regular vector field.
    case piv
    /// 🐱 Particle tracking velocimetry: individual particles → Lagrangian tracks (needed for Brownian diffusion).
    case ptv
    public var id: String { rawValue }
    public var title: String { self == .piv ? "PIV (cross-correlation)" : "PTV (particle tracking)" }
}

public enum PIVResolution: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, full, half, quarter
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "Auto (keep live)"
        case .full: return "Full"
        case .half: return "1/2"
        case .quarter: return "1/4"
        }
    }
}

public struct AnalysisSettings: Codable, Equatable, Sendable {
    public var method: AnalysisMethod = .piv
    public var piv = PIVParameters()
    /// 🐱 PIV analysis resolution. Auto lowers it while the live analysis is slower than ~8 fps (not during recording).
    public var pivResolution: PIVResolution = .auto
    public var shake = ShakeParameters()
    public var detector = DetectorParameters()
    public var tracker = TrackerParameters()
    public var field = FieldParameters()
    public var calibration = Calibration()
    /// 🐱 Nil = whole frame.
    public var roi: PixelROI?
    /// 🐱 Compute velocities from host arrival times when the source has no usable timestamps. Off by default
    /// 🐱 because Wi-Fi jitter then becomes velocity noise; frames.csv records which timing was used.
    public var allowHostArrivalTiming = false
    /// 🐱 Field snapshot interval in source seconds.
    public var fieldInterval = 0.2
    /// 🐱 End-of-measurement evaluation (session-averaged grid, Stokes–Einstein inputs).
    public var evaluation = EvaluationSettings()
    /// 🐱 Static reflections, glare, glints and exclusions (temporal background + masks).
    public var reflections = ReflectionParameters()
    /// 🐱 The container the flow is seen through (wall mask, refraction correction, length scale).
    public var container = ContainerGeometry()
    /// 🐱 Version of these settings, for migrating saved settings when a default changes.
    public var schema = AnalysisSettings.currentSchema

    public init() {}

    /// 🐱 2: intensity capping off by default. 3: reflections and container (new keys take their defaults).
    public static let currentSchema = 3

    /// 🐱 Length scale in effect: a marked round container defines it (outer diameter ÷ silhouette width, exact at
    /// 🐱 the silhouette, where rays graze the wall); otherwise the entered calibration.
    public var effectiveMMPerPixel: Double? {
        if container.correctRefraction, let s = RefractionMap.cylinderScale(container) { return s }
        return calibration.mmPerPixel
    }

    /// 🐱 Saved settings from an older app version: keys it did not have take today's defaults (instead of the whole
    /// 🐱 settings being discarded), and defaults that changed since are migrated. Nil if the data is not settings.
    public static func decodeMerged(_ data: Data) -> AnalysisSettings? {
        guard var saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(AnalysisSettings()),
              let defaults = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any] else { return nil }
        let savedSchema = saved["schema"] as? Int ?? 1
        if savedSchema < 2, var piv = saved["piv"] as? [String: Any] {
            piv.removeValue(forKey: "intensityCapping")
            saved["piv"] = piv
        }
        func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
            var out = base
            for (k, v) in over {
                if let b = base[k] as? [String: Any], let o = v as? [String: Any] { out[k] = merge(b, o) } else { out[k] = v }
            }
            return out
        }
        var merged = merge(defaults, saved)
        merged["schema"] = currentSchema
        guard let md = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(AnalysisSettings.self, from: md)
    }
}

/// 🐱 Everything the UI needs to draw one analysed frame.
public struct FrameResult: @unchecked Sendable {
    public let frame: VideoFrame
    public let roi: PixelROI
    public let particles: [Particle]
    public let trackIDs: [Int]
    public let samples: [VelocitySample]
    /// 🐱 Recent positions of active tracks (for tails), at most `maxTails` tracks.
    public let tails: [[(x: Double, y: Double)]]
    public let field: FieldSnapshot?
    public let metrics: PipelineMetrics
    public let velocityEnabled: Bool
    public var shake: ShakeEstimate?
    /// 🐱 What is masked (refreshed every few frames), nil when nothing is.
    public var mask: MaskOverlay? = nil
    /// 🐱 Container in effect (for drawing its outline and inner-wall limits).
    public var container: RefractionMap? = nil
}

/// 🐱 Source → ROI → detection → tracking → velocity field → recording, one frame at a time on a background task.
/// 🐱 The analysis never blocks the source: live sources drop (and count) frames when the analysis is slower.
public final class AnalysisPipeline: @unchecked Sendable {
    public let source: CameraVideoSource
    public let latencyProbe = LatencyProbe()
    public var onResult: (@Sendable (FrameResult) -> Void)? {
        get { lock.withLock { _onResult } }
        set { lock.withLock { _onResult = newValue } }
    }
    public var maxTails = 400

    private let lock = NSLock()
    private var _onResult: (@Sendable (FrameResult) -> Void)?
    private var _settings: AnalysisSettings
    private var _recorder: ExperimentRecorder?
    private var _metrics = PipelineMetrics()
    private var _resetBackgroundRequested = false
    /// 🐱 Latest full mask picture (for the report's quality figure).
    private var _maskForReport: MaskOverlay?
    private var _lastPrepared: PIVImage?
    private var _lastFrame: VideoFrame?
    private var _onPreviewFrame: (@Sendable (VideoFrame) -> Void)?
    // 🐱 Statistics of every delivered frame (not only analysed ones), and recent frames for PIV pairs.
    private var _deliveredGaps = StreamGapDetector()
    private var _framesDelivered = 0
    private var _ring: [CompactLuma] = []
    private var lastGapTotalAtAnalysis = 0

    /// 🐱 Every frame the source delivers, at the camera's rate (for a smooth display), before analysis drops.
    public var onPreviewFrame: (@Sendable (VideoFrame) -> Void)? {
        get { lock.withLock { _onPreviewFrame } }
        set { lock.withLock { _onPreviewFrame = newValue } }
    }
    private var task: Task<Void, Never>?

    // 🐱 Analysis-task state.
    private let pivEngine = PIVEngine()
    private let shakeCompensator = ShakeCompensator()
    private var pivK = 1
    private var pivAutoScale = 1
    private var framesAtScale = 0
    private var pivAnalysisEMA: Double?
    private var recentDisplacements: [Double] = []
    private var fieldsSinceKChange = 0
    private var lastShake: ShakeEstimate?
    private var pivField: PIVFieldAverager?
    /// 🐱 Field shown live: PIV updates it with every analysed pair; recorded snapshots stay at `fieldInterval`.
    private var displayField: FieldSnapshot?
    /// 🐱 Ensemble correlation (under `lock`: `finishRecording` takes its session sum from another task).
    private var _ensemble: EnsembleCorrelator?
    private var ensembleLive: EnsembleField?
    private var pivFieldCount = 0
    /// 🐱 Realistic-scene corrections: temporal background and masks, container refraction.
    private let reflection = ReflectionSuppressor()
    private var refractionCache: (geometry: ContainerGeometry, mm: Double?, map: RefractionMap?)?
    private var staticMaskCache: (key: String, mask: [Float]?)?
    private var lastMaskStatistics: MaskStatistics?
    private var maskOverlay: MaskOverlay?
    private var maskOverlayAge = 0
    private let detector: ParticleDetector
    private let tracker: ParticleTracker
    private var field: VelocityFieldAccumulator?
    private var lastField: FieldSnapshot?
    private var lastFieldTime = -Double.infinity
    private var appliedSettings: AnalysisSettings
    private var lastSegment: Int?
    private var processingRate = RateMeter(span: 3)
    private var assemblyWait = RollingWindow(capacity: 120)
    private var decodeLatency = RollingWindow(capacity: 120)
    private var analysisDuration = RollingWindow(capacity: 120)
    private var receiveToResult = RollingWindow(capacity: 120)

    public init(source: CameraVideoSource, settings: AnalysisSettings = AnalysisSettings()) {
        self.source = source
        _settings = settings
        appliedSettings = settings
        detector = ParticleDetector(parameters: settings.detector)
        tracker = ParticleTracker(parameters: settings.tracker)
    }

    public var settings: AnalysisSettings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    public var metrics: PipelineMetrics { lock.withLock { _metrics } }
    public var recorder: ExperimentRecorder? { lock.withLock { _recorder } }
    public var isRunning: Bool { lock.withLock { task != nil } }

    /// 🐱 Start consuming frames. The source must already be previewing (or be started by the caller after).
    public func start() {
        lock.withLock {
            guard task == nil else { return }
            _metrics = PipelineMetrics()
            _deliveredGaps = StreamGapDetector()
            _framesDelivered = 0
            _ring.removeAll()
            lastGapTotalAtAnalysis = 0
            source.setPreviewHandler { [weak self] f in self?.delivered(f) }
            task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, let frame = await self.source.nextFrame() {
                    self.process(frame)
                }
                self.lock.withLock { self.task = nil }
            }
        }
    }

    public func stop() async {
        let t = lock.withLock { task }
        t?.cancel()
        await t?.value
        lock.withLock { task = nil }
    }

    // 🐱 MARK: recording

    public func attach(recorder: ExperimentRecorder) { lock.withLock { _recorder = recorder } }

    public struct RecordingResult: Sendable {
        public let folder: URL
        public let evaluation: SessionEvaluation?
    }

    /// 🐱 Detach and finalise the current recording, including the end-of-measurement evaluation.
    @discardableResult
    public func finishRecording() async -> RecordingResult? {
        guard let r = lock.withLock({ () -> ExperimentRecorder? in
            let r = _recorder
            _recorder = nil
            return r
        }) else { return nil }
        var ensemble = lock.withLock { _ensemble }?.endSession(owner: ObjectIdentifier(r), parameters: settings.piv)
        if ensemble != nil { ensemble = correctedEnsemble(ensemble!, settings: settings) }
        let maskPicture = lock.withLock { _maskForReport }
        let frame = lock.withLock { _lastFrame }
        var background: CGImage?
        var size: CGSize?
        if let f = frame {
            let ci = CIImage(cvPixelBuffer: f.pixelBuffer)
            background = CIContext().createCGImage(ci, from: ci.extent)
            size = CGSize(width: f.width, height: f.height)
        }
        let (url, evaluation) = await r.finish(metrics: metrics, sourceStatistics: source.statistics(), latencyResults: latencyProbe.results,
                                               settings: settings, background: background, frameSize: size, ensemble: ensemble,
                                               mask: maskPicture)
        return RecordingResult(folder: url, evaluation: evaluation)
    }

    /// 🐱 Forward compressed pictures and log lines from the source to the active recording.
    public func handleSourceEvent(_ event: SourceEvent) {
        guard let r = recorder else { return }
        switch event {
        case let .compressedAccessUnit(au): r.archive(au)
        case let .log(level, message): r.log(level, message)
        case let .stateChanged(s): r.log(.info, "state: \(s)")
        case let .streamParameters(p):
            r.log(.info, "stream: \(p.codec.rawValue) \(p.width)x\(p.height) \(p.nominalFPS.map { String(format: "%.2f fps", $0) } ?? "") [\(p.origin)]")
            r.update(streamParameters: p, timestampUnit: nil, cameraInfo: nil)
        }
    }

    // 🐱 MARK: per-frame work

    /// 🐱 Runs for every delivered frame on the source's thread: stream statistics, PIV frame ring, display.
    private func delivered(_ f: VideoFrame) {
        let s = settings
        var copy: CompactLuma?
        if s.method == .piv {
            let roi = (s.roi ?? PixelROI.full(width: f.width, height: f.height)).clamped(toWidth: f.width, height: f.height)
            copy = CompactLuma(f.pixelBuffer, roi: roi, index: f.index, segment: f.segment, pts: f.presentationTime)
        }
        let keep = (s.piv.autoPairSpacing ? max(1, s.piv.maxPairSpacing) : max(1, s.piv.pairSpacing)) + 3
        let handler: (@Sendable (VideoFrame) -> Void)? = lock.withLock {
            _ = _deliveredGaps.observe(time: f.presentationTime, segment: f.segment, nominalInterval: nil)
            _framesDelivered += 1
            if let copy {
                _ring.append(copy)
                if _ring.count > keep { _ring.removeFirst(_ring.count - keep) }
            }
            return _onPreviewFrame
        }
        handler?(f)
    }

    private func process(_ frame: VideoFrame) {
        let t0 = HostClock.now()
        let s = settings
        if s != appliedSettings { apply(s) }
        if lock.withLock({ () -> Bool in defer { _resetBackgroundRequested = false }; return _resetBackgroundRequested }) {
            detector.reset()
            reflection.reset()
            // 🐱 also restart the live ensemble average (never a running recording's sum)
            lock.withLock { if _ensemble?.sessionOwner == nil { _ensemble = nil } }
            ensembleLive = nil
        }
        if !s.piv.ensemble.enabled || s.method != .piv, ensembleLive != nil || lock.withLock({ _ensemble != nil }) {
            lock.withLock { _ensemble = nil }
            ensembleLive = nil
        }

        let roi = (s.roi ?? PixelROI.full(width: frame.width, height: frame.height)).clamped(toWidth: frame.width, height: frame.height)
        if field == nil || field!.roi != roi || field!.parameters != s.field {
            field = VelocityFieldAccumulator(roi: roi, parameters: s.field)
            lastField = nil
            tracker.reset()
        }
        if frame.segment != lastSegment {
            // 🐱 New timeline (stream restart / unit lock / file loop): never connect tracks across it.
            tracker.reset()
            field?.reset()
            pivField?.reset()
            displayField = nil
            lastFieldTime = -.infinity
            lastSegment = frame.segment
        }

        lock.withLock { _lastFrame = frame }
        // 🐱 PIV works on the 8-bit copies taken at delivery (at the analysis resolution); PTV on the full frame
        let pivScale = pivScaleFor(s)
        let current: CompactLuma? = s.method == .piv
            ? (lock.withLock { _ring.last { $0.index == frame.index && $0.segment == frame.segment && $0.matches(roi) } }
               ?? CompactLuma(frame.pixelBuffer, roi: roi, index: frame.index, segment: frame.segment, pts: frame.presentationTime))
            : nil
        let luma = current.map { $0.luma(downsample: pivScale) } ?? LumaExtraction.extract(frame.pixelBuffer, roi: roi)

        let timingOK: Bool
        switch frame.timestampQuality {
        case .source, .synthetic: timingOK = true
        case .hostArrival: timingOK = s.allowHostArrivalTiming
        case .provisional: timingOK = false
        }
        var particles: [Particle] = []
        var step = TrackingStep(trackIDs: [], samples: [], started: 0, ended: 0)
        var piv: PIVField?
        var saveInstantaneous = false
        var subpixel: [Int]?
        let container = refractionMap(s)
        if s.method == .ptv {
            particles = detector.detect(luma)
            if needsSuppression(s, image: luma), let mask = suppress(luma, settings: s, update: true).mask {
                // 🐱 detections on glare, glints, walls or exclusions are not tracers
                let w = luma.width, h = luma.height
                particles = particles.filter { p in
                    let i = Int((p.x - Double(luma.originX)).rounded()), j = Int((p.y - Double(luma.originY)).rounded())
                    return i >= 0 && j >= 0 && i < w && j < h && mask[j * w + i] > 0.5
                }
            }
            step.trackIDs = [Int](repeating: 0, count: particles.count)
            if timingOK {
                step = tracker.update(particles: particles, time: frame.presentationTime, frameIndex: frame.index)
                if let c = container { step.samples = c.correct(step.samples) }
                field?.add(step.samples)
                if frame.presentationTime - lastFieldTime >= s.fieldInterval, let f = field {
                    lastField = f.snapshot(at: frame.presentationTime)
                    lastFieldTime = frame.presentationTime
                }
            }
        } else {
            // 🐱 PIV between this frame and the camera frame k frames earlier (from the delivered-frame ring), so
            // 🐱 pairs stay consecutive in camera time even when the analysis skips frames. k adapts to slow flows.
            if !s.piv.autoPairSpacing { pivK = max(1, s.piv.pairSpacing) }
            let k = pivK
            pivEngine.parameters = s.piv
            let partner = lock.withLock { _ring.last { $0.segment == frame.segment && $0.index <= frame.index - k && $0.matches(roi) } }
            var pairStart = frame.presentationTime
            if timingOK, let p = partner, frame.presentationTime > p.pts {
                pairStart = p.pts
                let actualK = max(1, frame.index - p.index)
                let pa = preparedImage(p, luma: nil, scale: pivScale, settings: s, current: false)
                let pb = current.map { preparedImage($0, luma: luma, scale: pivScale, settings: s, current: true) } ?? pivEngine.prepare(luma)
                lock.withLock { _lastPrepared = pb }
                piv = pivEngine.compute(a: pa, b: pb, dt: frame.presentationTime - p.pts)
                if var field = piv {
                    subpixel = field.subpixelHistogram(scale: pivScale)
                    // 🐱 background subtraction removes the static texture the camera-motion fit needs: measure the
                    // 🐱 static windows again on the raw frames
                    var remeasure: (([Int]) -> [Int: (dx: Double, dy: Double)])?
                    if s.shake.enabled && s.reflections.background != .off && !reflection.isWarmingUp {
                        let rawField = field, partner = p, cur = current, lumaNow = luma
                        remeasure = { [unowned self] idx in
                            let ra = self.rawPrepared(partner, luma: nil, scale: pivScale, parameters: s.piv)
                            let rb = cur.map { self.rawPrepared($0, luma: lumaNow, scale: pivScale, parameters: s.piv) } ?? self.pivEngine.prepare(lumaNow)
                            return self.pivEngine.measureWindows(a: ra, b: rb, field: rawField, indices: idx)
                        }
                    }
                    lastShake = shakeCompensator.compensate(&field, pairSpacing: actualK, parameters: s.shake, remeasure: remeasure)
                    adaptPairSpacing(field, scale: pivScale, settings: s)
                    if s.piv.ensemble.enabled && actualK == k {
                        ensembleStep(a: pa, b: pb, dt: frame.presentationTime - p.pts, k: k, field: field, settings: s)
                    }
                    // 🐱 everything above works in apparent image px; from here on displacements are true (plane) px
                    container?.correct(&field)
                    piv = field
                }
            }
            if let p = piv {
                let mid = (frame.presentationTime + pairStart) / 2
                step.samples = p.samples(frameIndex: frame.index, midTime: mid)
                let g = p.cellGrid
                var fp = s.field
                fp.cellSize = g.cellSize
                fp.minSamples = 1
                if pivField == nil || pivField!.grid != g || pivField!.parameters != fp {
                    pivField = PIVFieldAverager(grid: g, parameters: fp)
                }
                pivField!.add(p, time: mid)
                let snap = pivField!.snapshot(at: frame.presentationTime)
                displayField = snap
                if s.piv.ensemble.enabled, let e = ensembleLive {
                    displayField = e.field.snapshot(time: frame.presentationTime, counts: e.pairs)
                }
                if frame.presentationTime - lastFieldTime >= s.fieldInterval {
                    lastField = snap
                    lastFieldTime = frame.presentationTime
                }
                pivFieldCount += 1
                saveInstantaneous = s.piv.saveEveryNthField > 0 && pivFieldCount % s.piv.saveEveryNthField == 1 % s.piv.saveEveryNthField
            }
        }

        let (gapTotal, deliveredFPS, deliveredCount) = lock.withLock { (_deliveredGaps.missingFrames, _deliveredGaps.sourceFPS, _framesDelivered) }
        let missing = gapTotal - lastGapTotalAtAnalysis
        lastGapTotalAtAnalysis = gapTotal
        let t1 = HostClock.now()
        processingRate.tick(t1)
        assemblyWait.add((frame.timing.assembledHostTime - frame.timing.receivedHostTime) * 1000)
        decodeLatency.add((frame.timing.decodedHostTime - frame.timing.assembledHostTime) * 1000)
        analysisDuration.add((t1 - t0) * 1000)
        receiveToResult.add((t1 - frame.timing.receivedHostTime) * 1000)

        let stats = source.statistics()
        var m = lock.withLock { _metrics }
        m.framesAnalyzed += 1
        m.analysisDrops = source.analysisDropCount
        m.streamGapFrames = gapTotal
        m.framesDelivered = deliveredCount
        m.decodeErrors = stats.decodeErrors
        m.discardedBeforeDecode = stats.framesDiscardedBeforeDecode
        m.sourceFPS = deliveredFPS
        m.processingFPS = processingRate.rate
        m.assemblyWaitMs = assemblyWait.median
        m.decodeLatencyMs = decodeLatency.median
        m.analysisDurationMs = analysisDuration.median
        m.receiveToResultMs = receiveToResult.median
        m.receiveToResultP95Ms = receiveToResult.percentile(0.95)
        m.particles = particles.count
        m.activeTracks = tracker.tracks.count
        m.samples = step.samples.count
        m.timestampQuality = frame.timestampQuality.rawValue
        m.threshold = detector.lastThreshold
        if let p = piv {
            m.pivValidPercent = 100 * Double(p.validCount) / Double(max(1, p.count))
            m.pivVectors = p.count
        }
        m.maskedPercent = lastMaskStatistics?.maskedPercent
        m.containerStatus = container.map { c in
            c.isIdentity ? "wall mask" : String(format: "refraction corrected (centre ×%.3f)", c.centreMagnification ?? .nan)
        }
        if let p = piv {
            m.pivUncertaintyPx = p.medianSigma
            m.particleImageDiameterPx = p.particleImageDiameterPx
            m.pivDevice = pivEngine.lastDevice
        }
        if s.method == .piv {
            m.pivPairSpacing = pivK
            m.pivScale = pivScale
            m.shakePx = lastShake?.applied == true ? lastShake?.magnitudePx : nil
            // 🐱 pairs effectively in the live average (exponential memory of `livePairs`)
            m.pivEnsemblePairs = s.piv.ensemble.enabled ? min(ensembleLive?.totalPairs ?? 0, max(1, s.piv.ensemble.livePairs)) : nil
            m.pivEnsembleRecordedPairs = s.piv.ensemble.enabled ? lock.withLock({ _ensemble })?.sessionPairs : nil
            m.pivEnsembleValidPercent = s.piv.ensemble.enabled ? ensembleLive?.validPercent : nil
            m.shakeStatus = s.shake.enabled ? (lastShake.map { $0.applied ? "\($0.source), \($0.backgroundWindows) windows" : $0.source } ?? "waiting") : "off"
            updateAutoScale(t1 - t0, settings: s)
        }

        let meanLuma = luma.meanIntensity
        if let measurement = latencyProbe.observe(meanLuma: meanLuma, frameIndex: frame.index,
                                                  frameReceivedHostTime: frame.timing.receivedHostTime, analysisEndHostTime: t1) {
            recorder?.record(latency: measurement)
        }
        m.glassToResultMs = latencyProbe.medianToResultMs ?? m.glassToResultMs
        lock.withLock { _metrics = m }

        if let r = recorder {
            r.record(ExperimentRecorder.FrameRecord(
                frameIndex: frame.index, segment: frame.segment, quality: frame.timestampQuality.rawValue,
                sourceRaw: frame.timing.sourceTimestampRaw, pts: frame.presentationTime, received: frame.timing.receivedHostTime,
                assembled: frame.timing.assembledHostTime, decoded: frame.timing.decodedHostTime, analysisStart: t0, analysisEnd: t1, missingBefore: missing, roi: roi,
                meanLuma: meanLuma, threshold: detector.lastThreshold, particles: particles, trackIDs: step.trackIDs,
                tracks: tracker.tracks.count, samples: step.samples, metrics: m, mmPerPixel: s.effectiveMMPerPixel,
                method: s.method, piv: piv, saveInstantaneous: saveInstantaneous, pairSpacing: pivK, pivScale: pivScale,
                shake: s.method == .piv ? lastShake : nil,
                // 🐱 while the shake compensator is still learning, vectors are uncorrected: keep them out of statistics
                excludeFromStatistics: s.method == .piv && s.shake.enabled && piv != nil && lastShake?.source == "learning background",
                maskStatistics: lastMaskStatistics, subpixelHistogram: subpixel))
            if let f = lastField, f.time == frame.presentationTime { r.record(field: f, mmPerPixel: s.effectiveMMPerPixel) }
        }

        // 🐱 mask picture: rebuilt every few frames (glints change per frame, but the eye needs no more)
        maskOverlayAge += 1
        if maskOverlayAge >= 6 || (maskOverlay == nil && lastMaskStatistics != nil) {
            maskOverlayAge = 0
            maskOverlay = lastMaskStatistics == nil ? nil : MaskOverlay.make(from: reflection, step: 2)
            if let mo = maskOverlay { lock.withLock { _maskForReport = mo } }
        }
        if let handler = onResult {
            let tails = tracker.tracks.prefix(maxTails).filter { $0.points.count >= 2 }.map { $0.points.map { (x: $0.x, y: $0.y) } }
            handler(FrameResult(frame: frame, roi: roi, particles: particles, trackIDs: step.trackIDs, samples: step.samples,
                                tails: tails, field: s.method == .piv ? displayField : lastField, metrics: m, velocityEnabled: timingOK,
                                shake: s.method == .piv ? lastShake : nil, mask: maskOverlay, container: container))
        }
    }

    // 🐱 MARK: PIV adaptation

    private func pivScaleFor(_ s: AnalysisSettings) -> Int {
        switch s.pivResolution {
        case .full: return 1
        case .half: return 2
        case .quarter: return 4
        case .auto: return pivAutoScale
        }
    }

    /// 🐱 One pair into the ensemble correlation (live average, plus the recording's sum while recording).
    private func ensembleStep(a: PIVImage, b: PIVImage, dt: Double, k: Int, field: PIVField, settings s: AnalysisSettings) {
        var ens = lock.withLock { _ensemble }
        if ens == nil || !ens!.matches(image: b, parameters: s.piv, pairSpacing: k) {
            ens = EnsembleCorrelator(image: b, parameters: s.piv, pairSpacing: k, initial: field)
            lock.withLock { _ensemble = ens }
            ensembleLive = nil
        }
        guard let ens else { return }
        // 🐱 pairs taken while shake compensation is still learning stay out (as in the statistics)
        if s.shake.enabled && lastShake?.source == "learning background" { return }
        if let r = recorder {
            if ens.sessionOwner != ObjectIdentifier(r) { ens.beginSession(owner: ObjectIdentifier(r)) }
        } else if ens.sessionOwner != nil {
            ens.discardSession()
        }
        // 🐱 camera motion of this pair, applied to the second window so shake does not smear the averaged peak
        var shift: ((Double, Double) -> (Double, Double))?
        if let sh = lastShake, sh.applied {
            let c = shakeCompensator.center, sc = Double(b.scale), ox = Double(b.originX), oy = Double(b.originY)
            shift = { x, y in
                let d = sh.displacement(x: ox + (x + 0.5) * sc - 0.5, y: oy + (y + 0.5) * sc - 0.5, cx: c.x, cy: c.y)
                return (d.0 / sc, d.1 / sc)
            }
        }
        ens.add(a: a, b: b, dt: dt, parameters: s.piv, shift: shift)
        ensembleLive = ens.liveField(parameters: s.piv, adaptOffsets: ens.sessionOwner == nil).map { correctedEnsemble($0, settings: s) }
    }

    /// 🐱 Ensemble field with the current mask applied and displacements corrected for the container.
    private func correctedEnsemble(_ e: EnsembleField, settings s: AnalysisSettings) -> EnsembleField {
        var e = e
        if let img = lock.withLock({ _lastPrepared }) { e.field.applyMask(of: img, maxMaskedFraction: s.piv.maxMaskedFraction) }
        refractionMap(s)?.correct(&e.field)
        return e
    }

    // 🐱 MARK: realistic-scene corrections

    /// 🐱 Container mapping for these settings (cached; rebuilt when the geometry or calibration changes).
    private func refractionMap(_ s: AnalysisSettings) -> RefractionMap? {
        lock.withLock {
            if let c = refractionCache, c.geometry == s.container, c.mm == s.calibration.mmPerPixel { return c.map }
            let map = RefractionMap(geometry: s.container, calibrationMMPerPixel: s.calibration.mmPerPixel)
            refractionCache = (s.container, s.calibration.mmPerPixel, map)
            return map
        }
    }

    private func needsSuppression(_ s: AnalysisSettings, image: LumaImage) -> Bool {
        let r = s.reflections
        return r.background != .off || r.glareMasking || r.saturationMasking || !r.exclusions.isEmpty || s.container.isConfigured
    }

    /// 🐱 Background removal and masks for one analysed image. `update` only for frames in time order.
    private func suppress(_ img: LumaImage, settings s: AnalysisSettings, update: Bool) -> (image: LumaImage, mask: [Float]?) {
        guard needsSuppression(s, image: img) else {
            lastMaskStatistics = nil
            return (img, nil)
        }
        let key = "\(img.width)x\(img.height)@\(img.originX),\(img.originY)/\(img.scale)|\(s.reflections.exclusions)|\(s.container)|\(String(describing: s.calibration.mmPerPixel))"
        let staticMask: [Float]?
        if let c = staticMaskCache, c.key == key {
            staticMask = c.mask
        } else {
            staticMask = StaticMask.build(width: img.width, height: img.height, originX: img.originX, originY: img.originY, scale: img.scale,
                                          exclusions: s.reflections.exclusions, container: refractionMap(s))
            staticMaskCache = (key, staticMask)
        }
        reflection.parameters = s.reflections
        let r = reflection.process(img, staticMask: staticMask, updateBackground: update)
        if update { lastMaskStatistics = reflection.lastStatistics }
        return r
    }

    /// 🐱 Each frame is pre-processed once and reused as the earlier frame of a later pair.
    private struct PreparedFrame {
        let index: Int
        let segment: Int
        let scale: Int
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
        let parameters: PIVParameters
        let reflections: ReflectionParameters
        let container: ContainerGeometry
        let image: PIVImage
    }
    private var preparedCache: [PreparedFrame] = []

    /// 🐱 `current`: the frame being analysed now (its background update happens here, in time order); the earlier
    /// 🐱 frame of a pair is normally a cache hit from when it was current.
    private func preparedImage(_ c: CompactLuma, luma: LumaImage?, scale: Int, settings s: AnalysisSettings, current: Bool) -> PIVImage {
        let parameters = s.piv
        if let hit = preparedCache.last(where: {
            $0.index == c.index && $0.segment == c.segment && $0.scale == scale && $0.originX == c.originX && $0.originY == c.originY
                && $0.width == c.width && $0.height == c.height && $0.parameters == parameters
                && $0.reflections == s.reflections && $0.container == s.container
        }) {
            return hit.image
        }
        pivEngine.parameters = parameters
        let raw = suppress(luma ?? c.luma(downsample: scale), settings: s, update: current)
        let image = pivEngine.prepare(raw.image, mask: raw.mask)
        preparedCache.append(PreparedFrame(index: c.index, segment: c.segment, scale: scale, originX: c.originX, originY: c.originY,
                                           width: c.width, height: c.height, parameters: parameters, reflections: s.reflections,
                                           container: s.container, image: image))
        if preparedCache.count > 4 { preparedCache.removeFirst(preparedCache.count - 4) }
        return image
    }

    /// 🐱 Frames pre-processed WITHOUT background subtraction or masks (for the camera-motion fit).
    private var rawCache: [(index: Int, segment: Int, scale: Int, x: Int, y: Int, w: Int, h: Int, parameters: PIVParameters, image: PIVImage)] = []

    private func rawPrepared(_ c: CompactLuma, luma: LumaImage?, scale: Int, parameters: PIVParameters) -> PIVImage {
        if let hit = rawCache.last(where: { $0.index == c.index && $0.segment == c.segment && $0.scale == scale && $0.x == c.originX
                && $0.y == c.originY && $0.w == c.width && $0.h == c.height && $0.parameters == parameters }) {
            return hit.image
        }
        pivEngine.parameters = parameters
        let image = pivEngine.prepare(luma ?? c.luma(downsample: scale))
        rawCache.append((c.index, c.segment, scale, c.originX, c.originY, c.width, c.height, parameters, image))
        if rawCache.count > 4 { rawCache.removeFirst(rawCache.count - 4) }
        return image
    }

    /// 🐱 Auto resolution: if the live analysis runs slower than ~8 fps, halve the analysed resolution (down to 1/4).
    /// 🐱 Never during a recording, so one recording has one resolution.
    private func updateAutoScale(_ seconds: Double, settings s: AnalysisSettings) {
        // 🐱 only for live sources: files and offline analysis always use the chosen/full resolution
        guard s.pivResolution == .auto, source.info.isLive else { return }
        pivAnalysisEMA = pivAnalysisEMA.map { 0.8 * $0 + 0.2 * seconds } ?? seconds
        framesAtScale += 1
        guard recorder == nil, framesAtScale >= 8, pivAutoScale < 4, let ema = pivAnalysisEMA, ema > 1.0 / 8 else { return }
        pivAutoScale *= 2
        framesAtScale = 0
        pivAnalysisEMA = nil
        pivField = nil
        shakeCompensator.reset()
    }

    /// 🐱 Auto pair spacing: aim for ≈ target displacement (analysed px) so slow motion is resolved, but keep the
    /// 🐱 largest displacements below a quarter window.
    private func adaptPairSpacing(_ f: PIVField, scale: Int, settings s: AnalysisSettings) {
        // 🐱 an ensemble recording sums correlation planes of one pair spacing: keep it fixed while recording
        guard s.piv.autoPairSpacing, !(s.piv.ensemble.enabled && recorder != nil) else { return }
        var raw: [Double] = []
        raw.reserveCapacity(f.count)
        let inv = 1 / Double(scale)
        var k = 0
        while k < f.count {
            if f.status[k] == .valid { raw.append(hypot(f.dx[k], f.dy[k]) * inv) }
            k += 1
        }
        let mags = GridKernels.sorted(raw)
        guard mags.count >= 10 else { return }
        recentDisplacements.append(mags[mags.count / 2])
        if recentDisplacements.count > 5 { recentDisplacements.removeFirst() }
        fieldsSinceKChange += 1
        guard fieldsSinceKChange >= 5 else { return }
        let med = recentDisplacements.sorted()[recentDisplacements.count / 2]
        let p95 = mags[min(mags.count - 1, Int(Double(mags.count) * 0.95))]
        let quarter = Double(s.piv.finalWindow) / 4
        var newK = pivK
        if p95 > 0.8 * quarter && pivK > 1 {
            newK = max(1, pivK / 2)
        } else if med < s.piv.targetDisplacementPx / 2 && pivK < s.piv.maxPairSpacing {
            let factor = min(4, s.piv.targetDisplacementPx / max(med, 0.05))
            newK = min(s.piv.maxPairSpacing, max(pivK + 1, Int((Double(pivK) * factor).rounded())))
            // 🐱 never so large that the fastest vectors would break the quarter-window rule
            let p95perFrame = p95 / Double(pivK)
            if p95perFrame > 0 { newK = min(newK, max(pivK, Int(0.8 * quarter / p95perFrame))) }
        }
        if newK != pivK {
            pivK = newK
            fieldsSinceKChange = 0
            recentDisplacements.removeAll()
        }
    }

    private func apply(_ s: AnalysisSettings) {
        if s.detector != appliedSettings.detector {
            let backgroundChanged = s.detector.polarity != appliedSettings.detector.polarity
                || s.detector.backgroundSubtraction != appliedSettings.detector.backgroundSubtraction
            detector.parameters = s.detector
            if backgroundChanged { detector.reset() }
        }
        if s.tracker != appliedSettings.tracker {
            tracker.parameters = s.tracker
        }
        if s.roi != appliedSettings.roi { detector.reset(); shakeCompensator.reset() }
        if s.pivResolution != appliedSettings.pivResolution {
            pivAutoScale = 1; framesAtScale = 0; pivAnalysisEMA = nil; shakeCompensator.reset()
        }
        if s.method != appliedSettings.method { pivK = 1; shakeCompensator.reset() }
        appliedSettings = s
    }

    /// 🐱 Forget the learned background (e.g. after the lighting changed). Applied on the next frame by the
    /// 🐱 analysis task, which owns the detector.
    public func resetBackground() { lock.withLock { _resetBackgroundRequested = true } }
}
