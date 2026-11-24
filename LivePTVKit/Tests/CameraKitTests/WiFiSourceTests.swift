import Foundation
import Testing
@testable import CameraKit

@Suite(.serialized) struct WiFiSourceTests {
    private func makeSource(port: UInt16, tweak: (inout Insta360AcePro2WiFiSource.Configuration) -> Void = { _ in }) -> Insta360AcePro2WiFiSource {
        var cfg = Insta360AcePro2WiFiSource.Configuration()
        cfg.host = "127.0.0.1"
        cfg.port = port
        cfg.requireWiFiInterface = false
        cfg.connectTimeout = 2
        cfg.handshakeTimeout = 1
        cfg.commandTimeout = 1
        cfg.autoReconnect = false
        tweak(&cfg)
        return Insta360AcePro2WiFiSource(configuration: cfg)
    }

    /// 🐱 Frames received until `count` or `timeout`; on timeout returns what was collected so far.
    private func collect(_ source: CameraVideoSource, count: Int, timeout: Double = 5) async -> [VideoFrame] {
        let box = FrameBox()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while box.count < count, let f = await source.nextFrame() { box.append(f) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                // 🐱 Cancelled because the collector finished first: leave the preview running.
                if Task.isCancelled { return }
                await source.stopPreview()
            }
            _ = await group.next()
            group.cancelAll()
        }
        return box.frames
    }

    @Test(arguments: [VideoCodec.h264, .hevc])
    func streamsAndDecodesFromMockCamera(codec: VideoCodec) async throws {
        let stream = codec == .h264 ? try Fixtures.h264 : try Fixtures.hevc
        let camera = MockInsta360Camera(behavior: .init(codec: codec, units: Fixtures.accessUnits(stream, codec: codec)))
        let port = try await camera.start()
        defer { camera.stop() }
        let source = makeSource(port: port)

        try await source.startPreview()
        #expect(source.getConnectionState() == .streaming)
        // 🐱 30 pictures sent; the last one is only completed by stopPreview's flush in safe mode.
        // 🐱 The live hand-off may skip frames when the consumer is busy (by design), so the decoder count is the
        // 🐱 invariant; delivered timestamps must sit on whole multiples of the camera interval.
        let frames = await collect(source, count: 29, timeout: 3)
        #expect(!frames.isEmpty)
        #expect(source.statistics().framesDecoded >= 29)
        #expect(frames.allSatisfy { $0.width == 160 && $0.height == 120 })
        #expect(source.timestampUnit == .microseconds)
        let locked = frames.filter { $0.timestampQuality == .source }
        // 🐱 timestamps are comparable only within one timeline segment (a re-anchor under CPU load starts a new one)
        for (a, b) in zip(locked, locked.dropFirst()) where a.segment == b.segment {
            let steps = (b.presentationTime - a.presentationTime) / (1.0 / 30)
            #expect(steps >= 0.999 && abs(steps - steps.rounded()) < 1e-4)
        }
        #expect(source.cameraInfo?.cameraType == "Insta360 Ace Pro 2 (mock)")
        #expect(source.cameraInfo?.firmware == "v9.9.9-mock")
        let params = try #require(source.streamParameters)
        #expect(params.codec == codec && params.width == 160 && params.height == 120 && params.nominalFPS == 30)
        let stats = source.statistics()
        #expect(stats.decodeErrors == 0)
        #expect(stats.packetTypes["stream 0x20"] ?? 0 > 30)   // 🐱 big pictures were split across packets
        #expect(camera.commands.contains { $0.code == Insta360Protocol.Command.iframeRequest.rawValue })
        await source.disconnect()
        #expect(source.getConnectionState() == .disconnected)
    }

    @Test func fallsBackToNextResolutionWhenRejected() async throws {
        let units = Fixtures.accessUnits(try Fixtures.h264, codec: .h264)
        let camera = MockInsta360Camera(behavior: .init(rejectedResolutions: [29], units: units))
        let port = try await camera.start()
        defer { camera.stop() }
        let source = makeSource(port: port)
        try await source.startPreview()
        let starts = camera.commands.filter { $0.code == 1 }.compactMap { try? ProtobufMessage($0.body).varint(7) }
        #expect(starts == [29, 43])
        await source.disconnect()
    }

    @Test func allResolutionsRejectedIsReportedNotFaked() async throws {
        let camera = MockInsta360Camera(behavior: .init(rejectedResolutions: [29, 43, 9]))
        let port = try await camera.start()
        defer { camera.stop() }
        let source = makeSource(port: port)
        await #expect(throws: CameraError.self) { try await source.startPreview() }
        #expect(source.getConnectionState() != .streaming)
        await source.disconnect()
    }

    @Test func silentPeerFailsHandshake() async throws {
        let camera = MockInsta360Camera(behavior: .init(echoSync: false, answerCommands: false))
        let port = try await camera.start()
        defer { camera.stop() }
        let source = makeSource(port: port)
        do {
            try await source.connect()
            Issue.record("connect should fail")
        } catch let e as CameraError {
            #expect(e == .handshakeTimeout)
        }
        if case .failed(.handshakeTimeout) = source.getConnectionState() {} else {
            Issue.record("state should be failed(handshakeTimeout), is \(source.getConnectionState())")
        }
    }

    @Test func closedPortIsReportedAsRefusedOrUnreachable() async throws {
        let camera = MockInsta360Camera(behavior: .init())
        let port = try await camera.start()
        camera.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        let source = makeSource(port: port)
        do {
            try await source.connect()
            Issue.record("connect should fail")
        } catch let e as CameraError {
            switch e {
            case .connectionRefused, .cameraUnreachable: break
            default: Issue.record("unexpected error \(e)")
            }
        }
    }

    @Test func reconnectsAfterLinkDrop() async throws {
        let units = Fixtures.accessUnits(try Fixtures.h264, codec: .h264)
        let camera = MockInsta360Camera(behavior: .init(units: units))
        let port = try await camera.start()
        defer { camera.stop() }
        let source = makeSource(port: port) { $0.autoReconnect = true; $0.maxReconnectDelay = 1 }
        try await source.startPreview()
        _ = await collect(source, count: 10)
        camera.dropAllConnections()
        // 🐱 Expect reconnect (1 s backoff) and a fresh stream: more frames arrive on the same mailbox.
        var more: [VideoFrame] = []
        let deadline = HostClock.now() + 6
        while more.count < 10, HostClock.now() < deadline {
            if let f = source.getFrame() { more.append(f) } else { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        // 🐱 the stream resumed after the reconnect. The mailbox keeps only the latest frame and is polled every 10 ms, so
        // 🐱 on a busy machine (CI) some frames are overwritten between polls: count resumption, not polling speed.
        #expect(more.count >= 5)
        #expect(source.statistics().reconnects >= 1)
        // 🐱 the mock streams as soon as it gets START_LIVE_STREAM, so frames can arrive before the source has handled the
        // 🐱 acknowledgement and set `.streaming` (seen on a busy CI runner): wait for the state, do not sample it once
        let streamingDeadline = HostClock.now() + 3
        while source.getConnectionState() != .streaming, HostClock.now() < streamingDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(source.getConnectionState() == .streaming)
        await source.disconnect()
    }
}

/// 🐱 Thread-safe frame collector for the tests above.
final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [VideoFrame] = []
    func append(_ f: VideoFrame) { lock.withLock { _frames.append(f) } }
    var count: Int { lock.withLock { _frames.count } }
    var frames: [VideoFrame] { lock.withLock { _frames } }
}
