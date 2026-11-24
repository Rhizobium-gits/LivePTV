import Foundation
import Testing
@testable import CameraKit

@Suite struct ProtocolTests {
    @Test func syncPacketMatchesDocumentedBytes() {
        // 🐱 Byte sequence quoted in xaionaro-go/insta360ctl doc/protocol.md.
        let expected: [UInt8] = [0x11, 0, 0, 0, 0x06, 0, 0, 0x73, 0x79, 0x4E, 0x63, 0x65, 0x4E, 0x64, 0x69, 0x6E, 0x53]
        #expect([UInt8](Insta360Protocol.syncPacket()) == expected)
        #expect([UInt8](Insta360Protocol.keepAlivePacket()) == [0x07, 0, 0, 0, 0x05, 0, 0])
    }

    @Test func messageHeaderLayout() {
        let p = [UInt8](Insta360Protocol.messagePacket(code: 1, sequence: 0x030201, body: Data([0xAA])))
        // 🐱 length 4+12+1 = 17, then 04 00 00 | code 01 00 | 02 | seq 01 02 03 | 80 00 00 | body
        #expect(p == [17, 0, 0, 0, 0x04, 0, 0, 0x01, 0x00, 0x02, 0x01, 0x02, 0x03, 0x80, 0, 0, 0xAA])
    }

    @Test func parsesEveryPacketKind() {
        #expect(Insta360Protocol.parse(payload: Insta360Protocol.syncPacket().dropFirst(4)) == .sync)
        #expect(Insta360Protocol.parse(payload: Data([5, 0, 0])) == .keepAlive)

        let msg = Insta360Protocol.messagePacket(code: 200, sequence: 7, body: Data([1, 2]))
        #expect(Insta360Protocol.parse(payload: msg.dropFirst(4)) ==
            .message(.init(code: 200, sequence: 7), body: Data([1, 2])))

        var stream = Data([0x01, 0, 0, 0x20])
        Insta360Protocol.appendLE(UInt64(1_234_567), to: &stream)
        stream.append(contentsOf: [0, 0, 0, 1, 0x67])
        #expect(Insta360Protocol.parse(payload: stream) == .stream(type: 0x20, timestamp: 1_234_567, data: Data([0, 0, 0, 1, 0x67])))

        #expect(Insta360Protocol.parse(payload: Data([9, 9, 9])) == .unknown(Data([9, 9, 9])))
    }

    @Test func framerHandlesSplitAndCoalescedChunks() throws {
        let a = Insta360Protocol.syncPacket()
        let b = Insta360Protocol.messagePacket(code: 8, sequence: 1, body: Data(repeating: 0x55, count: 300))
        let c = Insta360Protocol.keepAlivePacket()
        let all = a + b + c
        var framer = Insta360Framer()
        var payloads: [Data] = []
        // 🐱 Feed in awkward chunk sizes.
        var i = 0
        for size in [3, 1, 20, 7, 150, 1000] {
            let end = min(all.count, i + size)
            payloads += try framer.append(all.subdata(in: i..<end))
            i = end
            if i == all.count { break }
        }
        #expect(payloads.count == 3)
        #expect(payloads[0] == a.dropFirst(4))
        #expect(payloads[1] == b.dropFirst(4))
        #expect(payloads[2] == c.dropFirst(4))
        #expect(framer.bufferedByteCount == 0)
    }

    @Test func framerRejectsGarbageLength() {
        var framer = Insta360Framer()
        #expect(throws: CameraError.self) { _ = try framer.append(Data([0xFF, 0xFF, 0xFF, 0x7F, 0])) }
        var framer2 = Insta360Framer()
        #expect(throws: CameraError.self) { _ = try framer2.append(Data([0x02, 0, 0, 0])) }
    }
}

@Suite struct ProtobufTests {
    @Test func startLiveStreamEncoding() throws {
        let body = Insta360Messages.StartLiveStream(resolution: .res1920x1080p30).encode()
        // 🐱 enableVideo(2)=1, audioSampleRate(4)=48000, resolution(7)=29, resolution1(10)=34
        #expect([UInt8](body) == [0x10, 0x01, 0x20, 0x80, 0xF7, 0x02, 0x38, 0x1D, 0x50, 0x22])
        let m = try ProtobufMessage(body)
        #expect(m.varint(2) == 1)
        #expect(m.varint(4) == 48_000)
        #expect(m.varint(7) == 29)
        #expect(m.varint(10) == 34)
    }

    @Test func liveStreamParamsUpdateDecoding() throws {
        var w = ProtobufWriter()
        w.enumValue(1, 1)
        w.uint32(2, 1920)
        w.uint32(3, 1080)
        w.uint32(4, 30)
        let p = try Insta360Messages.LiveStreamParamsUpdate(w.data)
        #expect(p.codec == .hevc && p.width == 1920 && p.height == 1080 && p.fps == 30)
    }

    @Test func stopCaptureResponseURI() {
        var video = ProtobufWriter()
        video.string(1, "/DCIM/Camera01/VID_20261122_101010_00_001.mp4")
        video.varint(2, 123_456)
        var resp = ProtobufWriter()
        resp.message(1, video)
        #expect(Insta360Messages.videoURI(fromStopCaptureResponse: resp.data) == "/DCIM/Camera01/VID_20261122_101010_00_001.mp4")
    }

    @Test func errorBodyDescription() {
        var w = ProtobufWriter()
        w.enumValue(1, 5)
        w.string(2, "busy")
        #expect(Insta360Messages.errorDescription(w.data) == "SYSTEM_BUSY: busy")
        #expect(Insta360Messages.errorDescription(Data()) == nil)
    }

    @Test func truncatedProtobufThrows() {
        #expect(throws: CameraError.self) { _ = try ProtobufMessage(Data([0x0A, 0x05, 0x01])) }
    }
}
