import Foundation
import Network
@testable import CameraKit

/// 🐱 Loopback TCP server that behaves like the camera as documented by the community projects:
/// 🐱 echoes SYNC, answers commands with 200/500 + sequence echo, announces stream parameters (8234),
/// 🐱 and streams access units as type-0x20 packets, splitting big pictures across packets with equal timestamps.
final class MockInsta360Camera: @unchecked Sendable {
    struct Behavior {
        var echoSync = true
        var answerCommands = true
        /// 🐱 START_LIVE_STREAM requests with these resolution values get code 500.
        var rejectedResolutions: Set<Int> = []
        var codec: VideoCodec = .h264
        var units: [[Data]] = []
        /// 🐱 Timestamp step per frame in camera ticks (µs by default).
        var timestampStep: UInt64 = 33_333
        var maxPacketPayload = 2_000
        var frameInterval: Double = 0.005
        var announceParameters = true
        var cameraType = "Insta360 Ace Pro 2 (mock)"
    }

    private let queue = DispatchQueue(label: "mock.camera")
    private var listener: NWListener!
    private var connections: [NWConnection] = []
    private(set) var receivedCommands: [(code: UInt16, body: Data)] = []
    private let lock = NSLock()
    var behavior: Behavior

    init(behavior: Behavior) { self.behavior = behavior }

    var commands: [(code: UInt16, body: Data)] { lock.withLock { receivedCommands } }

    /// 🐱 Starts listening on an ephemeral loopback port and returns it.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    c.resume(returning: self?.listener.port?.rawValue ?? 0)
                case let .failed(e):
                    resumed = true
                    c.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
            listener?.cancel()
        }
    }

    /// 🐱 Simulate the camera dropping the link (e.g. walked out of range).
    func dropAllConnections() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ c: NWConnection) {
        connections.append(c)
        var framer = Insta360Framer()
        func loop() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self else { return }
                if let data {
                    for payload in (try? framer.append(data)) ?? [] { self.handle(payload, on: c) }
                }
                if done || err != nil { return }
                loop()
            }
        }
        c.start(queue: queue)
        loop()
    }

    private func send(_ data: Data, on c: NWConnection) {
        c.send(content: data, completion: .idempotent)
    }

    private func handle(_ payload: Data, on c: NWConnection) {
        switch Insta360Protocol.parse(payload: payload) {
        case .sync:
            if behavior.echoSync { send(Insta360Protocol.syncPacket(), on: c) }
        case let .message(h, body):
            lock.withLock { receivedCommands.append((h.code, body)) }
            guard behavior.answerCommands else { return }
            switch Insta360Protocol.Command(rawValue: h.code) {
            case .startLiveStream?:
                let res = (try? ProtobufMessage(body))?.varint(7).map(Int.init) ?? -1
                if behavior.rejectedResolutions.contains(res) {
                    var e = ProtobufWriter(); e.enumValue(1, 3); e.string(2, "unsupported resolution")
                    send(Insta360Protocol.messagePacket(code: 500, sequence: h.sequence, body: e.data), on: c)
                    return
                }
                send(Insta360Protocol.messagePacket(code: 200, sequence: h.sequence, body: Data()), on: c)
                if behavior.announceParameters {
                    var w = ProtobufWriter()
                    w.enumValue(1, behavior.codec == .hevc ? 1 : 0)
                    w.uint32(2, 160); w.uint32(3, 120); w.uint32(4, 30)
                    send(Insta360Protocol.messagePacket(code: 8234, sequence: 0, body: w.data), on: c)
                }
                streamFrames(on: c)
            case .getOptions?:
                var options = ProtobufWriter()
                options.string(48, behavior.cameraType)
                options.string(30, "v9.9.9-mock")
                var resp = ProtobufWriter()
                resp.message(2, options)
                send(Insta360Protocol.messagePacket(code: 200, sequence: h.sequence, body: resp.data), on: c)
            default:
                send(Insta360Protocol.messagePacket(code: 200, sequence: h.sequence, body: Data()), on: c)
            }
        default:
            break
        }
    }

    private func streamFrames(on c: NWConnection) {
        let b = behavior
        for (i, unit) in b.units.enumerated() {
            queue.asyncAfter(deadline: .now() + Double(i) * b.frameInterval) { [weak self] in
                guard let self else { return }
                let ts = 10_000_000 + UInt64(i) * b.timestampStep
                let bytes = AnnexB.join(unit)
                var offset = 0
                while offset < bytes.count {
                    let end = min(bytes.count, offset + b.maxPacketPayload)
                    var p = Data([0x01, 0, 0, Insta360Protocol.StreamType.video])
                    Insta360Protocol.appendLE(ts, to: &p)
                    p.append(bytes.subdata(in: offset..<end))
                    self.send(Insta360Protocol.frame(p), on: c)
                    offset = end
                }
            }
        }
    }
}
