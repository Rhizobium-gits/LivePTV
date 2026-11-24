import Foundation

/// 🐱 Converts raw camera timestamps to seconds without assuming their unit.
/// 🐱
/// 🐱 Community documentation disagrees on the unit of the Insta360 stream timestamp (microseconds in some
/// 🐱 sources, milliseconds in others), so the unit is inferred from the median spacing of the first frames:
/// 🐱 a 8...120 fps video has 8...125 ms between frames, which lands in exactly one of the ranges below.
/// 🐱 Until the unit is locked, frames are marked `.provisional` and must not be used for velocities.
public struct TimestampNormalizer: Sendable {
    public enum Unit: String, Codable, Sendable {
        case nanoseconds, microseconds, milliseconds
        public var seconds: Double {
            switch self {
            case .nanoseconds: return 1e-9
            case .microseconds: return 1e-6
            case .milliseconds: return 1e-3
            }
        }
    }

    public struct Output: Equatable, Sendable {
        public let seconds: Double
        public let quality: TimestampQuality
        public let segment: Int
    }

    public private(set) var unit: Unit?
    /// 🐱 True when the spacing matched no plausible unit; host arrival times are used instead.
    public private(set) var unusable = false
    public private(set) var segment = 0
    public private(set) var medianFrameInterval: Double?

    private let framesToLock: Int
    private var firstRaws: [Int64] = []
    private var lastRaw: Int64?

    public init(framesToLock: Int = 6) { self.framesToLock = max(3, framesToLock) }

    /// 🐱 Classify a median tick spacing. Exposed for tests.
    public static func classify(medianDelta d: Double) -> Unit? {
        switch d {
        case 2_000_000...250_000_000: return .nanoseconds
        case 2_000...250_000: return .microseconds
        case 2...250: return .milliseconds
        default: return nil
        }
    }

    public mutating func normalize(raw: Int64, hostTime: Double) -> Output {
        if unusable { return Output(seconds: hostTime, quality: .hostArrival, segment: segment) }

        // 🐱 Backwards jump or a gap longer than 5 s means the stream restarted: new segment.
        if let last = lastRaw {
            let gapSeconds = Double(raw - last) * (unit ?? .microseconds).seconds
            if raw < last || (unit != nil && gapSeconds > 5) {
                segment += 1
            }
        }
        lastRaw = raw

        if unit == nil {
            firstRaws.append(raw)
            if firstRaws.count >= framesToLock {
                let deltas = zip(firstRaws.dropFirst(), firstRaws).map { Double($0 - $1) }.filter { $0 > 0 }.sorted()
                if deltas.isEmpty {
                    unusable = true
                    segment += 1
                } else {
                    let median = deltas[deltas.count / 2]
                    if let u = Self.classify(medianDelta: median) {
                        unit = u
                        medianFrameInterval = median * u.seconds
                        // 🐱 Provisional frames used a guessed unit, so the timeline changes here: new segment,
                        // 🐱 which makes trackers restart instead of mixing two time scales.
                        segment += 1
                    } else {
                        unusable = true
                        segment += 1
                    }
                }
                firstRaws.removeAll()
            }
            if unusable { return Output(seconds: hostTime, quality: .hostArrival, segment: segment) }
            if unit == nil {
                return Output(seconds: Double(raw) * Unit.microseconds.seconds, quality: .provisional, segment: segment)
            }
        }
        return Output(seconds: Double(raw) * unit!.seconds, quality: .source, segment: segment)
    }

    public mutating func reset() { self = TimestampNormalizer(framesToLock: framesToLock) }
}
