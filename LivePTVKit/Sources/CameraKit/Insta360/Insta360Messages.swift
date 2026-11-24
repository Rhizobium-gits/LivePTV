import Foundation

/// 🐱 Field numbers and enum values were decoded from the protobuf descriptors published in
/// 🐱 RigacciOrg/insta360-wifi-api (pb2/start_live_stream_pb2.py, video_pb2.py, live_stream_params_update_pb2.py,
/// 🐱 options_pb2.py, start_capture_pb2.py, stop_capture_pb2.py, error_pb2.py), package `insta360.messages`.
public enum Insta360Messages {
    /// 🐱 `insta360.messages.VideoResolution` (subset relevant for a preview stream).
    public enum PreviewResolution: Int, CaseIterable, Codable, Sendable {
        case res1440x720p30 = 9
        case res480x240p30 = 18
        case res1920x1080p30 = 29
        case res424x240p15 = 34
        case res1280x720p30 = 43
        case res640x360p30 = 75

        public var label: String {
            switch self {
            case .res1440x720p30: return "RES_1440_720P30"
            case .res480x240p30: return "RES_480_240P30"
            case .res1920x1080p30: return "RES_1920_1080P30"
            case .res424x240p15: return "RES_424_240P15"
            case .res1280x720p30: return "RES_1280_720P30"
            case .res640x360p30: return "RES_640_360P30"
            }
        }

        public var size: (width: Int, height: Int, fps: Double) {
            switch self {
            case .res1440x720p30: return (1440, 720, 30)
            case .res480x240p30: return (480, 240, 30)
            case .res1920x1080p30: return (1920, 1080, 30)
            case .res424x240p15: return (424, 240, 15)
            case .res1280x720p30: return (1280, 720, 30)
            case .res640x360p30: return (640, 360, 30)
            }
        }
    }

    /// 🐱 `StartLiveStream`: 1 enableAudio, 2 enableVideo, 3 audioType, 4 audioSampleRate, 5 audioBitrate,
    /// 🐱 6 videoBitrate, 7 resolution, 8 enableGyro, 9 videoBitrate1, 10 resolution1, 11 previewStreamNum,
    /// 🐱 12 enableRotate, 13 isForLive.
    /// 🐱 Defaults mirror the request ace-studio sends to an Ace Pro 2.
    public struct StartLiveStream: Sendable, Equatable {
        public var resolution: PreviewResolution
        /// 🐱 Secondary low-resolution stream requested by the official apps; nil omits the field.
        public var secondaryResolution: PreviewResolution?
        public var videoBitrateMbps: UInt32?
        public var enableGyro: Bool
        public var audioSampleRate: UInt32?

        public init(resolution: PreviewResolution, secondaryResolution: PreviewResolution? = .res424x240p15,
                    videoBitrateMbps: UInt32? = nil, enableGyro: Bool = false, audioSampleRate: UInt32? = 48_000) {
            self.resolution = resolution
            self.secondaryResolution = secondaryResolution
            self.videoBitrateMbps = videoBitrateMbps
            self.enableGyro = enableGyro
            self.audioSampleRate = audioSampleRate
        }

        public func encode() -> Data {
            var w = ProtobufWriter()
            w.bool(2, true)
            if let r = audioSampleRate { w.uint32(4, r) }
            if let b = videoBitrateMbps { w.uint32(6, b) }
            w.enumValue(7, resolution.rawValue)
            if enableGyro { w.bool(8, true) }
            if let r2 = secondaryResolution { w.enumValue(10, r2.rawValue) }
            return w.data
        }
    }

    /// 🐱 `LiveStreamParamsUpdate` (notification 8234): 1 video_encode_type (0 H.264, 1 H.265), 2 res_width,
    /// 🐱 3 res_height, 4 res_fps.
    public struct LiveStreamParamsUpdate: Equatable, Sendable {
        public let codec: VideoCodec?
        public let width: Int
        public let height: Int
        public let fps: Int

        public init(_ body: Data) throws {
            let m = try ProtobufMessage(body)
            switch m.varint(1) {
            case 0?: codec = .h264
            case 1?: codec = .hevc
            default: codec = nil
            }
            width = Int(m.varint(2) ?? 0)
            height = Int(m.varint(3) ?? 0)
            fps = Int(m.varint(4) ?? 0)
        }
    }

    /// 🐱 `StartCapture`: 1 mode (`CaptureMode`, 1 = Capture_MODE_NORMAL).
    public static func startCapture() -> Data {
        var w = ProtobufWriter()
        w.enumValue(1, 1)
        return w.data
    }

    /// 🐱 `StopCaptureResp`: 1 video { 1 uri, 2 file_size, 3 total_time }.
    public static func videoURI(fromStopCaptureResponse body: Data) -> String? {
        (try? ProtobufMessage(body))?.message(1)?.string(1)
    }

    /// 🐱 `Error`: 1 code, 2 message. Codes: 0 UNKNOWN_ERROR, 1 UNKNOWN_MSG_CODE, 2 UNKNOWN_MSG_PAYLOAD,
    /// 🐱 3 EXECUTE_ERROR, 4 OVER_FILE_NUMBER_LIMIT, 5 SYSTEM_BUSY.
    public static func errorDescription(_ body: Data) -> String? {
        guard !body.isEmpty, let m = try? ProtobufMessage(body) else { return nil }
        let names = ["UNKNOWN_ERROR", "UNKNOWN_MSG_CODE", "UNKNOWN_MSG_PAYLOAD", "EXECUTE_ERROR", "OVER_FILE_NUMBER_LIMIT", "SYSTEM_BUSY"]
        let code = m.varint(1).map { Int($0) }
        let name = code.flatMap { $0 < names.count ? names[$0] : "code \($0)" }
        return [name, m.string(2)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
    }
}
