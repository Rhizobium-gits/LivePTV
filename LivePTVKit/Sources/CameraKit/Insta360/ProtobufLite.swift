import Foundation

/// 🐱 Just enough Protocol Buffers wire format to build and read the few camera messages this app uses.
/// 🐱 Avoids pulling a protobuf runtime and generated code into the iPad app.
public struct ProtobufWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        rawVarint(value)
    }

    public mutating func bool(_ field: Int, _ value: Bool) { varint(field, value ? 1 : 0) }
    public mutating func uint32(_ field: Int, _ value: UInt32) { varint(field, UInt64(value)) }
    public mutating func enumValue(_ field: Int, _ value: Int) { varint(field, UInt64(bitPattern: Int64(value))) }

    public mutating func bytes(_ field: Int, _ value: Data) {
        key(field, wireType: 2)
        rawVarint(UInt64(value.count))
        data.append(value)
    }

    public mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    public mutating func message(_ field: Int, _ value: ProtobufWriter) { bytes(field, value.data) }

    private mutating func key(_ field: Int, wireType: UInt64) { rawVarint(UInt64(field) << 3 | wireType) }

    private mutating func rawVarint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}

/// 🐱 Parsed message: field number -> values in order of appearance.
public struct ProtobufMessage {
    public enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    public private(set) var fields: [Int: [Value]] = [:]

    public init(_ data: Data) throws {
        let b = [UInt8](data)
        var i = 0
        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < b.count, shift < 64 else { throw CameraError.protocolViolation("truncated protobuf varint") }
                let c = b[i]; i += 1
                result |= UInt64(c & 0x7F) << shift
                if c < 0x80 { return result }
                shift += 7
            }
        }
        while i < b.count {
            let key = try readVarint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0:
                value = .varint(try readVarint())
            case 1:
                guard i + 8 <= b.count else { throw CameraError.protocolViolation("truncated fixed64") }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 8
                value = .fixed64(v)
            case 2:
                let n = Int(try readVarint())
                guard n >= 0, i + n <= b.count else { throw CameraError.protocolViolation("truncated length-delimited field") }
                value = .bytes(Data(b[i..<(i + n)]))
                i += n
            case 5:
                guard i + 4 <= b.count else { throw CameraError.protocolViolation("truncated fixed32") }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(b[i + k]) << (8 * UInt32(k)) }
                i += 4
                value = .fixed32(v)
            default:
                throw CameraError.protocolViolation("unsupported protobuf wire type \(key & 7)")
            }
            fields[field, default: []].append(value)
        }
    }

    public func varint(_ field: Int) -> UInt64? {
        for v in fields[field] ?? [] { if case let .varint(x) = v { return x } }
        return nil
    }

    public func bytes(_ field: Int) -> Data? {
        for v in fields[field] ?? [] { if case let .bytes(x) = v { return x } }
        return nil
    }

    public func string(_ field: Int) -> String? { bytes(field).flatMap { String(data: $0, encoding: .utf8) } }
    public func message(_ field: Int) -> ProtobufMessage? { bytes(field).flatMap { try? ProtobufMessage($0) } }
}
