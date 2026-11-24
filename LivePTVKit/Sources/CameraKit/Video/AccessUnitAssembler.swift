import Foundation

/// 🐱 Rebuilds whole pictures from stream packets.
/// 🐱
/// 🐱 The official Android SDK documents that one frame may arrive split over several packets that share the same
/// 🐱 timestamp, and that feeding partial frames to the decoder corrupts the image. So packets are concatenated
/// 🐱 until the timestamp changes.
/// 🐱
/// 🐱 `.safe` emits a picture when the next picture's first packet arrives (adds up to one frame interval of latency).
/// 🐱 `.lowLatency` additionally lets the caller flush after a short idle gap. If a packet then arrives for a
/// 🐱 timestamp that was already emitted, the emitted picture was incomplete: the slice is dropped, counted,
/// 🐱 and the assembler falls back to `.safe` permanently for this stream.
public struct AccessUnitAssembler {
    public enum Mode: String, Codable, Sendable { case safe, lowLatency }

    public struct Unit: Equatable {
        public let timestamp: Int64
        public let data: Data
        /// 🐱 Host time the last packet of this picture arrived.
        public let receivedHostTime: Double
        public let packetCount: Int
    }

    public private(set) var mode: Mode
    public private(set) var lateSliceCount = 0
    /// 🐱 Set when low-latency mode had to be abandoned.
    public private(set) var fellBackToSafe = false

    private var currentTimestamp: Int64?
    private var buffer = Data()
    private var packets = 0
    private var lastPacketHostTime = 0.0
    private var lastEmittedTimestamp: Int64?

    public init(mode: Mode) { self.mode = mode }

    public var hasPending: Bool { currentTimestamp != nil }
    public var pendingSinceHostTime: Double { lastPacketHostTime }

    /// 🐱 Add one stream packet; returns pictures completed by it (zero or one).
    public mutating func push(timestamp: Int64, payload: Data, hostTime: Double) -> [Unit] {
        var out: [Unit] = []
        if timestamp != currentTimestamp, let emitted = lastEmittedTimestamp, timestamp == emitted {
            // 🐱 Slice for a picture we already handed to the decoder.
            lateSliceCount += 1
            if mode == .lowLatency {
                mode = .safe
                fellBackToSafe = true
            }
            return out
        }
        if let cur = currentTimestamp, cur != timestamp, let unit = finish() {
            out.append(unit)
        }
        if currentTimestamp == nil {
            currentTimestamp = timestamp
            buffer.removeAll(keepingCapacity: true)
            packets = 0
        }
        buffer.append(payload)
        packets += 1
        lastPacketHostTime = hostTime
        return out
    }

    /// 🐱 Low-latency flush: call when no packet arrived for a short while. No-op in `.safe` mode.
    public mutating func flushIfIdle(now: Double, idleSeconds: Double) -> Unit? {
        guard mode == .lowLatency, currentTimestamp != nil, now - lastPacketHostTime >= idleSeconds else { return nil }
        return finish()
    }

    /// 🐱 Emit whatever is pending (end of stream).
    public mutating func flush() -> Unit? { finish() }

    public mutating func reset() {
        currentTimestamp = nil
        buffer.removeAll()
        packets = 0
        lastEmittedTimestamp = nil
    }

    private mutating func finish() -> Unit? {
        guard let ts = currentTimestamp else { return nil }
        let unit = Unit(timestamp: ts, data: buffer, receivedHostTime: lastPacketHostTime, packetCount: packets)
        lastEmittedTimestamp = ts
        currentTimestamp = nil
        buffer = Data()
        packets = 0
        return unit.data.isEmpty ? nil : unit
    }
}
