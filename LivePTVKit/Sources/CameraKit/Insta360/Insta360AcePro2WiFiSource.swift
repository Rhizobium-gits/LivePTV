import CoreMedia
import Foundation
import Network

/// 🐱 Live preview straight from an Insta360 Ace Pro 2 over the camera's own Wi-Fi access point.
/// 🐱
/// 🐱 Status: the wire protocol is community-documented and has been used with an Ace Pro 2 by other projects,
/// 🐱 but it is not an official Insta360 API and has not been verified against hardware by this project.
/// 🐱 Everything the camera actually does (codec, resolution, timestamp unit, rejected commands) is observed and
/// 🐱 reported instead of assumed. Run `ace-probe` on a Mac first; see docs/TECHNICAL_REPORT.md.
public final class Insta360AcePro2WiFiSource: CameraVideoSource, CameraRecordingControl, KeyFrameRequesting, @unchecked Sendable {

    public struct Configuration: Sendable {
        public var host = Insta360Protocol.defaultHost
        public var port = Insta360Protocol.defaultPort
        /// 🐱 Force traffic onto Wi-Fi. Matters on cellular iPads, where a network without internet may otherwise be
        /// 🐱 bypassed. Turn off only for tests against a local mock camera.
        public var requireWiFiInterface = true
        public var connectTimeout: Double = 5
        public var handshakeTimeout: Double = 5
        public var commandTimeout: Double = 5
        public var keepAliveInterval: Double = 2
        /// 🐱 No bytes at all for this long: the link is dead.
        public var receiveTimeout: Double = 10
        /// 🐱 Streaming but no video for this long: ask for a key frame...
        public var stallKeyFrameTimeout: Double = 2
        /// 🐱 ...and for this long: reconnect.
        public var stallReconnectTimeout: Double = 8
        /// 🐱 Tried in order until the camera accepts one.
        public var previewResolutions: [Insta360Messages.PreviewResolution] = [.res1920x1080p30, .res1280x720p30, .res1440x720p30]
        public var secondaryResolution: Insta360Messages.PreviewResolution? = .res424x240p15
        public var videoBitrateMbps: UInt32?
        public var assemblyMode: AccessUnitAssembler.Mode = .safe
        public var lowLatencyIdleFlush: Double = 0.004
        public var autoReconnect = true
        public var maxReconnectDelay: Double = 10
        /// 🐱 Emit `.compressedAccessUnit` events (bit-exact archiving of the preview stream).
        public var emitCompressedAccessUnits = false
        /// 🐱 Keep this many packet summaries for protocol diagnostics.
        public var packetLogLimit = 400
        /// 🐱 Read model / firmware / serial with GET_OPTIONS after connecting.
        public var queryCameraInfo = true

        public init() {}
    }

    public struct CameraInfo: Codable, Sendable, Equatable {
        public var cameraType: String?
        public var firmware: String?
        public var serialNumber: String?
    }

    /// 🐱 One received/sent packet, for the diagnostics capture.
    public struct PacketLogEntry: Codable, Sendable {
        public let hostTime: Double
        public let direction: String
        public let label: String
        public let length: Int
        public let headHex: String
    }

    // 🐱 MARK: public surface

