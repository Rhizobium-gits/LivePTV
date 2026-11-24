import CameraKit
import Foundation
import PTVCore

/// 🐱 Parameters of the end-of-measurement evaluation.
public struct EvaluationSettings: Codable, Equatable, Sendable {
    /// 🐱 Grid cell size for the session-averaged field (px).
    public var cellSize: Double = 32
    /// 🐱 Cells need this many samples over the whole measurement to count as valid.
    public var minSamplesPerCell = 20
    /// 🐱 Fluid temperature and viscosity for the Stokes–Einstein size estimate (defaults: water at 20 °C).
    public var temperatureC = 20.0
    public var viscosityMPaS = 1.002

    public init() {}
}

/// 🐱 Per-frame numbers gathered while recording (cheap; O(1) memory per frame apart from fixed reservoirs).
struct FrameAggregate {
    var frames = 0
    var particlesSum = 0.0
    var particlesMin = Int.max
    var particlesMax = 0
    var particles = Reservoir(capacity: 20_000, seed: 0xF1)
    var latency = Reservoir(capacity: 20_000, seed: 0xF2)
    var qualities: [String: Int] = [:]
    var firstHost: Double?
    var lastHost: Double?
    /// 🐱 Camera-time span, summed over timeline segments.
    var sourceSpan = 0.0
    var segmentStart: (segment: Int, pts: Double)?
    var lastPTS: Double?
    var roiChanged = false
    var firstROI: PixelROI?
    var roiArea = 0
    // 🐱 track lengths (points per track), finalised when a track has not been seen for a few frames
    var trackSamples: [Int: (count: Int, lastFrame: Int)] = [:]
    var trackLengths = Reservoir(capacity: 50_000, seed: 0xF3)
    var tracksFinished = 0
    var lastPrune = 0
    // 🐱 PIV quality
    var method: AnalysisMethod = .ptv
    var pivFields = 0
    var pivValid = 0, pivReplaced = 0, pivInvalid = 0, pivMasked = 0
    var pivCorrelation = Reservoir(capacity: 50_000, seed: 0xF4)
    /// 🐱 per-vector random uncertainty (px, valid vectors) and per-field particle-image diameter (px)
    var pivSigma = Reservoir(capacity: 50_000, seed: 0xF6)
    var pivDiameter = Reservoir(capacity: 10_000, seed: 0xF7)
    var subpixel = [Int](repeating: 0, count: 20)
    // 🐱 masks (percent of the analysed image per frame)
    var maskedShare = Reservoir(capacity: 20_000, seed: 0xF8)
    var glareShare = Reservoir(capacity: 20_000, seed: 0xF9)
    var saturatedShare = Reservoir(capacity: 20_000, seed: 0xFA)
    var pivWindow = 0
    var pivStep = 0.0
    // 🐱 camera shake
    var shakeEnabled = false
    var shakePairs = 0
    var shakeApplied = 0
    var shakeLearning = 0
    var shakeMagnitudes = Reservoir(capacity: 20_000, seed: 0xF5)
    var shakeModels: [String: Int] = [:]
    var shakeRotationSq = 0.0
    /// 🐱 pivot sums as in ShakeCompensator: Σ(s² + θ²), ΣMᵀt, Σ|t|², pairs, and the grid centre the motions refer to
    var shakePivot = (m: 0.0, mtx: 0.0, mty: 0.0, tt: 0.0, n: 0)
    var shakeCenter: (x: Double, y: Double)?
    /// 🐱 Camera-time series of the spatial mean speed (valid samples), one bin per second.
    var timeBins: [Int: (sum: Double, sumSq: Double, n: Int)] = [:]

