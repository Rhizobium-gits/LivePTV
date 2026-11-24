import CoreMedia
import Foundation

/// 🐱 Keeps the latest H.264 (SPS/PPS) or HEVC (VPS/SPS/PPS) parameter sets and builds CoreMedia objects from
/// 🐱 Annex B access units. Shared by the decoder and the MP4 archiver so both see the stream identically.
public final class H26xSampleFactory {
    public let codec: VideoCodec
    private var parameterSets: [Int: Data] = [:]
    public private(set) var formatDescription: CMVideoFormatDescription?
    /// 🐱 Incremented every time the parameter sets change (resolution / profile change).
    public private(set) var formatGeneration = 0

    public init(codec: VideoCodec) {
        precondition(codec == .h264 || codec == .hevc, "H26xSampleFactory only handles H.264 / HEVC")
        self.codec = codec
    }

    public struct Prepared {
        public let sampleBuffer: CMSampleBuffer
        public let isKeyFrame: Bool
        public let formatChanged: Bool
    }

    public enum Outcome {
        case sample(Prepared)
        /// 🐱 Only parameter sets / SEI / AUD, no picture data.
        case noPicture
        /// 🐱 Picture data present but the parameter sets needed to describe it have not arrived yet.
        case missingParameterSets
    }

    /// 🐱 Feed one access unit (all NAL units of one picture).
    public func prepare(nals: [Data], pts: CMTime) throws -> Outcome {
        var changed = false
        var vcl: [Data] = []
        var key = false
        for nal in nals {
            let t = AnnexB.type(of: nal, codec: codec)
            if AnnexB.isParameterSet(t, codec: codec) {
                if parameterSets[t] != nal {
                    parameterSets[t] = nal
                    changed = true
                }
            } else if AnnexB.isVCL(t, codec: codec) {
                vcl.append(nal)
                if AnnexB.isKeyFrame(t, codec: codec) { key = true }
            }
        }
        if changed {
            formatDescription = nil
            formatGeneration += 1
        }
        if formatDescription == nil {
            formatDescription = try makeFormatDescription()
        }
        guard !vcl.isEmpty else { return .noPicture }
        guard let format = formatDescription else { return .missingParameterSets }
        let sample = try makeSampleBuffer(data: AnnexB.lengthPrefixed(vcl), format: format, pts: pts, keyFrame: key)
        return .sample(Prepared(sampleBuffer: sample, isKeyFrame: key, formatChanged: changed))
    }

    public var dimensions: (width: Int, height: Int)? {
        guard let f = formatDescription else { return nil }
        let d = CMVideoFormatDescriptionGetDimensions(f)
        return (Int(d.width), Int(d.height))
    }

    private func makeFormatDescription() throws -> CMVideoFormatDescription? {
        let order: [Int] = codec == .hevc ? [32, 33, 34] : [7, 8]
        let sets = order.compactMap { parameterSets[$0] }
        guard sets.count == order.count else { return nil }
        var desc: CMFormatDescription?
        var status: OSStatus = noErr
        // 🐱 Keep the Data alive and pass stable pointers for the duration of the call.
        let arrays = sets.map { [UInt8]($0) }
        let sizes = arrays.map { $0.count }
        func withPointers<R>(_ i: Int, _ acc: [UnsafePointer<UInt8>], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
            if i == arrays.count { return body(acc) }
            return arrays[i].withUnsafeBufferPointer { withPointers(i + 1, acc + [$0.baseAddress!], body) }
        }
        withPointers(0, []) { ptrs in
            if codec == .hevc {
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            } else {
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard status == noErr, let d = desc else {
            throw CameraError.decoderFailure(status: status, detail: "invalid \(codec.rawValue) parameter sets")
        }
        return d
    }

    private func makeSampleBuffer(data: Data, format: CMVideoFormatDescription, pts: CMTime, keyFrame: Bool) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else {
            throw CameraError.decoderFailure(status: status, detail: "block buffer allocation")
        }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else {
            throw CameraError.decoderFailure(status: status, detail: "block buffer copy")
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw CameraError.decoderFailure(status: status, detail: "sample buffer creation")
        }
        if !keyFrame, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
