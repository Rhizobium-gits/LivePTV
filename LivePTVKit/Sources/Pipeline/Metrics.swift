import Accelerate
import CoreVideo
import Foundation
import PTVCore

/// 🐱 Copy the ROI of the luminance plane out of a decoded frame (plane 0 of 420f, or a one-component buffer).
public enum LumaExtraction {
    public static func extract(_ pb: CVPixelBuffer, roi: PixelROI) -> LumaImage {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pb)
        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        guard let base else { return LumaImage(width: roi.width, height: roi.height, originX: roi.x, originY: roi.y,
                                               pixels: [Float](repeating: 0, count: roi.width * roi.height)) }
        return LumaImage(plane: base.assumingMemoryBound(to: UInt8.self), bytesPerRow: stride, roi: roi)
    }
}

/// 🐱 8-bit copy of the analysis region of a delivered frame (compact enough to keep ~30 frames for PIV pairs).
struct CompactLuma: Sendable {
    let width: Int
    let height: Int
    let originX: Int
    let originY: Int
    let index: Int
    let segment: Int
    let pts: Double
    let bytes: [UInt8]

    init?(_ pb: CVPixelBuffer, roi: PixelROI, index: Int, segment: Int, pts: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pb)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
        var b = [UInt8](repeating: 0, count: roi.width * roi.height)
        b.withUnsafeMutableBufferPointer { d in
            let src = base.assumingMemoryBound(to: UInt8.self)
            var r = 0
            while r < roi.height {
                memcpy(d.baseAddress! + r * roi.width, src + (roi.y + r) * stride + roi.x, roi.width)
                r += 1
            }
        }
        width = roi.width; height = roi.height; originX = roi.x; originY = roi.y
        self.index = index; self.segment = segment; self.pts = pts; bytes = b
    }

    func luma(downsample f: Int) -> LumaImage {
        var px = [Float](repeating: 0, count: bytes.count)
        bytes.withUnsafeBufferPointer { s in
            px.withUnsafeMutableBufferPointer { d in vDSP_vfltu8(s.baseAddress!, 1, d.baseAddress!, 1, vDSP_Length(bytes.count)) }
        }
        return LumaImage(width: width, height: height, originX: originX, originY: originY, pixels: px).downsampled(by: f)
    }

    func matches(_ roi: PixelROI) -> Bool { width == roi.width && height == roi.height && originX == roi.x && originY == roi.y }
}

/// 🐱 Rolling statistics over the last N values (median / p95 for latency display).
public struct RollingWindow: Sendable {
    private var values: [Double] = []
    private var next = 0
    public let capacity: Int

    public init(capacity: Int = 120) { self.capacity = capacity }

    public mutating func add(_ v: Double) {
        if values.count < capacity { values.append(v) } else { values[next] = v }
        next = (next + 1) % capacity
    }

    public var count: Int { values.count }

    public func percentile(_ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))]
    }

    public var median: Double? { percentile(0.5) }
}

/// 🐱 Events per second from host times of the last few seconds.
public struct RateMeter: Sendable {
    private var times: [Double] = []
    public let span: Double

    public init(span: Double = 2) { self.span = span }

    public mutating func tick(_ t: Double) {
        times.append(t)
        let cutoff = t - span
        if let firstKeep = times.firstIndex(where: { $0 >= cutoff }), firstKeep > 0 { times.removeFirst(firstKeep) }
    }

    public var rate: Double? {
        guard times.count >= 2, let a = times.first, let b = times.last, b > a else { return nil }
        return Double(times.count - 1) / (b - a)
    }
}

/// 🐱 Estimates frames the source never delivered (camera/network drops) from gaps in source timestamps.
public struct StreamGapDetector: Sendable {
    private var lastTime: Double?
    private var lastSegment: Int?
    private var intervals = RollingWindow(capacity: 60)
    public private(set) var missingFrames = 0
    public private(set) var gapEvents = 0

    public init() {}

    /// 🐱 Returns the number of frames missing just before this one.
    public mutating func observe(time: Double, segment: Int, nominalInterval: Double?) -> Int {
        defer { lastTime = time; lastSegment = segment }
        guard let lt = lastTime, lastSegment == segment else { return 0 }
        let dt = time - lt
        guard dt > 0 else { return 0 }
        let reference = nominalInterval ?? intervals.median ?? dt
        intervals.add(dt)
        let missing = Int((dt / reference).rounded()) - 1
        if missing > 0 {
            missingFrames += missing
            gapEvents += 1
            return missing
        }
        return 0
    }

    /// 🐱 Measured source frame rate (from source timestamps, not arrival times).
    public var sourceFPS: Double? { intervals.median.map { 1 / $0 } }
}

public struct PipelineMetrics: Codable, Sendable, Equatable {
    public var framesAnalyzed = 0
    /// 🐱 Frames the source delivered (≥ analysed when the analysis is slower than the camera).
    public var framesDelivered = 0
    /// 🐱 Decoded frames the analysis skipped because it was busy (hand-off buffer overwrites).
    public var analysisDrops = 0
    /// 🐱 Frames missing in the source timeline (camera or Wi-Fi drops).
    public var streamGapFrames = 0
    public var decodeErrors = 0
    public var discardedBeforeDecode = 0
    public var sourceFPS: Double?
    public var processingFPS: Double?
    /// 🐱 Medians over the last ~4 s, milliseconds. Receive = last byte of the frame arrived on the iPad.
    /// 🐱 Assembly wait = time until the picture was known complete (≈ one frame interval in safe mode).
    public var assemblyWaitMs: Double?
    public var decodeLatencyMs: Double?
    public var analysisDurationMs: Double?
    public var receiveToResultMs: Double?
    public var receiveToResultP95Ms: Double?
    /// 🐱 From the flash test: screen change → result, includes camera exposure, encode, Wi-Fi, decode.
    public var glassToResultMs: Double?
    public var particles = 0
    public var activeTracks = 0
    public var samples = 0
    public var timestampQuality: String = ""
    public var threshold: Float = 0
    /// 🐱 PIV only: share of valid (not replaced/invalid) vectors in the last field, and its vector count.
    public var pivValidPercent: Double?
    public var pivVectors = 0
    /// 🐱 PIV: current pair spacing (frames) and analysis resolution divisor (1 = full).
    public var pivPairSpacing = 1
    public var pivScale = 1
    /// 🐱 Camera shake removed from the last pair (px over the pair) and how it was estimated.
    public var shakePx: Double?
    public var shakeStatus = ""
    /// 🐱 Ensemble correlation (nil when off): pairs in the live average and its share of valid vectors.
    public var pivEnsemblePairs: Int?
    public var pivEnsembleValidPercent: Double?
    /// 🐱 Pairs summed so far in the running recording.
    public var pivEnsembleRecordedPairs: Int?
    /// 🐱 Share of the analysed image masked in the last frame (glare, glints, container, exclusions), percent.
    public var maskedPercent: Double?
    /// 🐱 PIV: median random uncertainty of the valid vectors of the last pair (px per pair).
    public var pivUncertaintyPx: Double?
    /// 🐱 PIV: particle-image diameter from the correlation-peak width (px).
    public var particleImageDiameterPx: Double?
    /// 🐱 PIV: where the correlation ran for the last pair, e.g. "GPU (Apple M4)", "GPU (Apple M4) + CPU", "CPU".
    public var pivDevice: String?
    /// 🐱 Container correction in effect (short text), nil when none.
    public var containerStatus: String?

    public init() {}
}
