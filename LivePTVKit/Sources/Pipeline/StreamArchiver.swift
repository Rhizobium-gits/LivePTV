import AVFoundation
import CameraKit
import CoreMedia
import Foundation

/// 🐱 Preserves the compressed preview stream exactly as received:
/// 🐱  - `preview.h264|h265`: the Annex B bytes, bit-exact (nothing re-encoded)
/// 🐱  - `preview_index.csv`: byte offset, size, raw camera timestamp and arrival time of every picture
/// 🐱  - `preview.mp4`: the same samples remuxed (no re-encoding) with camera-clock timing, fragmented every
/// 🐱    second so a crash loses at most the last second. This file re-opens in `VideoFileSource` for offline
/// 🐱    re-analysis.
/// 🐱 Not thread-safe: the recorder calls it from its serial queue.
final class StreamArchiver {
    private let directory: URL
    private var rawHandle: FileHandle?
    private var rawURL: URL?
    private var rawOffset: UInt64 = 0
    private var index: CSVWriter?
    private var auCount = 0
    private(set) var codec: VideoCodec?

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var factory: H26xSampleFactory?
    private var normalizer = TimestampNormalizer()
    private var pendingUntilUnitKnown: [(CompressedAccessUnit, TimestampNormalizer.Output)] = []
    private var firstSeconds: Double?
    private var lastPTS: Double = -1
    private var segmentOffset: Double = 0
    private var lastSegment = 0
    private var startedKeyFrame = false
    private(set) var mp4Error: String?
    private(set) var mp4Samples = 0

    init(directory: URL) { self.directory = directory }

    var files: [String] {
        var f: [String] = []
        if let rawURL { f.append(rawURL.lastPathComponent) }
        if index != nil { f.append("preview_index.csv") }
        if writer != nil { f.append("preview.mp4") }
        return f
    }

    func append(_ au: CompressedAccessUnit) {
        if codec == nil {
            guard au.codec == .h264 || au.codec == .hevc else { return }
            codec = au.codec
            let url = directory.appendingPathComponent(au.codec == .hevc ? "preview.h265" : "preview.h264")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            rawHandle = try? FileHandle(forWritingTo: url)
            rawURL = url
            index = try? CSVWriter(url: directory.appendingPathComponent("preview_index.csv"),
                                   header: ["au_index", "byte_offset", "byte_length", "source_ts_raw", "received_host_s", "key_frame"])
            factory = H26xSampleFactory(codec: au.codec)
        }
        rawHandle?.write(au.annexB)
        index?.row([String(auCount), String(rawOffset), String(au.annexB.count), String(au.sourceTimestampRaw),
                    CSVWriter.fmt(au.receivedHostTime, 6), au.isKeyFrame ? "1" : "0"])
        rawOffset += UInt64(au.annexB.count)
        auCount += 1
        appendToMP4(au)
    }

    // 🐱 MARK: MP4 remux

    private func appendToMP4(_ au: CompressedAccessUnit) {
        guard mp4Error == nil else { return }
        let n = normalizer.normalize(raw: au.sourceTimestampRaw, hostTime: au.receivedHostTime)
        if n.quality == .provisional {
            pendingUntilUnitKnown.append((au, n))
            return
        }
        if !pendingUntilUnitKnown.isEmpty {
            // 🐱 Re-time the held pictures now that the unit is known.
            let held = pendingUntilUnitKnown
            pendingUntilUnitKnown.removeAll()
            for (a, _) in held {
                let seconds = normalizer.unusable ? a.receivedHostTime : Double(a.sourceTimestampRaw) * (normalizer.unit?.seconds ?? 1e-6)
                write(a, seconds: seconds, segment: n.segment)
            }
        }
        write(au, seconds: n.seconds, segment: n.segment)
    }

    private func write(_ au: CompressedAccessUnit, seconds rawSeconds: Double, segment: Int) {
        guard let factory else { return }
        if firstSeconds == nil {
            firstSeconds = rawSeconds
            lastSegment = segment
        } else if segment != lastSegment {
            // 🐱 Camera timeline restarted: continue the file timeline right after the last sample.
            segmentOffset = lastPTS + (normalizer.medianFrameInterval ?? 1.0 / 30) - (rawSeconds - firstSeconds!)
            lastSegment = segment
        }
        var pts = rawSeconds - firstSeconds! + segmentOffset
        if pts <= lastPTS { pts = lastPTS + 0.001 }   // 🐱 AVAssetWriter requires strictly increasing timestamps
        do {
            let nals = AnnexB.split(au.annexB)
            guard case let .sample(prepared) = try factory.prepare(nals: nals, pts: CMTime(seconds: pts, preferredTimescale: 90_000)) else { return }
            if !startedKeyFrame {
                guard prepared.isKeyFrame else { return }
                startedKeyFrame = true
            }
            if writer == nil { try startWriter(format: CMSampleBufferGetFormatDescription(prepared.sampleBuffer)!, at: pts) }
            guard let input, let writer, writer.status == .writing else {
                mp4Error = writer?.error?.localizedDescription ?? "writer not ready"
                return
            }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000),
                                            decodeTimeStamp: CMTime(seconds: pts, preferredTimescale: 90_000))
            var retimed: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: prepared.sampleBuffer,
                                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed)
            if input.isReadyForMoreMediaData, let retimed, input.append(retimed) {
                mp4Samples += 1
                lastPTS = pts
            } else if writer.status == .failed {
                mp4Error = writer.error?.localizedDescription ?? "append failed"
            }
        } catch {
            mp4Error = "\(error)"
        }
    }

    private func startWriter(format: CMFormatDescription, at pts: Double) throws {
        let url = directory.appendingPathComponent("preview.mp4")
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        w.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { throw CameraError.fileError("cannot add passthrough video track") }
        w.add(i)
        guard w.startWriting() else { throw CameraError.fileError(w.error?.localizedDescription ?? "startWriting failed") }
        w.startSession(atSourceTime: CMTime(seconds: pts, preferredTimescale: 90_000))
        writer = w
        input = i
    }

    func finish() async {
        try? rawHandle?.synchronize()
        try? rawHandle?.close()
        rawHandle = nil
        index?.close()
        // 🐱 Stream shorter than the unit-lock window: write what was held with host timing.
        if !pendingUntilUnitKnown.isEmpty {
            let held = pendingUntilUnitKnown
            pendingUntilUnitKnown.removeAll()
            for (a, _) in held { write(a, seconds: a.receivedHostTime, segment: lastSegment) }
        }
        if let writer, writer.status == .writing {
            input?.markAsFinished()
            await writer.finishWriting()
            if writer.status == .failed { mp4Error = writer.error?.localizedDescription }
        }
    }
}
