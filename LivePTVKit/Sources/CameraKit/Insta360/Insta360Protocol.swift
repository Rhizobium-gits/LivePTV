import Foundation

/// 🐱 Insta360 camera control/stream protocol over TCP (camera access point 192.168.42.1, port 6666).
/// 🐱
/// 🐱 Not an official API. Layout cross-checked against four independent open-source implementations
/// 🐱 (RigacciOrg/insta360-wifi-api, xaionaro-go/insta360ctl, Daiki-Iijima/insta360-go-ultra-sdk, the `insta360`
/// 🐱 PyPI package used by ace-studio for Ace Pro 2). See docs/TECHNICAL_REPORT.md for sources and caveats.
/// 🐱
/// 🐱 Wire format (all integers little-endian):
/// 🐱   packet   = u32 total_length (includes these 4 bytes) + payload
/// 🐱   SYNC     = 06 00 00 "syNceNdinS"                  (client sends after connect, camera echoes)
/// 🐱   KEEPALIVE= 05 00 00                               (both sides, every ~2 s)
/// 🐱   MESSAGE  = 04 00 00 code:u16 02 seq:u24 80 00 00 protobuf...
/// 🐱   STREAM   = 01 00 00 type:u8 timestamp:u64 data... (type 0x20 = H.264/H.265 Annex B video)
public enum Insta360Protocol {
    public static let defaultHost = "192.168.42.1"
    public static let defaultPort: UInt16 = 6666
    public static let syncMagic = Data("syNceNdinS".utf8)
    /// 🐱 Guard against garbage lengths. Real video packets are far below this.
    public static let maxPacketLength = 8 * 1024 * 1024

    public enum Command: UInt16, Sendable {
        case startLiveStream = 1
        case stopLiveStream = 2
        case takePicture = 3
        case startCapture = 4
        case stopCapture = 5
        case setOptions = 7
        case getOptions = 8
        case getCurrentCaptureStatus = 15
        case iframeRequest = 105

        public var name: String {
            switch self {
            case .startLiveStream: return "START_LIVE_STREAM"
            case .stopLiveStream: return "STOP_LIVE_STREAM"
            case .takePicture: return "TAKE_PICTURE"
            case .startCapture: return "START_CAPTURE"
            case .stopCapture: return "STOP_CAPTURE"
            case .setOptions: return "SET_OPTIONS"
            case .getOptions: return "GET_OPTIONS"
            case .getCurrentCaptureStatus: return "GET_CURRENT_CAPTURE_STATUS"
            case .iframeRequest: return "IFRAME_REQUEST"
            }
        }
    }

    public enum ResponseCode {
        public static let ok: UInt16 = 200
        public static let badRequest: UInt16 = 400
        public static let error: UInt16 = 500
        public static let notImplemented: UInt16 = 501
        /// 🐱 Codes >= 8192 are unsolicited camera notifications.
        public static let notificationBase: UInt16 = 8192
    }

    public enum Notification {
        public static let captureStopped: UInt16 = 8201
        public static let currentCaptureStatus: UInt16 = 8208
        public static let authorizationResult: UInt16 = 8209
        public static let updateLiveStreamParams: UInt16 = 8234
    }

    public enum StreamType {
        public static let video: UInt8 = 0x20
        public static let gyro: UInt8 = 0x30
        public static let sync: UInt8 = 0x40
    }

    public struct MessageHeader: Equatable, Sendable {
        public let code: UInt16
        public let sequence: UInt32
    }

    public enum Packet: Equatable, Sendable {
        case sync
        case keepAlive
        case message(MessageHeader, body: Data)
        case stream(type: UInt8, timestamp: UInt64, data: Data)
        case unknown(Data)

        public var histogramLabel: String {
            switch self {
            case .sync: return "sync"
            case .keepAlive: return "keepalive"
            case let .message(h, _): return h.code >= ResponseCode.notificationBase ? "notify \(h.code)" : "msg \(h.code)"
            case let .stream(t, _, _): return String(format: "stream 0x%02x", t)
            case let .unknown(d): return "unknown 0x\(d.first.map { String(format: "%02x", $0) } ?? "--")"
            }
        }
    }

    // 🐱 MARK: encoding

    public static func frame(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        appendLE(UInt32(payload.count + 4), to: &out)
        out.append(payload)
        return out
    }

    public static func syncPacket() -> Data { frame(Data([0x06, 0x00, 0x00]) + syncMagic) }
    public static func keepAlivePacket() -> Data { frame(Data([0x05, 0x00, 0x00])) }

    public static func messagePacket(code: UInt16, sequence: UInt32, body: Data) -> Data {
        var p = Data([0x04, 0x00, 0x00])
        appendLE(code, to: &p)
        p.append(0x02)                                   // 🐱 content type: protobuf
        p.append(contentsOf: [UInt8(sequence & 0xFF), UInt8((sequence >> 8) & 0xFF), UInt8((sequence >> 16) & 0xFF)])
        p.append(contentsOf: [0x80, 0x00, 0x00])
        p.append(body)
        return frame(p)
    }

    // 🐱 MARK: decoding

    /// 🐱 Classify one de-framed payload.
    public static func parse(payload p: Data) -> Packet {
        let b = [UInt8](p.prefix(12))
        guard b.count >= 3, b[1] == 0, b[2] == 0 else { return .unknown(p) }
        switch b[0] {
        case 0x06 where p.count == 3 + syncMagic.count && p.suffix(syncMagic.count) == syncMagic:
            return .sync
        case 0x05 where p.count == 3:
            return .keepAlive
        case 0x04 where p.count >= 12:
            let code = UInt16(b[3]) | UInt16(b[4]) << 8
            let seq = UInt32(b[6]) | UInt32(b[7]) << 8 | UInt32(b[8]) << 16
            return .message(MessageHeader(code: code, sequence: seq), body: p.dropFirst(12).withFreshIndices())
        case 0x01 where p.count >= 12:
            var ts: UInt64 = 0
            for i in 0..<8 { ts |= UInt64(b[4 + i]) << (8 * UInt64(i)) }
            return .stream(type: b[3], timestamp: ts, data: p.dropFirst(12).withFreshIndices())
        default:
            return .unknown(p)
        }
    }

    static func appendLE<T: FixedWidthInteger>(_ v: T, to d: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }
}

/// 🐱 Incremental de-framer for the TCP byte stream.
public struct Insta360Framer {
    private var buffer = Data()
    private var readOffset = 0

    public init() {}

    public var bufferedByteCount: Int { buffer.count - readOffset }

    /// 🐱 Append received bytes and return every complete payload (length prefix stripped).
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        while buffer.count - readOffset >= 4 {
            let s = buffer.startIndex + readOffset
            let len = Int(buffer[s]) | Int(buffer[s + 1]) << 8 | Int(buffer[s + 2]) << 16 | Int(buffer[s + 3]) << 24
            guard len >= 4, len <= Insta360Protocol.maxPacketLength else {
                throw CameraError.protocolViolation("invalid packet length \(len)")
            }
            guard buffer.count - readOffset >= len else { break }
            out.append(buffer.subdata(in: (s + 4)..<(s + len)))
            readOffset += len
        }
        // 🐱 Compact occasionally instead of on every packet.
        if readOffset > 0 && (readOffset >= buffer.count || readOffset > 1 << 20) {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readOffset))
            readOffset = 0
        }
        return out
    }

    public mutating func reset() {
        buffer = Data()
        readOffset = 0
    }
}

extension Data {
    /// 🐱 Copy a slice so its indices start at 0 (avoids index surprises with Data slices).
    func withFreshIndices() -> Data { Data(self) }
}