    mutating func add(_ r: ExperimentRecorder.FrameRecord) {
        frames += 1
        let n = r.particles.count
        particlesSum += Double(n)
        particlesMin = min(particlesMin, n)
        particlesMax = max(particlesMax, n)
        particles.add(Double(n))
        latency.add((r.analysisEnd - r.received) * 1000)
        qualities[r.quality, default: 0] += 1
        firstHost = firstHost ?? r.received
        lastHost = r.received
        if let s = segmentStart, s.segment == r.segment, let last = lastPTS {
            sourceSpan += max(0, r.pts - last)
        } else {
            segmentStart = (r.segment, r.pts)
        }
        lastPTS = r.pts
        method = r.method
        if r.piv != nil || r.method == .ptv, let sh = r.shake {
            shakePairs += 1
            if sh.applied {
                shakeApplied += 1
                shakeMagnitudes.add(sh.magnitudePx)
                shakeModels[sh.model, default: 0] += 1
                shakeRotationSq += sh.rotation * sh.rotation
                if sh.model != "translation" {
                    let sc = sh.scale, th = sh.rotation
                    shakePivot.m += sc * sc + th * th
                    shakePivot.mtx += sc * sh.tx - th * sh.ty
                    shakePivot.mty += th * sh.tx + sc * sh.ty
                    shakePivot.tt += sh.tx * sh.tx + sh.ty * sh.ty
                    shakePivot.n += 1
                }
                if shakeCenter == nil, let c = r.shakeCenter { shakeCenter = c }
            }
            if sh.source == "learning background" { shakeLearning += 1 }
        }
        if r.excludeFromStatistics { shakeEnabled = true }
        if let sh = r.shake, sh.applied || sh.source != "none" { shakeEnabled = true }
        if let p = r.piv {
            pivFields += 1
            pivWindow = p.windowSize
            pivStep = p.step
            for k in 0..<p.count {
                switch p.status[k] {
                case .valid: pivValid += 1; pivCorrelation.add(Double(p.correlation[k]))
                case .replaced: pivReplaced += 1
                case .invalid: pivInvalid += 1
                case .masked: pivMasked += 1
                }
                if p.status[k] == .valid, let s = p.sigma(k) { pivSigma.add(s) }
            }
            if let d = p.particleImageDiameterPx { pivDiameter.add(d) }
        }
        if let h = r.subpixelHistogram, h.count == subpixel.count {
            for i in 0..<h.count { subpixel[i] += h[i] }
        }
        if let m = r.maskStatistics {
            maskedShare.add(m.maskedPercent)
            glareShare.add(m.glarePercent)
            saturatedShare.add(m.saturatedPercent)
        }
        let good = r.samples.filter { !$0.outlier }
        if !good.isEmpty {
            let meanSpeed = good.map { hypot($0.u, $0.v) }.reduce(0, +) / Double(good.count)
            let bin = Int(sourceSpan)
            let e = timeBins[bin] ?? (0, 0, 0)
            timeBins[bin] = (e.sum + meanSpeed, e.sumSq + meanSpeed * meanSpeed, e.n + 1)
        }
        if firstROI == nil { firstROI = r.roi; roiArea = r.roi.width * r.roi.height } else if firstROI != r.roi { roiChanged = true }
        for s in r.samples {
            let e = trackSamples[s.trackID]
            trackSamples[s.trackID] = ((e?.count ?? 0) + 1, r.frameIndex)
        }
        if r.frameIndex - lastPrune >= 150 {
            finishTracks(olderThan: r.frameIndex - 10)
            lastPrune = r.frameIndex
        }
    }

    mutating func finishTracks(olderThan frame: Int) {
        for (id, e) in trackSamples where e.lastFrame < frame {
            trackLengths.add(Double(e.count + 1))   // 🐱 n samples = n+1 observations
            tracksFinished += 1
            trackSamples.removeValue(forKey: id)
        }
    }
}

/// 🐱 Numbers and verdict written at the end of every recording (evaluation.json, report.html).
public struct SessionEvaluation: Codable, Sendable {
    public struct Measurement: Codable, Sendable {
        public var cameraTimeS: Double
        public var wallTimeS: Double
        public var framesAnalyzed: Int
        public var measuredFPS: Double?
        public var analysisFPS: Double?
        public var missingFrames: Int
        public var missingFramePercent: Double
        public var analysisDrops: Int
        public var analysisDropPercent: Double
        public var decodeErrors: Int
        public var receiveToResultMedianMs: Double?
        public var receiveToResultP95Ms: Double?
        public var timestampQuality: [String: Int]
    }

    public struct Detection: Codable, Sendable {
        public var particlesPerFrameMean: Double
        public var particlesPerFrameMedian: Double?
        public var particlesPerFrameMin: Int
        public var particlesPerFrameMax: Int
        /// 🐱 per 10⁴ px² of analysed area
        public var densityPer10kPx: Double
        /// 🐱 per mm² (calibrated only)
        public var densityPerMM2: Double?
    }

