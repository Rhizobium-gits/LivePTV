import Foundation

/// 🐱 Connection life cycle shared by every source.
public enum ConnectionState: Equatable, Sendable, CustomStringConvertible {
    case disconnected
    /// 🐱 Associated text names the current step ("TCP connect", "handshake"...).
    case connecting(String)
    /// 🐱 Control channel up, no preview running.
    case connected
    case streaming
    case reconnecting(attempt: Int, delay: Double)
    case failed(CameraError)

    public var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case let .connecting(step): return "Connecting (\(step))"
        case .connected: return "Connected"
        case .streaming: return "Streaming"
        case let .reconnecting(n, d): return String(format: "Reconnecting #%d in %.0f s", n, d)
        case let .failed(e): return "Failed: \(e.description)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .connected, .streaming: return true
        default: return false
        }
    }
}

public enum VideoCodec: String, Codable, Sendable { case h264 = "H.264", hevc = "H.265", raw = "raw", unknown }

/// 🐱 What the stream actually is, as reported by the source (camera notification, file track, SPS).
public struct StreamParameters: Codable, Sendable, Equatable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    /// 🐱 Nominal frame rate announced by the source; the measured rate is in `SourceStatistics`.
    public var nominalFPS: Double?
    /// 🐱 Free-form provenance, e.g. "camera notification 8234" or "requested RES_1920_1080P30".
    public var origin: String

    public init(codec: VideoCodec, width: Int, height: Int, nominalFPS: Double?, origin: String) {
        self.codec = codec
        self.width = width
        self.height = height
        self.nominalFPS = nominalFPS
        self.origin = origin
    }
}

/// 🐱 Counters every source keeps. Values are cumulative since `startPreview()`.
public struct SourceStatistics: Codable, Sendable, Equatable {
    public var bytesReceived: Int = 0
    public var packetsReceived: Int = 0
    public var accessUnitsAssembled: Int = 0
    public var framesDecoded: Int = 0
    public var decodeErrors: Int = 0
    /// 🐱 Compressed frames discarded before decoding (waiting for a key frame, corrupt, late slices).
    public var framesDiscardedBeforeDecode: Int = 0
    public var keyFrameRequests: Int = 0
    public var reconnects: Int = 0
    public var lastFrameHostTime: Double?
    /// 🐱 Packet histogram for diagnostics, keyed by a short label ("msg 200", "stream 0x20"...).
    public var packetTypes: [String: Int] = [:]

    public init() {}
}

/// 🐱 Something worth telling the UI or the session log.
public enum SourceEvent: Sendable {
    case stateChanged(ConnectionState)
    case streamParameters(StreamParameters)
    case log(level: LogLevel, message: String)
    /// 🐱 A compressed access unit as received (for bit-exact archiving). Only emitted by compressed sources.
    case compressedAccessUnit(CompressedAccessUnit)
}

public enum LogLevel: String, Codable, Sendable { case debug, info, warning, error }

/// 🐱 Annex B bytes of one picture plus its timing, exactly as the camera sent them.
public struct CompressedAccessUnit: Sendable {
    public let codec: VideoCodec
    public let annexB: Data
    public let sourceTimestampRaw: Int64
    public let receivedHostTime: Double
    public let isKeyFrame: Bool

    public init(codec: VideoCodec, annexB: Data, sourceTimestampRaw: Int64, receivedHostTime: Double, isKeyFrame: Bool) {
        self.codec = codec
        self.annexB = annexB
        self.sourceTimestampRaw = sourceTimestampRaw
        self.receivedHostTime = receivedHostTime
        self.isKeyFrame = isKeyFrame
    }
}

public struct SourceInfo: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case insta360WiFi, videoFile, synthetic, usbCamera }
    public var kind: Kind
    public var name: String
    /// 🐱 Anything that identifies the physical source: host:port, file path, device unique ID.
    public var address: String
    public var isLive: Bool

    public init(kind: Kind, name: String, address: String, isLive: Bool) {
        self.kind = kind
        self.name = name
        self.address = address
        self.isLive = isLive
    }
}

/// 🐱 The single interface the analysis depends on. Camera protocols can change without touching anything
/// 🐱 downstream of this protocol.
/// 🐱
/// 🐱 Threading: all methods are safe to call from any thread. `onEvent` is called on an internal queue.
public protocol CameraVideoSource: AnyObject, Sendable {
    var info: SourceInfo { get }

    /// 🐱 Establish the link (TCP + handshake, open file, open device). Throws `CameraError`.
    func connect() async throws
    func disconnect() async
    /// 🐱 Start delivering frames. Implies `connect()` if needed.
    func startPreview() async throws
    func stopPreview() async

    /// 🐱 Newest frame not yet consumed, or nil. Non-blocking.
    func getFrame() -> VideoFrame?
    /// 🐱 Suspends until the next frame; nil when the preview stopped.
    func nextFrame() async -> VideoFrame?
    func getConnectionState() -> ConnectionState

    func statistics() -> SourceStatistics
    /// 🐱 Frames replaced in the hand-off buffer because the consumer was too slow.
    var analysisDropCount: Int { get }

    var onEvent: (@Sendable (SourceEvent) -> Void)? { get set }

    /// 🐱 Receive every delivered frame (display, stream statistics), even those the analysis later skips.
    func setPreviewHandler(_ handler: (@Sendable (VideoFrame) -> Void)?)
}

extension CameraVideoSource {
    public func setPreviewHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) {}
}

/// 🐱 Optional capability: sources that can also start the camera's own (full-quality) recording.
public protocol CameraRecordingControl: AnyObject {
    func startCameraRecording() async throws
    /// 🐱 Returns the file path on the camera's card when the camera reports it.
    func stopCameraRecording() async throws -> String?
}

/// 🐱 Optional capability: ask the encoder for a new key frame (used after decoder errors).
public protocol KeyFrameRequesting: AnyObject {
    func requestKeyFrame() async
}
