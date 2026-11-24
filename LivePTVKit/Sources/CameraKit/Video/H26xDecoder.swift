import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 🐱 Hardware H.264 / H.265 decoder (VideoToolbox), fed with Annex B access units.
/// 🐱 Not thread-safe: call from one serial queue. Decoding is synchronous so output order and timing are exact.
public final class H26xDecoder {
    public enum Result {
        case frame(CVPixelBuffer, isKeyFrame: Bool)
        /// 🐱 Access unit skipped on purpose (no picture, waiting for key frame / parameter sets).
        case skipped(reason: String)
    }

    public private(set) var codec: VideoCodec?
    private var factory: H26xSampleFactory?
    private var session: VTDecompressionSession?
    private var sessionGeneration = -1
    /// 🐱 After a reset or an error only a key frame can start a clean picture.
    public private(set) var waitingForKeyFrame = true

    public init(codec: VideoCodec? = nil) {
        self.codec = codec
        if let c = codec, c == .h264 || c == .hevc { factory = H26xSampleFactory(codec: c) }
    }

    deinit { invalidate() }

    public var dimensions: (width: Int, height: Int)? { factory?.dimensions }

    /// 🐱 Forget everything (new stream). The codec is re-detected from the next parameter sets / hint.
    public func reset() {
        invalidate()
        codec = nil
        factory = nil
        waitingForKeyFrame = true
    }

    /// 🐱 Decode one access unit. `codecHint` is used only until the codec is known.
    public func decode(annexB: Data, pts: CMTime, codecHint: VideoCodec? = nil) throws -> Result {
        let nals = AnnexB.split(annexB)
        guard !nals.isEmpty else { return .skipped(reason: "empty access unit") }
        if codec == nil {
            guard let detected = codecHint.flatMap({ $0 == .h264 || $0 == .hevc ? $0 : nil }) ?? AnnexB.detectCodec(nals: nals) else {
                return .skipped(reason: "codec not identified yet (no parameter sets seen)")
            }
            codec = detected
            factory = H26xSampleFactory(codec: detected)
        }
        guard let factory, let codec else { return .skipped(reason: "unsupported codec") }

        let outcome = try factory.prepare(nals: nals, pts: pts)
        let prepared: H26xSampleFactory.Prepared
        switch outcome {
        case .noPicture: return .skipped(reason: "no picture data")
        case .missingParameterSets: return .skipped(reason: "waiting for \(codec.rawValue) parameter sets")
        case let .sample(p): prepared = p
        }
        if waitingForKeyFrame && !prepared.isKeyFrame {
            return .skipped(reason: "waiting for key frame")
        }
        if session == nil || sessionGeneration != factory.formatGeneration {
            try makeSession(format: CMSampleBufferGetFormatDescription(prepared.sampleBuffer)!, generation: factory.formatGeneration)
        }

        var output: CVPixelBuffer?
        var status = decodeOnce(prepared.sampleBuffer, into: &output)
        if status == kVTInvalidSessionErr {
            // 🐱 iPadOS tears down hardware sessions when the app is backgrounded. Recreate once and retry.
            try makeSession(format: CMSampleBufferGetFormatDescription(prepared.sampleBuffer)!, generation: factory.formatGeneration)
            status = decodeOnce(prepared.sampleBuffer, into: &output)
        }
        guard status == noErr, let pixels = output else {
            waitingForKeyFrame = true
            throw CameraError.decoderFailure(status: status, detail: status == noErr ? "decoder returned no image" : "VTDecompressionSessionDecodeFrame")
        }
        waitingForKeyFrame = false
        return .frame(pixels, isKeyFrame: prepared.isKeyFrame)
    }

    private func decodeOnce(_ sample: CMSampleBuffer, into output: inout CVPixelBuffer?) -> OSStatus {
        guard let session else { return kVTInvalidSessionErr }
        var callbackStatus: OSStatus = noErr
        var image: CVImageBuffer?
        // 🐱 Without kVTDecodeFrame_EnableAsynchronousDecompression the handler runs before this call returns.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, img, _, _ in
            callbackStatus = st
            image = img
        }
        if status != noErr { return status }
        // 🐱 Make sure nothing is still pending inside the session before reading the result.
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        output = image
        return callbackStatus
    }

    private func makeSession(format: CMFormatDescription, generation: Int) throws {
        invalidate()
        let attributes: [CFString: Any] = [
            // 🐱 Bi-planar full range: plane 0 is the 8-bit luma image used directly by the analysis.
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &newSession)
        guard status == noErr, let s = newSession else {
            throw CameraError.decoderFailure(status: status, detail: "VTDecompressionSessionCreate")
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        sessionGeneration = generation
    }

    private func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        sessionGeneration = -1
    }
}