    public let info: SourceInfo
    public let configuration: Configuration
    public var onEvent: (@Sendable (SourceEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.info = SourceInfo(kind: .insta360WiFi, name: "Insta360 Ace Pro 2 (Wi-Fi)",
                               address: "\(configuration.host):\(configuration.port)", isLive: true)
        self.assembler = AccessUnitAssembler(mode: configuration.assemblyMode)
    }

    deinit {
        connection?.cancel()
        tickTimer?.cancel()
    }

    public func getFrame() -> VideoFrame? { mailbox.take() }
    public func setPreviewHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) { mailbox.onPut = handler }
    public func nextFrame() async -> VideoFrame? { await mailbox.next() }
    public func getConnectionState() -> ConnectionState { lock.withLock { _state } }
    public func statistics() -> SourceStatistics { lock.withLock { _stats } }
    public var analysisDropCount: Int { mailbox.overwrittenCount }
    public var cameraInfo: CameraInfo? { lock.withLock { _cameraInfo } }
    public var streamParameters: StreamParameters? { lock.withLock { _streamParameters } }
    public var packetLog: [PacketLogEntry] { lock.withLock { _packetLog } }
    public var timestampUnit: TimestampNormalizer.Unit? { queue.sync { normalizer.unit } }
    public var assemblerStatus: (mode: AccessUnitAssembler.Mode, lateSlices: Int) {
        queue.sync { (assembler.mode, assembler.lateSliceCount) }
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { self.beginConnect(c) }
        }
        if configuration.queryCameraInfo, cameraInfo == nil {
            await queryCameraInfo()
        }
    }

    public func disconnect() async {
        queue.sync {
            previewWanted = false
            reconnectWork?.cancel()
            reconnectWork = nil
        }
        if getConnectionState() == .streaming {
            _ = try? await sendCommand(.stopLiveStream, body: Data(), timeout: 1.5)
        }
        queue.sync {
            teardownConnection(reason: nil)
            setState(.disconnected)
        }
        mailbox.close()
    }

    public func startPreview() async throws {
        let alreadyWanted = queue.sync { previewWanted }
        if !alreadyWanted {
            mailbox.reset()
            queue.sync {
                frameIndex = 0
                lock.withLock { _stats = SourceStatistics() }
                previewWanted = true
            }
        }
        do {
            if !getConnectionState().isActive { try await connect() }
            try await startStream()
        } catch {
            queue.sync { previewWanted = false }
            throw error
        }
    }

    public func stopPreview() async {
        queue.sync {
            previewWanted = false
            reconnectWork?.cancel()
            reconnectWork = nil
            if case .reconnecting = _stateUnlocked { setState(.disconnected) }
        }
        if getConnectionState() == .streaming {
            do { _ = try await sendCommand(.stopLiveStream, body: Data(), timeout: 2) }
            catch { log(.warning, "STOP_LIVE_STREAM: \(error)") }
        }
        queue.sync {
            if let unit = assembler.flush() { process(unit) }
            if case .streaming = _stateUnlocked { setState(.connected) }
        }
        decodeQueue.sync {}
        mailbox.close()
    }

    public func requestKeyFrame() async {
        lock.withLock { _stats.keyFrameRequests += 1 }
        do { _ = try await sendCommand(.iframeRequest, body: Data(), timeout: 2) }
        catch { log(.debug, "IFRAME_REQUEST not acknowledged: \(error)") }
    }

    public func startCameraRecording() async throws {
        _ = try await sendCommand(.startCapture, body: Insta360Messages.startCapture())
        log(.info, "Camera-native recording started")
    }

    public func stopCameraRecording() async throws -> String? {
        let body = try await sendCommand(.stopCapture, body: Data(), timeout: 10)
        let uri = Insta360Messages.videoURI(fromStopCaptureResponse: body)
        log(.info, "Camera-native recording stopped\(uri.map { ": \($0)" } ?? "")")
        return uri
    }

    // 🐱 MARK: private state (guarded by `queue`, except fields prefixed `_` which are guarded by `lock`)

    private let queue = DispatchQueue(label: "liveptv.insta360.net", qos: .userInteractive)
    private let decodeQueue = DispatchQueue(label: "liveptv.insta360.decode", qos: .userInteractive)
    private let lock = NSLock()
    private let mailbox = FrameMailbox(policy: .latestOnly)

    private var _onEvent: (@Sendable (SourceEvent) -> Void)?
    private var _state: ConnectionState = .disconnected
    private var _stats = SourceStatistics()
    private var _cameraInfo: CameraInfo?
    private var _streamParameters: StreamParameters?
    private var _packetLog: [PacketLogEntry] = []

    private var connection: NWConnection?
    private var connectionGeneration = 0
    private var framer = Insta360Framer()
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeoutWork: DispatchWorkItem?
    private var lastWaitingReason: String?
    private var handshakeDone = false
    private var sequence: UInt32 = 0
    private var pending: [UInt32: Pending] = [:]
    private var tickTimer: DispatchSourceTimer?
    private var lastReceive = 0.0
    private var lastSend = 0.0
    private var lastVideo = 0.0
    private var stallKeyFrameRequested = false
    private var previewWanted = false
    private var streamActive = false
    private var streamEpoch = 0
    private var frameIndex = 0
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var assembler: AccessUnitAssembler
    private var normalizer = TimestampNormalizer()
    private var codecHint: VideoCodec?
    private var flushScheduled = false
    private var lastKeyFrameRequest = 0.0
    private var videoPacketsSinceStart = 0

    // 🐱 Decode-queue state.
    private let decoder = H26xDecoder()

    private struct Pending {
        let command: Insta360Protocol.Command
        let continuation: CheckedContinuation<Data, Error>
        let timeout: DispatchWorkItem
    }

    private var _stateUnlocked: ConnectionState { lock.withLock { _state } }

    private func setState(_ s: ConnectionState) {
        let changed: Bool = lock.withLock {
            guard _state != s else { return false }
            _state = s
            return true
        }
        if changed { emit(.stateChanged(s)) }
    }

    /// 🐱 Events are delivered on their own serial queue, never on the network queue, so handlers may call back
    /// 🐱 into this object without deadlocking.
    private let eventQueue = DispatchQueue(label: "liveptv.insta360.events")

    private func emit(_ e: SourceEvent) {
        guard let handler = onEvent else { return }
        eventQueue.async { handler(e) }
    }

    private func log(_ level: LogLevel, _ message: String) { emit(.log(level: level, message: message)) }

    private func logPacket(_ direction: String, _ label: String, _ payload: Data) {
        lock.withLock {
            if direction == "rx" { _stats.packetTypes[label, default: 0] += 1 }
            guard _packetLog.count < configuration.packetLogLimit else { return }
            let head = payload.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            _packetLog.append(PacketLogEntry(hostTime: HostClock.now(), direction: direction, label: label, length: payload.count, headHex: head))
        }
    }

    // 🐱 MARK: connection

    private func beginConnect(_ c: CheckedContinuation<Void, Error>) {
        if handshakeDone, connection != nil { c.resume(); return }
        if connectContinuation != nil {
            c.resume(throwing: CameraError.protocolViolation("connect already in progress"))
            return
        }
        teardownConnection(reason: nil)
        connectContinuation = c
        connectionGeneration += 1
        let generation = connectionGeneration
        setState(.connecting("TCP connect to \(configuration.host):\(configuration.port)"))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(configuration.connectTimeout.rounded(.up))
        let params = NWParameters(tls: nil, tcp: tcp)
        if configuration.requireWiFiInterface { params.requiredInterfaceType = .wifi }
        let conn = NWConnection(host: NWEndpoint.Host(configuration.host),
                                port: NWEndpoint.Port(rawValue: configuration.port)!, using: params)
        connection = conn
        lastWaitingReason = nil
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, generation == self.connectionGeneration else { return }
            self.connectionStateChanged(state, conn)
        }
        conn.start(queue: queue)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, generation == self.connectionGeneration, self.connectContinuation != nil else { return }
            let why = self.lastWaitingReason ?? "no answer within \(Int(self.configuration.connectTimeout)) s"
            self.failConnect(self.handshakeStarted
                ? .handshakeTimeout
                : .cameraUnreachable(host: self.configuration.host, port: self.configuration.port, reason: why))
        }
        connectTimeoutWork = timeout
        queue.asyncAfter(deadline: .now() + configuration.connectTimeout + configuration.handshakeTimeout, execute: timeout)
    }

    private var handshakeStarted = false

    private func connectionStateChanged(_ state: NWConnection.State, _ conn: NWConnection) {
        switch state {
        case .ready:
            handshakeStarted = true
            setState(.connecting("protocol handshake"))
            lastReceive = HostClock.now()
            receive(on: conn, generation: connectionGeneration)
            send(Insta360Protocol.syncPacket(), label: "sync")
            send(Insta360Protocol.keepAlivePacket(), label: "keepalive")
            // 🐱 Handshake must finish within handshakeTimeout of TCP being ready.
            connectTimeoutWork?.cancel()
            let generation = connectionGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, generation == self.connectionGeneration, !self.handshakeDone else { return }
                self.failConnect(.handshakeTimeout)
            }
            connectTimeoutWork = work
            queue.asyncAfter(deadline: .now() + configuration.handshakeTimeout, execute: work)
        case let .waiting(error):
            lastWaitingReason = "\(error)"
            if conn.currentPath?.unsatisfiedReason == .localNetworkDenied {
                failConnect(.localNetworkDenied)
            } else if case let .posix(code) = error, code == .ECONNREFUSED {
                failConnect(.connectionRefused(host: configuration.host, port: configuration.port))
            } else if connectContinuation == nil {
                // 🐱 An established link went into waiting: treat as loss.
                connectionLost("network path lost (\(error))")
            }
        case let .failed(error):
            if connectContinuation != nil {
                if case let .posix(code) = error, code == .ECONNREFUSED {
                    failConnect(.connectionRefused(host: configuration.host, port: configuration.port))
                } else {
                    failConnect(.cameraUnreachable(host: configuration.host, port: configuration.port, reason: "\(error)"))
                }
            } else {
                connectionLost("\(error)")
            }
        case .cancelled, .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func completeHandshake(via label: String) {
        guard !handshakeDone else { return }
        handshakeDone = true
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        reconnectAttempt = 0
        log(.info, "Handshake complete (first camera packet: \(label))")
        startTicking()
        setState(.connected)
        let c = connectContinuation
        connectContinuation = nil
        c?.resume()
    }

    private func failConnect(_ error: CameraError) {
        let c = connectContinuation
        connectContinuation = nil
        teardownConnection(reason: error)
        setState(.failed(error))
        log(.error, error.description)
        c?.resume(throwing: error)
    }

    /// 🐱 Close the socket and fail anything waiting on it. Does not change the public state.
    private func teardownConnection(reason: CameraError?) {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        tickTimer?.cancel()
        tickTimer = nil
        connectionGeneration += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        framer.reset()
        handshakeDone = false
        handshakeStarted = false
        streamActive = false
        let waiting = pending
        pending.removeAll()
        for p in waiting.values {
            p.timeout.cancel()
            p.continuation.resume(throwing: reason ?? CameraError.notConnected)
        }
    }

    private func connectionLost(_ why: String) {
        let error = CameraError.connectionLost(why)
        log(.warning, error.description)
        teardownConnection(reason: error)
        if previewWanted && configuration.autoReconnect {
            scheduleReconnect()
        } else {
            setState(.failed(error))
            if !previewWanted { mailbox.close() }
        }
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(configuration.maxReconnectDelay, pow(2, Double(reconnectAttempt - 1)))
        lock.withLock { _stats.reconnects += 1 }
        setState(.reconnecting(attempt: reconnectAttempt, delay: delay))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewWanted else { return }
            Task {
                do {
                    try await self.connect()
                    try await self.startStream()
                    self.log(.info, "Reconnected")
                } catch {
                    self.queue.async {
                        if self.previewWanted && self.configuration.autoReconnect { self.scheduleReconnect() }
                    }
                }
            }
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // 🐱 MARK: I/O

    private func send(_ packet: Data, label: String) {
        guard let conn = connection else { return }
        lastSend = HostClock.now()
        logPacket("tx", label, packet.dropFirst(4))
        conn.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.connectionLost("send failed: \(error)") }
        })
    }

    private func receive(on conn: NWConnection, generation: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self, generation == self.connectionGeneration else { return }
            if let data, !data.isEmpty {
                self.lastReceive = HostClock.now()
                self.lock.withLock { self._stats.bytesReceived += data.count }
                do {
                    for payload in try self.framer.append(data) {
                        self.handle(payload: payload)
                        if generation != self.connectionGeneration { return }
                    }
                } catch let e as CameraError {
                    if self.connectContinuation != nil { self.failConnect(e) } else { self.connectionLost(e.description) }
                    return
                } catch {
                    self.connectionLost("\(error)")
                    return
                }
            }
            if isComplete {
                if self.connectContinuation != nil {
                    self.failConnect(.protocolViolation("camera closed the connection during handshake"))
                } else {
                    self.connectionLost("camera closed the connection")
                }
                return
            }
            if let error {
                if self.connectContinuation != nil {
                    self.failConnect(.cameraUnreachable(host: self.configuration.host, port: self.configuration.port, reason: "\(error)"))
                } else {
                    self.connectionLost("\(error)")
                }
                return
            }
            self.receive(on: conn, generation: generation)
        }
    }

    private func handle(payload: Data) {
        let packet = Insta360Protocol.parse(payload: payload)
        lock.withLock { _stats.packetsReceived += 1 }
        logPacket("rx", packet.histogramLabel, payload)
        // 🐱 Any well-formed packet proves the protocol; a SYNC echo is expected but not strictly required.
        if !handshakeDone {
            if case .unknown = packet {
                // 🐱 Keep waiting for a recognisable packet; the handshake timeout decides. The hex goes to the log
                // 🐱 so an unexpected firmware dialect can be analysed afterwards.
                log(.warning, "Unrecognised packet during handshake: \(payload.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
                return
            }
            completeHandshake(via: packet.histogramLabel)
        }
        switch packet {
        case .sync, .keepAlive:
            break
        case let .message(header, body):
            if header.code >= Insta360Protocol.ResponseCode.notificationBase {
                handleNotification(code: header.code, body: body)
            } else if let p = pending.removeValue(forKey: header.sequence) {
                p.timeout.cancel()
                if header.code == Insta360Protocol.ResponseCode.ok {
                    p.continuation.resume(returning: body)
                } else {
                    p.continuation.resume(throwing: CameraError.commandRejected(
                        command: p.command.name, code: Int(header.code), message: Insta360Messages.errorDescription(body)))
                }
            } else {
                log(.debug, "Response code \(header.code) for unknown sequence \(header.sequence)")
            }
        case let .stream(type, timestamp, data):
            guard type == Insta360Protocol.StreamType.video, previewWanted, !data.isEmpty else { return }
            videoPacketsSinceStart += 1
            let now = HostClock.now()
            for unit in assembler.push(timestamp: Int64(bitPattern: timestamp), payload: data, hostTime: now) {
                process(unit)
            }
            if assembler.fellBackToSafe && configuration.assemblyMode == .lowLatency && !loggedFallback {
                loggedFallback = true
                log(.warning, "Low-latency assembly saw a late slice; switched to safe mode for this stream")
            }
            if assembler.mode == .lowLatency && !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + configuration.lowLatencyIdleFlush) { [weak self] in
                    guard let self else { return }
                    self.flushScheduled = false
                    if let unit = self.assembler.flushIfIdle(now: HostClock.now(), idleSeconds: self.configuration.lowLatencyIdleFlush) {
                        self.process(unit)
                    } else if self.assembler.hasPending, !self.flushScheduled {
                        self.flushScheduled = true
                        self.queue.asyncAfter(deadline: .now() + self.configuration.lowLatencyIdleFlush) { [weak self] in
                            guard let self else { return }
                            self.flushScheduled = false
                            if let u = self.assembler.flushIfIdle(now: HostClock.now(), idleSeconds: self.configuration.lowLatencyIdleFlush) {
                                self.process(u)
                            }
                        }
                    }
                }
            }
        case .unknown:
            break
        }
    }

    private var loggedFallback = false

    private func handleNotification(code: UInt16, body: Data) {
        switch code {
        case Insta360Protocol.Notification.updateLiveStreamParams:
            guard let p = try? Insta360Messages.LiveStreamParamsUpdate(body) else {
                log(.warning, "Unparseable live stream parameters notification")
                return
            }
            if let c = p.codec { codecHint = c }
            let params = StreamParameters(codec: p.codec ?? .unknown, width: p.width, height: p.height,
                                          nominalFPS: p.fps > 0 ? Double(p.fps) : nil, origin: "camera notification 8234")
            lock.withLock { _streamParameters = params }
            emit(.streamParameters(params))
            log(.info, "Camera stream parameters: \(params.codec.rawValue) \(p.width)x\(p.height) @ \(p.fps) fps")
        case Insta360Protocol.Notification.captureStopped:
            log(.info, "Camera reports capture stopped")
        default:
            log(.debug, "Camera notification \(code) (\(body.count) bytes)")
        }
    }

    // 🐱 MARK: commands

    private func sendCommand(_ command: Insta360Protocol.Command, body: Data, timeout: Double? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            queue.async {
                guard self.connection != nil, self.handshakeDone else {
                    c.resume(throwing: CameraError.notConnected)
                    return
                }
                self.sequence = self.sequence % 0xFF_FFFF + 1
                let seq = self.sequence
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let p = self.pending.removeValue(forKey: seq) else { return }
                    p.continuation.resume(throwing: CameraError.commandTimeout(command: command.name))
                }
                self.pending[seq] = Pending(command: command, continuation: c, timeout: work)
                self.queue.asyncAfter(deadline: .now() + (timeout ?? self.configuration.commandTimeout), execute: work)
                self.send(Insta360Protocol.messagePacket(code: command.rawValue, sequence: seq, body: body), label: command.name)
            }
        }
    }

    private func queryCameraInfo() async {
        // 🐱 GetOptions.option_types is a packed repeated enum: one length-delimited field holding the varints.
        var w = ProtobufWriter()
        var list = Data()
        for t in [48, 30, 15] { list.append(UInt8(t)) }   // 🐱 CAMERA_TYPE, FIRMWAREREVISION, SERIAL_NUMBER (< 128)
        w.bytes(1, list)
        do {
            let body = try await sendCommand(.getOptions, body: w.data, timeout: 3)
            let options = (try? ProtobufMessage(body))?.message(2)
            let info = CameraInfo(cameraType: options?.string(48), firmware: options?.string(30), serialNumber: options?.string(15))
            lock.withLock { _cameraInfo = info }
            log(.info, "Camera: \(info.cameraType ?? "?") firmware \(info.firmware ?? "?")")
        } catch {
            log(.info, "Camera info not available: \(error)")
        }
    }

    /// 🐱 Send START_LIVE_STREAM, trying each configured resolution.
    private func startStream() async throws {
        queue.sync {
            assembler = AccessUnitAssembler(mode: configuration.assemblyMode)
            loggedFallback = false
            normalizer.reset()
            codecHint = nil
            streamEpoch += 1
            videoPacketsSinceStart = 0
            lastVideo = HostClock.now()
            stallKeyFrameRequested = false
        }
        decodeQueue.sync { decoder.reset() }

        var tried: [String] = []
        var accepted: Insta360Messages.PreviewResolution?
        for res in configuration.previewResolutions {
            let request = Insta360Messages.StartLiveStream(resolution: res, secondaryResolution: configuration.secondaryResolution,
                                                           videoBitrateMbps: configuration.videoBitrateMbps)
            do {
                _ = try await sendCommand(.startLiveStream, body: request.encode())
                accepted = res
                break
            } catch CameraError.commandTimeout {
                // 🐱 Some firmware may stream without acknowledging; accept if video is flowing.
                if queue.sync(execute: { videoPacketsSinceStart }) > 0 {
                    log(.warning, "START_LIVE_STREAM not acknowledged but video is arriving; continuing")
                    accepted = res
                    break
                }
                tried.append("\(res.label): timeout")
            } catch let CameraError.commandRejected(_, code, message) {
                tried.append("\(res.label): \(code)\(message.map { " \($0)" } ?? "")")
                log(.warning, "Camera rejected preview \(res.label) (code \(code))")
            }
        }
        guard let res = accepted else { throw CameraError.previewRejected(triedResolutions: tried) }

        let s = res.size
        let requested = StreamParameters(codec: .unknown, width: s.width, height: s.height, nominalFPS: s.fps,
                                         origin: "requested \(res.label) (not yet confirmed by camera)")
        let known = lock.withLock { () -> StreamParameters? in
            if _streamParameters == nil { _streamParameters = requested; return nil }
            return _streamParameters
        }
        if known == nil { emit(.streamParameters(requested)) }
        queue.sync {
            streamActive = true
            setState(.streaming)
        }
        log(.info, "Preview started with \(res.label)")
        await requestKeyFrame()
    }

    // 🐱 MARK: frames

    private func process(_ unit: AccessUnitAssembler.Unit) {
        let assembled = HostClock.now()
        lock.withLock { _stats.accessUnitsAssembled += 1 }
        lastVideo = unit.receivedHostTime
        stallKeyFrameRequested = false
        let norm = normalizer.normalize(raw: unit.timestamp, hostTime: unit.receivedHostTime)
        let index = frameIndex
        frameIndex += 1
        let epoch = streamEpoch
        let hint = codecHint
        let emitCompressed = configuration.emitCompressedAccessUnits

        decodeQueue.async { [weak self] in
            guard let self else { return }
            let pts = CMTime(seconds: norm.seconds, preferredTimescale: 1_000_000)
            if emitCompressed {
                let nals = AnnexB.split(unit.data)
                let codec = self.decoder.codec ?? hint ?? AnnexB.detectCodec(nals: nals) ?? .unknown
                let key = codec == .unknown ? false : AnnexB.containsKeyFrame(nals, codec: codec)
                self.emit(.compressedAccessUnit(CompressedAccessUnit(codec: codec, annexB: unit.data, sourceTimestampRaw: unit.timestamp,
                                                                      receivedHostTime: unit.receivedHostTime, isKeyFrame: key)))
            }
            do {
                switch try self.decoder.decode(annexB: unit.data, pts: pts, codecHint: hint) {
                case let .frame(pixels, _):
                    let decoded = HostClock.now()
                    let frame = VideoFrame(index: index, pixelBuffer: pixels, presentationTime: norm.seconds,
                                           timestampQuality: norm.quality, segment: epoch * 1000 + norm.segment,
                                           timing: FrameTiming(sourceTimestampRaw: unit.timestamp, receivedHostTime: unit.receivedHostTime,
                                                               assembledHostTime: assembled, decodedHostTime: decoded))
                    self.lock.withLock {
                        self._stats.framesDecoded += 1
                        self._stats.lastFrameHostTime = decoded
                    }
                    self.updateParametersFromDecoder(width: frame.width, height: frame.height)
                    self.mailbox.put(frame)
                case let .skipped(reason):
                    self.lock.withLock { self._stats.framesDiscardedBeforeDecode += 1 }
                    if reason.contains("key frame") || reason.contains("parameter sets") { self.requestKeyFrameThrottled() }
                }
            } catch {
                self.lock.withLock { self._stats.decodeErrors += 1 }
                self.log(.warning, "\(error)")
                self.requestKeyFrameThrottled()
            }
        }
    }

    private func updateParametersFromDecoder(width: Int, height: Int) {
        let codec = decoder.codec ?? .unknown
        let changed: StreamParameters? = lock.withLock {
            var p = _streamParameters ?? StreamParameters(codec: codec, width: width, height: height, nominalFPS: nil, origin: "decoder")
            guard p.width != width || p.height != height || p.codec != codec else { return nil }
            p.width = width
            p.height = height
            p.codec = codec
            p.origin += " + decoded picture"
            _streamParameters = p
            return p
        }
        if let changed { emit(.streamParameters(changed)) }
    }

    private func requestKeyFrameThrottled() {
        queue.async {
            let now = HostClock.now()
            guard now - self.lastKeyFrameRequest > 1.0, self.handshakeDone else { return }
            self.lastKeyFrameRequest = now
            Task { await self.requestKeyFrame() }
        }
    }

    // 🐱 MARK: housekeeping timer (keepalive, receive timeout, stall watchdog)

    private func startTicking() {
        tickTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        tickTimer = t
    }

    private func tick() {
        guard handshakeDone else { return }
        let now = HostClock.now()
        if now - lastSend >= configuration.keepAliveInterval {
            send(Insta360Protocol.keepAlivePacket(), label: "keepalive")
        }
        if now - lastReceive > configuration.receiveTimeout {
            connectionLost(String(format: "nothing received for %.0f s", now - lastReceive))
            return
        }
        guard streamActive, previewWanted else { return }
        let silence = now - lastVideo
        if silence > configuration.stallReconnectTimeout {
            log(.warning, CameraError.streamStalled(seconds: silence).description)
            connectionLost("video stalled")
        } else if silence > configuration.stallKeyFrameTimeout && !stallKeyFrameRequested {
            stallKeyFrameRequested = true
            log(.warning, CameraError.streamStalled(seconds: silence).description + " Requesting key frame.")
            if let unit = assembler.flush() { process(unit) }
            Task { await self.requestKeyFrame() }
        }
    }
}
