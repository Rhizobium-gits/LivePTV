import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import CameraKit

@Suite struct AnnexBTests {
    @Test func splitsAndDetectsH264() throws {
        let nals = AnnexB.split(try Fixtures.h264)
        #expect(nals.count > 30)
        #expect(AnnexB.detectCodec(nals: nals) == .h264)
        #expect(AnnexB.containsKeyFrame(nals, codec: .h264))
        #expect(!nals.contains { $0.isEmpty })
    }

    @Test func detectsHEVC() throws {
        let nals = AnnexB.split(try Fixtures.hevc)
        #expect(AnnexB.detectCodec(nals: nals) == .hevc)
        #expect(AnnexB.containsKeyFrame(nals, codec: .hevc))
    }

    @Test func splitRoundTrip() {
        let nals = [Data([0x67, 1, 2, 3]), Data([0x68, 4]), Data([0x65, 0, 0, 3, 1, 9])]
        #expect(AnnexB.split(AnnexB.join(nals)) == nals)
        // 🐱 3-byte start codes and trailing zeros are handled too.
        let mixed = Data([0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0])
        #expect(AnnexB.split(mixed) == [Data([0x67, 1]), Data([0x68, 2])])
    }

    @Test func fixturesGroupIntoThirtyPictures() throws {
        #expect(Fixtures.accessUnits(try Fixtures.h264, codec: .h264).count == 30)
        #expect(Fixtures.accessUnits(try Fixtures.hevc, codec: .hevc).count == 30)
    }
}

@Suite struct AssemblerTests {
    @Test func safeModeEmitsOnTimestampChange() {
        var a = AccessUnitAssembler(mode: .safe)
        #expect(a.push(timestamp: 1, payload: Data([1]), hostTime: 0).isEmpty)
        #expect(a.push(timestamp: 1, payload: Data([2]), hostTime: 0.001).isEmpty)
        let out = a.push(timestamp: 2, payload: Data([3]), hostTime: 0.033)
        #expect(out == [.init(timestamp: 1, data: Data([1, 2]), receivedHostTime: 0.001, packetCount: 2)])
        #expect(a.flushIfIdle(now: 10, idleSeconds: 0.001) == nil)   // 🐱 safe mode never flushes early
        #expect(a.flush()?.data == Data([3]))
    }

    @Test func lowLatencyFlushAndLateSliceFallback() {
        var a = AccessUnitAssembler(mode: .lowLatency)
        _ = a.push(timestamp: 10, payload: Data([1]), hostTime: 1.000)
        #expect(a.flushIfIdle(now: 1.001, idleSeconds: 0.004) == nil)
        #expect(a.flushIfIdle(now: 1.005, idleSeconds: 0.004)?.data == Data([1]))
        // 🐱 A slice of the already-emitted picture arrives: dropped, counted, back to safe mode.
        #expect(a.push(timestamp: 10, payload: Data([2]), hostTime: 1.006).isEmpty)
        #expect(a.lateSliceCount == 1)
        #expect(a.mode == .safe && a.fellBackToSafe)
        _ = a.push(timestamp: 11, payload: Data([3]), hostTime: 1.033)
        #expect(a.flushIfIdle(now: 2, idleSeconds: 0.004) == nil)
    }
}

@Suite struct TimestampTests {
    @Test func classifiesUnits() {
        #expect(TimestampNormalizer.classify(medianDelta: 33_333) == .microseconds)
        #expect(TimestampNormalizer.classify(medianDelta: 33) == .milliseconds)
        #expect(TimestampNormalizer.classify(medianDelta: 33_333_333) == .nanoseconds)
        #expect(TimestampNormalizer.classify(medianDelta: 1) == nil)
        #expect(TimestampNormalizer.classify(medianDelta: 900_000) == nil)
    }

