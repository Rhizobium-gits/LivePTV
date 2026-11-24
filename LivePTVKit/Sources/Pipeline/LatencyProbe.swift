import CameraKit
import Foundation

/// 🐱 End-to-end ("glass-to-result") latency test.
/// 🐱
/// 🐱 Point the camera at the iPad screen. The app alternates the screen between black and white; the probe
/// 🐱 records when each change was put on screen and finds the first analysed frame whose mean brightness crossed
/// 🐱 to the new level. Latency = that frame's arrival (or analysis end) − screen change. The result includes
/// 🐱 camera exposure, encoding, Wi-Fi, decoding and analysis; it also includes up to one display refresh
/// 🐱 (8–17 ms) because the exact moment the panel lit up is not observable from the app.
/// 🐱 The same flashes are visible in the camera's own SD recording and serve as sync marks for aligning it.
public final class LatencyProbe: @unchecked Sendable {
    public struct Measurement: Codable, Sendable, Equatable {
        public var screenChangeHostTime: Double
        public var toBright: Bool
        public var frameIndex: Int
        public var frameReceivedHostTime: Double
        public var analysisEndHostTime: Double
        public var toReceiveMs: Double { (frameReceivedHostTime - screenChangeHostTime) * 1000 }
        public var toResultMs: Double { (analysisEndHostTime - screenChangeHostTime) * 1000 }
    }

    private let lock = NSLock()
    private var running = false
    private var minLuma = Double.infinity
    private var maxLuma = -Double.infinity
    private var pending: (time: Double, bright: Bool)?
    private var changes = 0
    private var _results: [Measurement] = []
    /// 🐱 Minimum brightness difference (grey levels) between the two screen states to accept a crossing.
    public var minimumContrast = 20.0

    public init() {}

    public var isRunning: Bool { lock.withLock { running } }
    public var results: [Measurement] { lock.withLock { _results } }

    public func begin() {
        lock.withLock {
            running = true
            minLuma = .infinity
            maxLuma = -.infinity
            pending = nil
            changes = 0
            _results.removeAll()
        }
    }

    public func end() { lock.withLock { running = false; pending = nil } }

    /// 🐱 Call right after the screen was switched (as close to the actual draw as possible).
    public func screenChanged(toBright: Bool, hostTime: Double = HostClock.now()) {
        lock.withLock {
            guard running else { return }
            changes += 1
            pending = (hostTime, toBright)
        }
    }

    /// 🐱 Feed every analysed frame. Returns a measurement when this frame completes one.
    @discardableResult
    public func observe(meanLuma: Double, frameIndex: Int, frameReceivedHostTime: Double, analysisEndHostTime: Double) -> Measurement? {
        lock.withLock {
            guard running else { return nil }
            minLuma = min(minLuma, meanLuma)
            maxLuma = max(maxLuma, meanLuma)
            // 🐱 The first two changes only calibrate the black/white levels.
            guard let p = pending, changes > 2, maxLuma - minLuma >= minimumContrast,
                  frameReceivedHostTime > p.time else { return nil }
            let mid = (minLuma + maxLuma) / 2
            guard p.bright ? meanLuma > mid : meanLuma < mid else { return nil }
            let m = Measurement(screenChangeHostTime: p.time, toBright: p.bright, frameIndex: frameIndex,
                                frameReceivedHostTime: frameReceivedHostTime, analysisEndHostTime: analysisEndHostTime)
            _results.append(m)
            pending = nil
            return m
        }
    }

    public var medianToResultMs: Double? {
        let v = results.map(\.toResultMs).sorted()
        return v.isEmpty ? nil : v[v.count / 2]
    }

    public var medianToReceiveMs: Double? {
        let v = results.map(\.toReceiveMs).sorted()
        return v.isEmpty ? nil : v[v.count / 2]
    }
}