    public struct Tracking: Codable, Sendable {
        public var velocitySamples: Int
        public var outlierSamples: Int
        public var outlierPercent: Double
        public var tracksFinished: Int
        public var trackLengthMedian: Double?
        public var trackLengthP90: Double?
        public var displacementMedianPx: Double?
        public var displacementP99Px: Double?
        public var maxDisplacementSettingPx: Double
    }

    public struct Field: Codable, Sendable {
        public var cellSizePx: Double
        public var cellSizeUm: Double?
        public var columns: Int
        public var rows: Int
        public var cellsWithData: Int
        public var validCells: Int
        public var coveragePercent: Double
        public var samplesPerValidCellMedian: Double?
        public var speedUnit: String
        /// 🐱 Area-averaged mean velocity over valid cells, in `speedUnit`
        public var meanU: Double?
        public var meanV: Double?
        public var meanSpeedOfMeanField: Double?
        public var maxSpeedOfMeanField: Double?
        /// 🐱 From all individual samples, in `speedUnit`
        public var sampleSpeedMedian: Double?
        public var sampleSpeedP95: Double?
        public var fluctuationRMSMedian: Double?
        public var turbulenceIntensityMedian: Double?
        /// 🐱 Median over valid cells of |SE of mean| / |mean|; < 0.1 means the mean field is converged to ~10 %.
        public var relativeUncertaintyMedian: Double?
        public var cellsBelow10PercentUncertainty: Int
        public var vorticityMaxAbs: Double?
        public var divergenceMeanAbs: Double?
        public var vorticityMeanAbs: Double?
    }

    public struct PIVQuality: Codable, Sendable {
        public var passes: [Int]
        public var finalWindowPx: Int
        public var vectorSpacingPx: Double
        public var pairSpacingFrames: Int
        public var fieldsComputed: Int
        public var validPercent: Double
        public var replacedPercent: Double
        public var invalidPercent: Double
        public var correlationMedian: Double?
        /// 🐱 camera-shake compensation over the recording
        public var shakeCompensation: Bool
        public var shakePairsCorrected: Int
        public var shakePairsLearning: Int
        public var shakeMedianPx: Double?
        public var shakeP95Px: Double?
        /// 🐱 Ensemble correlation over the recording (nil when off).
        public var ensemble: EnsembleSummary? = nil
        /// 🐱 Windows without a measurement because they were mostly masked (percent of all windows).
        public var maskedPercent: Double? = nil
        /// 🐱 Random uncertainty of single vectors from correlation statistics (px per pair, valid vectors).
        public var uncertaintyMedianPx: Double? = nil
        public var uncertaintyP95Px: Double? = nil
        /// 🐱 Particle-image diameter from the correlation-peak width (median, px).
        public var particleImageDiameterPx: Double? = nil
        /// 🐱 0 = sub-pixel displacements spread evenly, 1 = all locked to integers: 2·P(|frac| < 0.25) − 1.
        public var peakLockingIndex: Double? = nil
        /// 🐱 Histogram of the fractional displacement (20 bins over −0.5…0.5, analysed px).
        public var subpixelHistogram: [Int]? = nil
    }

    /// 🐱 Realistic-scene corrections applied in this recording.
    public struct Corrections: Codable, Sendable {
        public var background: String
        public var glareMasking: Bool
        public var saturationMasking: Bool
        public var exclusions: Int
        /// 🐱 percent of the analysed image (median over frames)
        public var maskedPercentMedian: Double?
        public var glarePercentMedian: Double?
        public var saturatedPercentMedian: Double?
        public var container: String
        public var refractionCorrected: Bool
        public var lateralMagnificationAtCentre: Double?
        /// 🐱 figures, mean_field.csv and derived quantities are on a regular grid in true plane coordinates
        public var rectifiedGrid: Bool
        public var lengthScaleSource: String
    }

    public struct EnsembleSummary: Codable, Sendable {
        public var pairs: Int
        public var pairSpacingFrames: Int
        public var windowPx: Int
        public var validPercent: Double
        public var replacedPercent: Double
        public var medianPeakRatio: Double?
        public var medianPeakCorrelation: Double?
        /// 🐱 Median |ensemble − vector average| ÷ median speed, over cells valid in both (same grid only).
        public var differenceFromVectorAverage: Double?
    }