    @Test(arguments: [(Int64(33_333), TimestampNormalizer.Unit.microseconds), (Int64(33), .milliseconds)])
    func locksUnitAndBumpsSegment(step: Int64, unit: TimestampNormalizer.Unit) {
        var n = TimestampNormalizer(framesToLock: 6)
        var outs: [TimestampNormalizer.Output] = []
        for i in 0..<10 { outs.append(n.normalize(raw: 1_000_000 + Int64(i) * step, hostTime: Double(i))) }
        #expect(n.unit == unit)
        #expect(outs[0].quality == .provisional)
        #expect(outs[5].quality == .source)
        #expect(outs[6].segment == outs[5].segment && outs[5].segment == outs[4].segment + 1)
        let dt = outs[9].seconds - outs[8].seconds
        #expect(abs(dt - Double(step) * unit.seconds) < 1e-9)
    }

    @Test func backwardJumpStartsNewSegment() {
        var n = TimestampNormalizer(framesToLock: 3)
        for i in 0..<5 { _ = n.normalize(raw: 5_000_000 + Int64(i) * 33_333, hostTime: 0) }
        let before = n.segment
        let out = n.normalize(raw: 100, hostTime: 0)
        #expect(out.segment == before + 1)
    }

    @Test func implausibleSpacingFallsBackToHostTime() {
        var n = TimestampNormalizer(framesToLock: 3)
        var last: TimestampNormalizer.Output?
        for i in 0..<5 { last = n.normalize(raw: Int64(i) * 900_000, hostTime: 42 + Double(i)) }
        #expect(n.unusable)
        #expect(last?.quality == .hostArrival && last?.seconds == 46)
    }
}

@Suite struct DecoderTests {
    @Test(arguments: [VideoCodec.h264, .hevc])
    func decodesFixture(codec: VideoCodec) throws {
        let stream = codec == .h264 ? try Fixtures.h264 : try Fixtures.hevc
        let units = Fixtures.accessUnits(stream, codec: codec)
        let decoder = H26xDecoder()
        var frames = 0
        for (i, unit) in units.enumerated() {
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            if case let .frame(pb, _) = try decoder.decode(annexB: AnnexB.join(unit), pts: pts) {
                #expect(CVPixelBufferGetWidth(pb) == 160 && CVPixelBufferGetHeight(pb) == 120)
                #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                frames += 1
            }
        }
        #expect(decoder.codec == codec)
        #expect(frames == 30)
    }

    @Test func waitsForKeyFrameAfterJoiningMidStream() throws {
        let units = Fixtures.accessUnits(try Fixtures.h264, codec: .h264)
        let decoder = H26xDecoder()
        // 🐱 Start at picture 3 (a P-frame): nothing decodes until the next IDR (picture 15, GOP 15).
        var firstDecoded: Int?
        for i in 3..<units.count {
            if case .frame = try decoder.decode(annexB: AnnexB.join(units[i]), pts: CMTime(value: CMTimeValue(i), timescale: 30)) {
                firstDecoded = firstDecoded ?? i
            }
        }
        #expect(firstDecoded == 15)
    }
}

@Suite struct MailboxTests {
    private func frame(_ i: Int) -> VideoFrame {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_OneComponent8, nil, &pb)
        return VideoFrame(index: i, pixelBuffer: pb!, presentationTime: Double(i), timestampQuality: .synthetic, segment: 0,
                          timing: FrameTiming(sourceTimestampRaw: nil, receivedHostTime: 0, decodedHostTime: 0))
    }

    @Test func latestOnlyCountsOverwrites() async {
        let box = FrameMailbox(policy: .latestOnly)
        box.put(frame(0)); box.put(frame(1)); box.put(frame(2))
        #expect(box.overwrittenCount == 2)
        #expect(await box.next()?.index == 2)
        box.close()
        #expect(await box.next() == nil)
    }

    @Test func losslessDeliversEverythingInOrder() async {
        let box = FrameMailbox(policy: .lossless)
        let producer = Task {
            for i in 0..<50 { await box.putWaiting(frame(i)) }
            box.close()
        }
        var got: [Int] = []
        while let f = await box.next() { got.append(f.index) }
        await producer.value
        #expect(got == Array(0..<50))
        #expect(box.overwrittenCount == 0)
    }
}
