import Foundation

/// 🐱 Hand-off point between a video source (producer) and the analysis (consumer).
/// 🐱
/// 🐱 `.latestOnly` is for live sources: if analysis is slower than the camera, older frames are replaced and
/// 🐱 counted in `overwrittenCount`, so latency never accumulates and every drop is accounted for.
/// 🐱 `.lossless` is for offline files: the producer waits until the consumer has taken the frame.
/// 🐱
/// 🐱 All locking happens in small synchronous helpers; async functions never hold the lock across a suspension.
public final class FrameMailbox: @unchecked Sendable {
    public enum Policy: Sendable { case latestOnly, lossless }

    public let policy: Policy
    private let lock = NSLock()
    private var slot: VideoFrame?
    private var consumerWaiter: CheckedContinuation<VideoFrame?, Never>?
    private var producerWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var _overwritten = 0
    private var _delivered = 0
    private var _onPut: (@Sendable (VideoFrame) -> Void)?

    /// 🐱 Called for every frame the source delivers (before any dropping): the smooth display and the stream
    /// 🐱 statistics use this, independent of how fast the analysis consumes frames.
    public var onPut: (@Sendable (VideoFrame) -> Void)? {
        get { lock.withLock { _onPut } }
        set { lock.withLock { _onPut = newValue } }
    }

    public init(policy: Policy) { self.policy = policy }

    /// 🐱 Frames that were replaced before the consumer took them (analysis drops).
    public var overwrittenCount: Int { lock.withLock { _overwritten } }
    public var deliveredCount: Int { lock.withLock { _delivered } }
    public var isClosed: Bool { lock.withLock { closed } }

    /// 🐱 Re-open after `close()` (a new preview session) and reset counters.
    public func reset() {
        lock.withLock {
            slot = nil
            closed = false
            _overwritten = 0
            _delivered = 0
        }
    }

    /// 🐱 Producer side. Never blocks; replaces (and counts) an unconsumed frame.
    public func put(_ frame: VideoFrame) {
        onPut?(frame)
        let waiter: CheckedContinuation<VideoFrame?, Never>? = lock.withLock {
            if closed { return nil }
            if let w = consumerWaiter {
                consumerWaiter = nil
                _delivered += 1
                return w
            }
            if slot != nil { _overwritten += 1 }
            slot = frame
            return nil
        }
        waiter?.resume(returning: frame)
    }

    /// 🐱 Producer side for `.lossless`: suspends while the previous frame has not been consumed.
    public func putWaiting(_ frame: VideoFrame) async {
        onPut?(frame)
        while true {
            switch tryPutWithoutOverwrite(frame) {
            case .done: return
            case .full:
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    registerProducer(c)
                }
            }
        }
    }

    /// 🐱 Non-blocking: newest unconsumed frame, or nil.
    public func take() -> VideoFrame? {
        let (frame, producers) = takeLocked()
        producers.forEach { $0.resume() }
        return frame
    }

    /// 🐱 Suspends until a frame is available. Returns nil once the mailbox is closed and drained.
    public func next() async -> VideoFrame? {
        if let frame = take() { return frame }
        return await withCheckedContinuation { (c: CheckedContinuation<VideoFrame?, Never>) in
            registerConsumer(c)
        }
    }

    /// 🐱 Stop accepting frames. A waiting consumer gets nil; a pending frame can still be drained by next().
    public func close() {
        let (consumer, producers): (CheckedContinuation<VideoFrame?, Never>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            closed = true
            let c = consumerWaiter
            consumerWaiter = nil
            let p = producerWaiters
            producerWaiters.removeAll()
            return (c, p)
        }
        consumer?.resume(returning: nil)
        producers.forEach { $0.resume() }
    }

    // 🐱 MARK: synchronous helpers (the only places that take the lock)

    private enum PutResult { case done, full }

    private func tryPutWithoutOverwrite(_ frame: VideoFrame) -> PutResult {
        let waiter: CheckedContinuation<VideoFrame?, Never>?
        lock.lock()
        if closed {
            lock.unlock()
            return .done
        }
        if let w = consumerWaiter {
            consumerWaiter = nil
            _delivered += 1
            waiter = w
        } else if slot == nil {
            slot = frame
            waiter = nil
        } else {
            lock.unlock()
            return .full
        }
        lock.unlock()
        waiter?.resume(returning: frame)
        return .done
    }

    private func registerProducer(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        // 🐱 Re-check under the lock: the slot may have been emptied (or the box closed) meanwhile.
        if slot == nil || closed {
            lock.unlock()
            c.resume()
            return
        }
        producerWaiters.append(c)
        lock.unlock()
    }

    private func takeLocked() -> (VideoFrame?, [CheckedContinuation<Void, Never>]) {
        lock.withLock {
            let frame = slot
            slot = nil
            if frame != nil { _delivered += 1 }
            let p = producerWaiters
            producerWaiters.removeAll()
            return (frame, p)
        }
    }

    private func registerConsumer(_ c: CheckedContinuation<VideoFrame?, Never>) {
        lock.lock()
        if let frame = slot {
            slot = nil
            _delivered += 1
            let producers = producerWaiters
            producerWaiters.removeAll()
            lock.unlock()
            c.resume(returning: frame)
            producers.forEach { $0.resume() }
            return
        }
        if closed {
            lock.unlock()
            c.resume(returning: nil)
            return
        }
        // 🐱 Single consumer. A second concurrent next() releases the first with nil.
        let previous = consumerWaiter
        consumerWaiter = c
        lock.unlock()
        previous?.resume(returning: nil)
    }
}