    public struct Diffusion: Codable, Sendable {
        public var estimate: DiffusionEstimate
        /// 🐱 µm²/s (calibrated only)
        public var dUm2PerS: Double?
        public var standardErrorUm2PerS: Double?
        public var localizationNoiseUm: Double?
        /// 🐱 Stokes–Einstein hydrodynamic diameter, nm (calibrated and significant only)
        public var stokesEinsteinDiameterNm: Double?
        public var temperatureC: Double
        public var viscosityMPaS: Double
        public var interpretation: String
    }

    public var generatedAt: Date
    public var method: String
    public var piv: PIVQuality?
    public var mmPerPixel: Double?
    public var measurement: Measurement
    public var detection: Detection
    public var tracking: Tracking
    public var field: Field
    public var diffusion: Diffusion?
    public var warnings: [String]
    public var verdict: String
    public var corrections: Corrections? = nil
    /// 🐱 Camera motion removed over the recording (PIV and PTV); nil when shake compensation was off.
    public var cameraMotion: CameraMotion? = nil

    public struct CameraMotion: Codable, Sendable {
        public var pairsCorrected: Int
        public var pairsLearning: Int
        /// 🐱 how often each motion model was fitted
        public var models: [String: Int]
        public var shiftMedianPx: Double?
        public var shiftP95Px: Double?
        public var rotationRMSMrad: Double
        /// 🐱 Point the motion turned about (full-frame px; may lie outside the frame) when rotation and zoom about one
        /// 🐱 point explain ≥ 80 % of the fitted shifts, with that share.
        public var pivotXPx: Double?
        public var pivotYPx: Double?
        public var pivotRSquared: Double?
        public var pivotInsideFrame: Bool?
        public var text: String
    }
}

enum SessionEvaluator {
    /// 🐱 Summary of the camera motion that was removed, with the session pivot (as `ShakeCompensator.pivot`).
    static func cameraMotion(_ f: FrameAggregate, settings: AnalysisSettings) -> SessionEvaluation.CameraMotion? {
        guard f.shakeEnabled else { return nil }
        var px: Double?, py: Double?, r2: Double?, inside: Bool?
        let s = f.shakePivot
        if s.n >= 10, s.m > 0, s.tt > 0, let c = f.shakeCenter,
           (s.m / Double(s.n)).squareRoot() * max(1, hypot(c.x, c.y)) >= 0.05 {
            let qx = c.x - s.mtx / s.m, qy = c.y - s.mty / s.m
            let dx = qx - c.x, dy = qy - c.y
            let resid = s.tt + 2 * (dx * s.mtx + dy * s.mty) + s.m * (dx * dx + dy * dy)
            let rr = 1 - max(0, resid) / s.tt
            if rr >= 0.8 {
                px = qx; py = qy; r2 = rr
                if let roi = f.firstROI { inside = roi.contains(x: qx, y: qy) }
            }
        }
        let rot = f.shakeApplied > 0 ? (f.shakeRotationSq / Double(f.shakeApplied)).squareRoot() * 1000 : 0
        let models = f.shakeModels.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        var text = String(format: "%d pairs corrected (%@); shift median %.2f px, rotation RMS %.3f mrad.", f.shakeApplied,
                          models.isEmpty ? "none" : models, f.shakeMagnitudes.percentile(0.5) ?? 0, rot)
        if let px, let py, let r2 {
            text += String(format: " The camera motion turned about a point at (%.0f, %.0f) px%@ (rotation and zoom about it explain %.0f %% of the shifts).",
                           px, py, inside == false ? ", outside the frame" : "", r2 * 100)
        }
        return SessionEvaluation.CameraMotion(pairsCorrected: f.shakeApplied, pairsLearning: f.shakeLearning, models: f.shakeModels,
                                              shiftMedianPx: f.shakeMagnitudes.percentile(0.5), shiftP95Px: f.shakeMagnitudes.percentile(0.95),
                                              rotationRMSMrad: rot, pivotXPx: px, pivotYPx: py, pivotRSquared: r2, pivotInsideFrame: inside,
                                              text: text)
    }

    static func evaluate(stats: SessionFieldStatistics, cells: [CellStatistics], frames: FrameAggregate, metrics: PipelineMetrics,
                         settings: AnalysisSettings, grid: GridGeometry? = nil, refraction: RefractionMap? = nil,
                         rectified: Bool = false) -> SessionEvaluation {
        let mm = settings.effectiveMMPerPixel
        let grid = grid ?? stats.grid
        var warnings: [String] = []
        var critical = false

        // 🐱 measurement
        let wall = (frames.lastHost ?? 0) - (frames.firstHost ?? 0)
        let delivered = max(metrics.framesDelivered, frames.frames)
        let expected = delivered + metrics.streamGapFrames
        let missingPct = expected > 0 ? 100 * Double(metrics.streamGapFrames) / Double(expected) : 0
        let dropPct = delivered > 0 ? 100 * Double(max(0, delivered - frames.frames)) / Double(delivered) : 0
        let measurement = SessionEvaluation.Measurement(
            cameraTimeS: frames.sourceSpan, wallTimeS: wall, framesAnalyzed: frames.frames, measuredFPS: metrics.sourceFPS,
            analysisFPS: wall > 0 ? Double(frames.frames - 1) / wall : nil, missingFrames: metrics.streamGapFrames,
            missingFramePercent: missingPct, analysisDrops: metrics.analysisDrops, analysisDropPercent: dropPct,
            decodeErrors: metrics.decodeErrors, receiveToResultMedianMs: frames.latency.percentile(0.5),
            receiveToResultP95Ms: frames.latency.percentile(0.95), timestampQuality: frames.qualities)
        if missingPct > 1 { warnings.append(String(format: "%.1f %% of camera frames are missing (gaps in camera timestamps). Velocities stay correct (real time steps are used) but fewer samples were collected; check the link quality.", missingPct)) }
        if dropPct > 1 { warnings.append(String(format: "The analysis skipped %.1f %% of frames because it was busy. Reduce the analysis region or resolution for full temporal coverage.", dropPct)) }
        let goodTiming = (frames.qualities["source"] ?? 0) + (frames.qualities["synthetic"] ?? 0)
        if frames.frames > 0 && Double(goodTiming) / Double(frames.frames) < 0.95 {
            warnings.append("Less than 95 % of frames had verified camera timestamps; velocities from host arrival times include network jitter.")
            critical = true
        }
        if frames.frames < 30 { warnings.append("Very short measurement (\(frames.frames) frames)."); critical = true }

        // 🐱 detection
        let meanParticles = frames.frames > 0 ? frames.particlesSum / Double(frames.frames) : 0
        let area = Double(max(1, frames.roiArea))
        let density = meanParticles / area * 10_000
        let detection = SessionEvaluation.Detection(
            particlesPerFrameMean: meanParticles, particlesPerFrameMedian: frames.particles.percentile(0.5),
            particlesPerFrameMin: frames.particlesMin == Int.max ? 0 : frames.particlesMin, particlesPerFrameMax: frames.particlesMax,
            densityPer10kPx: density, densityPerMM2: mm.map { meanParticles / (area * $0 * $0) })
        let isPIV = frames.method == .piv
        if !isPIV && meanParticles < 30 { warnings.append(String(format: "Few particles per frame (%.0f). Increase seeding or illumination, or lower the detection threshold.", meanParticles)) }
        if !isPIV && density > 200 { warnings.append(String(format: "High particle-image density (%.0f per 10⁴ px²): overlapping images and ambiguous matches become likely.", density)) }

        // 🐱 tracking
        let total = stats.samples + stats.outliers
        let outlierPct = total > 0 ? 100 * Double(stats.outliers) / Double(total) : 0
        let dMed = stats.displacements.percentile(0.5), d99 = stats.displacements.percentile(0.99)
        let tracking = SessionEvaluation.Tracking(
            velocitySamples: stats.samples, outlierSamples: stats.outliers, outlierPercent: outlierPct, tracksFinished: frames.tracksFinished,
            trackLengthMedian: frames.trackLengths.percentile(0.5), trackLengthP90: frames.trackLengths.percentile(0.9),
            displacementMedianPx: dMed, displacementP99Px: d99, maxDisplacementSettingPx: settings.tracker.maxDisplacement)
        if outlierPct > 5 { warnings.append(String(format: "%.1f %% of velocity samples were rejected as outliers. Check the maximum displacement, seeding density and focus.", outlierPct)) }
        if !isPIV, let d99, d99 > 0.8 * settings.tracker.maxDisplacement {
            warnings.append(String(format: "The fastest displacements (p99 %.1f px/frame) approach the search radius (%.0f px). Fast particles may be lost: raise 'Max displacement'.", d99, settings.tracker.maxDisplacement))
        }
        if !isPIV, let dMed, dMed < 0.3 {
            warnings.append(String(format: "Typical displacement is only %.2f px/frame, close to the localisation noise (≈0.05–0.1 px). Velocity resolution is limited; increase magnification or analyse over longer time steps. For such slow particles, turn background subtraction off so they are not absorbed into the background.", dMed))
        }
        if total == 0 { warnings.append("No velocity samples were produced."); critical = true }

        // 🐱 PIV-specific quality
        var pivQuality: SessionEvaluation.PIVQuality?
        if isPIV {
            let total = Double(max(1, frames.pivValid + frames.pivReplaced + frames.pivInvalid))
            var q = SessionEvaluation.PIVQuality(
                passes: settings.piv.windowSizes, finalWindowPx: frames.pivWindow, vectorSpacingPx: frames.pivStep,
                pairSpacingFrames: settings.piv.pairSpacing, fieldsComputed: frames.pivFields,
                validPercent: 100 * Double(frames.pivValid) / total, replacedPercent: 100 * Double(frames.pivReplaced) / total,
                invalidPercent: 100 * Double(frames.pivInvalid) / total, correlationMedian: frames.pivCorrelation.percentile(0.5),
                shakeCompensation: frames.shakeEnabled, shakePairsCorrected: frames.shakeApplied, shakePairsLearning: frames.shakeLearning,
                shakeMedianPx: frames.shakeMagnitudes.percentile(0.5), shakeP95Px: frames.shakeMagnitudes.percentile(0.95))
            let all = Double(max(1, frames.pivValid + frames.pivReplaced + frames.pivInvalid + frames.pivMasked))
            q.maskedPercent = 100 * Double(frames.pivMasked) / all
            q.uncertaintyMedianPx = frames.pivSigma.percentile(0.5)
            q.uncertaintyP95Px = frames.pivSigma.percentile(0.95)
            q.particleImageDiameterPx = frames.pivDiameter.percentile(0.5)
            let hist = frames.subpixel
            let counted = hist.reduce(0, +)
            if counted >= 200 {
                let centre = hist[5..<15].reduce(0, +)
                q.peakLockingIndex = max(0, 2 * Double(centre) / Double(counted) - 1)
                q.subpixelHistogram = hist
            }
            pivQuality = q
            if let d = q.particleImageDiameterPx, d < 2, let pl = q.peakLockingIndex, pl > 0.1 {
                warnings.append(String(format: "Particle images are only ≈%.1f px across and the sub-pixel displacements cluster at integers (peak-locking index %.2f): velocities are biased towards whole pixels. Defocus slightly or use a smaller analysis scale so images span 2–4 px.", d, pl))
            }
            if let u = q.uncertaintyMedianPx, u > 0.2 {
                warnings.append(String(format: "The random uncertainty of single vectors is high (median %.2f px per pair). Improve image contrast / seeding, use larger windows, or rely on the time average (its uncertainty falls with √N).", u))
            }
            if let m = q.maskedPercent, m > 40 {
                warnings.append(String(format: "%.0f %% of the interrogation windows were masked (outside the fluid, wall band, glare or exclusions). Check the container outline and the glare level if that is more than expected.", m))
            }
            if frames.pivFields == 0 { warnings.append("No PIV field was computed (too few frames or the region is smaller than the first window)."); critical = true }
            if frames.shakeEnabled, frames.shakePairs - frames.shakeLearning > 10,
               Double(frames.shakeApplied) / Double(frames.shakePairs - frames.shakeLearning) < 0.5 {
                warnings.append("Camera-shake compensation was on but found too little static background in most frame pairs, so those vectors were not corrected. Draw a reference area on something that does not move (wall, ruler), or keep the camera steadier.")
            }
            if frames.shakeLearning > 0 {
                warnings.append("The first \(frames.shakeLearning) frame pairs were recorded while shake compensation was still learning the static background; they are excluded from the statistics. Start recording a few seconds after the preview to avoid this.")
            }
            if q.validPercent < 90 { warnings.append(String(format: "Only %.0f %% of PIV vectors are valid (%.0f %% replaced, %.0f %% invalid). Improve seeding density/contrast, or use larger windows.", q.validPercent, q.replacedPercent, q.invalidPercent)) }
            if let c = q.correlationMedian, c < 0.4 { warnings.append(String(format: "Low median correlation (%.2f): particle patterns change too much between the frames of a pair (out-of-plane motion, blur, too large displacement or too sparse seeding).", c)) }
            if let d99, d99 > Double(q.finalWindowPx) / 4 {
                warnings.append(String(format: "The largest displacements (p99 %.1f px per pair) exceed a quarter of the final window (%d px): keep displacements below w/4 (more passes / larger first window, or smaller pair spacing).", d99, q.finalWindowPx))
            }
            if let dMed, dMed < 0.5 {
                let suggested = max(2, Int((2.0 / max(dMed, 0.05)).rounded()) * max(1, settings.piv.pairSpacing))
                warnings.append(String(format: "Typical displacement per pair is only %.2f px; relative errors are large. Increase 'Pair spacing' (e.g. to %d frames), as when a 30 fps video is analysed at 6 fps.", dMed, min(30, suggested)))
            }
        }

        // 🐱 field
        let valid = cells.filter(\.valid)
        let speeds = valid.map(\.speedOfMean)
        let unit = SpeedUnit.choose(mmPerPixel: mm, typicalPxPerSecond: stats.speeds.percentile(0.5) ?? 0)
        func med(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.sorted()[a.count / 2] }
        let rel = valid.compactMap(\.relativeUncertainty)
        let vort = valid.compactMap(\.vorticity), div = valid.compactMap(\.divergence)
        let coverage = cells.isEmpty ? 0 : 100 * Double(valid.count) / Double(cells.count)
        let field = SessionEvaluation.Field(
            cellSizePx: grid.cellSize, cellSizeUm: mm.map { grid.cellSize * $0 * 1000 },
            columns: grid.columns, rows: grid.rows, cellsWithData: cells.filter { $0.count > 0 }.count,
            validCells: valid.count, coveragePercent: coverage, samplesPerValidCellMedian: med(valid.map { Double($0.count) }),
            speedUnit: unit.label,
            meanU: valid.isEmpty ? nil : valid.map(\.meanU).reduce(0, +) / Double(valid.count) * unit.factor,
            meanV: valid.isEmpty ? nil : valid.map(\.meanV).reduce(0, +) / Double(valid.count) * unit.factor,
            meanSpeedOfMeanField: speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count) * unit.factor,
            maxSpeedOfMeanField: speeds.max().map { $0 * unit.factor },
            sampleSpeedMedian: stats.speeds.percentile(0.5).map { $0 * unit.factor },
            sampleSpeedP95: stats.speeds.percentile(0.95).map { $0 * unit.factor },
            fluctuationRMSMedian: med(valid.map(\.fluctuationRMS)).map { $0 * unit.factor },
            turbulenceIntensityMedian: med(valid.compactMap(\.turbulenceIntensity)),
            relativeUncertaintyMedian: med(rel), cellsBelow10PercentUncertainty: rel.filter { $0 < 0.1 }.count,
            vorticityMaxAbs: vort.map(abs).max(), divergenceMeanAbs: div.isEmpty ? nil : div.map(abs).reduce(0, +) / Double(div.count),
            vorticityMeanAbs: vort.isEmpty ? nil : vort.map(abs).reduce(0, +) / Double(vort.count))
        if coverage < 50 { warnings.append(String(format: "Only %.0f %% of grid cells have enough samples (≥ %d). Measure longer, seed more, or use a larger cell size.", coverage, settings.evaluation.minSamplesPerCell)) }
        if coverage < 10 { critical = true }
        if let r = field.relativeUncertaintyMedian, r > 0.2 {
            warnings.append(String(format: "The time-averaged field is not converged (median statistical uncertainty %.0f %% of the local mean speed). Measure longer for a reliable mean field.", r * 100))
        }
        if let dv = field.divergenceMeanAbs, let vo = field.vorticityMeanAbs, vo > 0, dv / vo > 0.5, (field.meanSpeedOfMeanField ?? 0) > 0 {
            warnings.append(String(format: "Mean |divergence| is %.0f %% of mean |vorticity|. In a planar incompressible flow it should be small: out-of-plane motion, perspective or lens distortion, or noise dominates.", dv / vo * 100))
        }
        if frames.roiChanged { warnings.append("The analysis region changed during the recording; the session grid uses the first region.") }
        if mm == nil { warnings.append("No length calibration (mm per pixel): results are in pixels; physical speeds and particle size cannot be given.") }

        // 🐱 diffusion (Brownian motion)
        var diffusion: SessionEvaluation.Diffusion?
        if let est = stats.diffusion() {
            let s2 = mm.map { pow($0 * 1000, 2) }   // 🐱 px² → µm²
            var diameter: Double?
            var text: String
            if est.significant, let s2 {
                let dSI = est.d * s2 * 1e-12   // 🐱 m²/s
                let kB = 1.380649e-23, T = settings.evaluation.temperatureC + 273.15, eta = settings.evaluation.viscosityMPaS * 1e-3
                diameter = kB * T / (3 * .pi * eta * dSI) * 1e9
                text = "Brownian motion resolved. The size estimate assumes single spherical particles, the stated temperature/viscosity, and no velocity gradients within a cell."
            } else if est.significant {
                text = "Brownian motion resolved (in px²/s). Add a length calibration to obtain µm²/s and a Stokes–Einstein size."
            } else {
                text = "Brownian motion is not resolved: displacement scatter is explained by localisation noise. At this magnification, individual nanoparticles' diffusion cannot be measured (expected one-frame step ≈ √(2DΔt), e.g. ≈0.5 µm for 100 nm particles in water at 30 fps)."
            }
            diffusion = SessionEvaluation.Diffusion(
                estimate: est, dUm2PerS: s2.map { est.d * $0 }, standardErrorUm2PerS: s2.map { est.standardError * $0 },
                localizationNoiseUm: est.localizationNoisePx.flatMap { px in mm.map { px * $0 * 1000 } },
                stokesEinsteinDiameterNm: diameter, temperatureC: settings.evaluation.temperatureC,
                viscosityMPaS: settings.evaluation.viscosityMPaS, interpretation: text)
        }

        // 🐱 realistic-scene corrections
        let rp = settings.reflections
        let geometry = settings.container
        let scaleSource: String
        if geometry.shape == .cylinder, geometry.isConfigured, geometry.correctRefraction {
            scaleSource = String(format: "container silhouette (⌀%.2f mm outer)", geometry.outerDiameterMM)
        } else if settings.calibration.mmPerPixel != nil {
            scaleSource = settings.calibration.note.isEmpty ? "entered calibration" : "entered calibration: \(settings.calibration.note)"
        } else {
            scaleSource = "none (pixels)"
        }
        if geometry.shape == .cylinder, geometry.isConfigured, !geometry.correctRefraction {
            warnings.append("A round container is set but refraction correction is off: lateral positions and velocities inside the bottle are magnified (≈ n_fluid near the axis, more towards the walls).")
        }
        if geometry.shape != .none, !geometry.isConfigured {
            warnings.append("A container type is selected but its outline was not marked, so no wall mask or refraction correction was applied.")
        }
        let corrections = SessionEvaluation.Corrections(
            background: rp.background.title, glareMasking: rp.glareMasking, saturationMasking: rp.saturationMasking,
            exclusions: rp.exclusions.count, maskedPercentMedian: frames.maskedShare.percentile(0.5),
            glarePercentMedian: frames.glareShare.percentile(0.5), saturatedPercentMedian: frames.saturatedShare.percentile(0.5),
            container: refraction?.summary ?? (geometry.isConfigured ? geometry.shape.title : "none"),
            refractionCorrected: refraction.map { !$0.isIdentity } ?? false,
            lateralMagnificationAtCentre: refraction?.centreMagnification, rectifiedGrid: rectified, lengthScaleSource: scaleSource)

        let verdict = critical ? "Poor: see warnings before using these data"
            : warnings.filter { !$0.hasPrefix("No length calibration") }.isEmpty ? "Good"
            : "Usable with caveats"
        return SessionEvaluation(generatedAt: Date(), method: frames.method.rawValue, piv: pivQuality, mmPerPixel: mm, measurement: measurement, detection: detection, tracking: tracking,
                                 field: field, diffusion: diffusion, warnings: warnings, verdict: verdict, corrections: corrections,
                                 cameraMotion: cameraMotion(frames, settings: settings))
    }
}
