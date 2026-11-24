import CoreVideo
import Foundation

/// 🐱 Analytic flow fields with exactly known velocity, in pixels per second, origin at the image centre.
public enum SyntheticFlow: Sendable, Codable, Equatable {
    case uniform(u: Double, v: Double)
    /// 🐱 Rigid rotation, `omega` in rad/s (positive = clockwise on screen, since image y points down).
    case solidBodyRotation(omega: Double)
    /// 🐱 Lamb-Oseen vortex: circulation in px²/s, core radius in px.
    case lambOseen(circulation: Double, coreRadius: Double)
    /// 🐱 Plane Poiseuille flow along x between y = 0 and y = height.
    case poiseuille(uMax: Double)

    public func velocity(x: Double, y: Double, width: Double, height: Double) -> (u: Double, v: Double) {
        let cx = width / 2, cy = height / 2
        switch self {
        case let .uniform(u, v):
            return (u, v)
        case let .solidBodyRotation(omega):
            return (-omega * (y - cy), omega * (x - cx))
        case let .lambOseen(gamma, rc):
            let dx = x - cx, dy = y - cy
            let r2 = dx * dx + dy * dy
            guard r2 > 1e-12 else { return (0, 0) }
            let vTheta = gamma / (2 * .pi * sqrt(r2)) * (1 - exp(-r2 / (rc * rc)))
            let r = sqrt(r2)
            return (-vTheta * dy / r, vTheta * dx / r)
        case let .poiseuille(uMax):
            let eta = y / height
            return (4 * uMax * eta * (1 - eta), 0)
        }
    }
}

/// 🐱 Synthetic particle images with a known flow: the ground truth for validating detection, tracking and the
/// 🐱 velocity field, and a way to develop without the camera.
public final class TestVideoSource: CameraVideoSource, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var width = 640
        public var height = 480
        public var fps = 30.0
        public var particleCount = 600
        /// 🐱 Gaussian particle image standard deviation in px (diameter ≈ 4σ).
        public var particleSigma = 1.2
        public var peakIntensity = 180.0
        public var background = 12.0
        public var noiseStd = 2.0
        public var flow: SyntheticFlow = .lambOseen(circulation: 60_000, coreRadius: 60)
        /// 🐱 Brownian diffusion coefficient in px²/s added on top of the flow (0 = none).
        public var brownianD = 0.0
        /// 🐱 Particles in this outer band (fraction of width/height) never move: a textured static background.
        public var staticMarginFraction = 0.0
        /// 🐱 Simulated camera shake: random per-frame image shift (px, std) and rotation (rad, std) of the whole picture.
        public var shakeStdPx = 0.0
        public var shakeRotationStd = 0.0
        public var seed: UInt64 = 42
        /// 🐱 Probability that a frame is generated but not delivered (simulated camera/network drop).
        public var dropProbability = 0.0
        /// 🐱 `true` = paced at `fps` like a camera; `false` = as fast as the consumer takes frames (no drops).
        public var realTime = true
        public var frameLimit: Int?
        /// 🐱 Realistic scene (optional): particles move in true plane coordinates and are drawn where the camera sees
        /// 🐱 them (`apparentPosition`, e.g. through a bottle; nil = not visible), and `overlay(frame, image)` adds what
        /// 🐱 is not flow (reflections, glare, glints) to the grey levels before noise and clipping.
        public var apparentPosition: (@Sendable (Double, Double) -> (x: Double, y: Double)?)?
        public var overlay: (@Sendable (Int, inout [Float]) -> Void)?

        public init() {}
    }

    public let configuration: Configuration
    public let info: SourceInfo
    public var onEvent: (@Sendable (SourceEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    private let lock = NSLock()
    private var _onEvent: (@Sendable (SourceEvent) -> Void)?
    private var _state: ConnectionState = .disconnected
    private var _stats = SourceStatistics()
    private let mailbox: FrameMailbox
    private var task: Task<Void, Never>?
    private var pool: CVPixelBufferPool?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.mailbox = FrameMailbox(policy: configuration.realTime ? .latestOnly : .lossless)
        self.info = SourceInfo(kind: .synthetic, name: "Synthetic particles", address: "\(configuration.flow)", isLive: configuration.realTime)
    }

    /// 🐱 Exact velocity at a point (px/s).
    public func groundTruthVelocity(x: Double, y: Double) -> (u: Double, v: Double) {
        configuration.flow.velocity(x: x, y: y, width: Double(configuration.width), height: Double(configuration.height))
    }

    public func getFrame() -> VideoFrame? { mailbox.take() }
    public func setPreviewHandler(_ handler: (@Sendable (VideoFrame) -> Void)?) { mailbox.onPut = handler }
    public func nextFrame() async -> VideoFrame? { await mailbox.next() }
    public func getConnectionState() -> ConnectionState { lock.withLock { _state } }
    public func statistics() -> SourceStatistics { lock.withLock { _stats } }
    public var analysisDropCount: Int { mailbox.overwrittenCount }

    private func setState(_ s: ConnectionState) {
        let handler: (@Sendable (SourceEvent) -> Void)? = lock.withLock {
            guard _state != s else { return nil }
            _state = s
            return _onEvent
        }
        handler?(.stateChanged(s))
    }

    public func connect() async throws {
        if getConnectionState().isActive { return }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: configuration.width,
            kCVPixelBufferHeightKey: configuration.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
        guard let p else { throw CameraError.deviceUnavailable("cannot allocate synthetic frames") }
        pool = p
        onEvent?(.streamParameters(StreamParameters(codec: .raw, width: configuration.width, height: configuration.height,
                                                    nominalFPS: configuration.fps, origin: "synthetic")))
        setState(.connected)
    }

    public func disconnect() async {
        await stopPreview()
        setState(.disconnected)
    }

    public func startPreview() async throws {
        if !getConnectionState().isActive { try await connect() }
        task?.cancel()
        mailbox.reset()
        lock.withLock { _stats = SourceStatistics() }
        setState(.streaming)
        let cfg = configuration
        let pool = self.pool!
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var generator = ParticleImageGenerator(configuration: cfg)
            let start = HostClock.now()
            var index = 0
            var frameNumber = 0
            while !Task.isCancelled {
                if let limit = cfg.frameLimit, frameNumber >= limit { break }
                let t = Double(frameNumber) / cfg.fps
                if cfg.realTime {
                    let wait = start + t - HostClock.now()
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
                guard let pixels = pb else { break }
                generator.render(into: pixels)
                let dropped = cfg.dropProbability > 0 && generator.random() < cfg.dropProbability
                generator.advance(dt: 1 / cfg.fps)
                frameNumber += 1
                guard let self else { return }
                if dropped { continue }
                let now = HostClock.now()
                let frame = VideoFrame(index: index, pixelBuffer: pixels, presentationTime: t, timestampQuality: .synthetic, segment: 0,
                                       timing: FrameTiming(sourceTimestampRaw: Int64(frameNumber - 1), receivedHostTime: now, decodedHostTime: now))
                index += 1
                self.lock.withLock {
                    self._stats.framesDecoded += 1
                    self._stats.lastFrameHostTime = now
                }
                if cfg.realTime { self.mailbox.put(frame) } else { await self.mailbox.putWaiting(frame) }
            }
            self?.mailbox.close()
        }
    }

    public func stopPreview() async {
        task?.cancel()
        task = nil
        mailbox.close()
        if getConnectionState() == .streaming { setState(.connected) }
    }
}

/// 🐱 Renders Gaussian particle images and advects particles with RK4 through the analytic flow.
public struct ParticleImageGenerator {
    public let configuration: TestVideoSource.Configuration
    public private(set) var positions: [(x: Double, y: Double)] = []
    private var rng: SplitMix64

    public init(configuration: TestVideoSource.Configuration) {
        self.configuration = configuration
        self.rng = SplitMix64(seed: configuration.seed)
        positions = (0..<configuration.particleCount).map { _ in randomPosition() }
    }

    public mutating func random() -> Double { rng.nextUnit() }

    private mutating func randomPosition() -> (x: Double, y: Double) {
        (rng.nextUnit() * Double(configuration.width), rng.nextUnit() * Double(configuration.height))
    }

    private func vel(_ x: Double, _ y: Double) -> (Double, Double) {
        let v = configuration.flow.velocity(x: x, y: y, width: Double(configuration.width), height: Double(configuration.height))
        return (v.u, v.v)
    }

    /// 🐱 Current simulated camera pose (shift x, shift y, rotation), drawn anew for every frame.
    public private(set) var shake = (x: 0.0, y: 0.0, r: 0.0)
    public private(set) var frameNumber = 0

    private func isStatic(_ x: Double, _ y: Double) -> Bool {
        let m = configuration.staticMarginFraction
        guard m > 0 else { return false }
        let w = Double(configuration.width), h = Double(configuration.height)
        return x < m * w || x > (1 - m) * w || y < m * h || y > (1 - m) * h
    }

    public mutating func advance(dt: Double) {
        frameNumber += 1
        let w = Double(configuration.width), h = Double(configuration.height)
        if configuration.shakeStdPx > 0 || configuration.shakeRotationStd > 0 {
            shake = (rng.nextGaussian() * configuration.shakeStdPx, rng.nextGaussian() * configuration.shakeStdPx,
                     rng.nextGaussian() * configuration.shakeRotationStd)
        }
        for i in positions.indices {
            let (x, y) = positions[i]
            if isStatic(x, y) { continue }
            let k1 = vel(x, y)
            let k2 = vel(x + 0.5 * dt * k1.0, y + 0.5 * dt * k1.1)
            let k3 = vel(x + 0.5 * dt * k2.0, y + 0.5 * dt * k2.1)
            let k4 = vel(x + dt * k3.0, y + dt * k3.1)
            var nx = x + dt / 6 * (k1.0 + 2 * k2.0 + 2 * k3.0 + k4.0)
            var ny = y + dt / 6 * (k1.1 + 2 * k2.1 + 2 * k3.1 + k4.1)
            if configuration.brownianD > 0 {
                let step = sqrt(2 * configuration.brownianD * dt)
                nx += step * rng.nextGaussian()
                ny += step * rng.nextGaussian()
            }
            // 🐱 Particles leaving the field are replaced at random positions (like seeding in a real flow).
            positions[i] = (nx < 0 || ny < 0 || nx >= w || ny >= h) ? randomPosition() : (nx, ny)
        }
    }

    /// 🐱 Write the luma plane (and neutral chroma) of a 420f pixel buffer.
    public mutating func render(into pixels: CVPixelBuffer) {
        let w = configuration.width, h = configuration.height
        var image = [Float](repeating: Float(configuration.background), count: w * h)
        let sigma = configuration.particleSigma
        let radius = Int(ceil(3.5 * sigma))
        let inv2s2 = 1.0 / (2 * sigma * sigma)
        let peak = configuration.peakIntensity
        let (sx, sy, sr) = shake
        let mx = Double(w) / 2, my = Double(h) / 2
        let seen = configuration.apparentPosition
        for q0 in positions {
            var q = q0
            if let seen {
                guard let a = seen(q0.x, q0.y) else { continue }
                q = (a.x, a.y)
            }
            // 🐱 camera pose applied to the whole scene (rotation about the image centre, then shift)
            let rx = q.x - mx, ry = q.y - my
            let p = (x: mx + cos(sr) * rx - sin(sr) * ry + sx, y: my + sin(sr) * rx + cos(sr) * ry + sy)
            let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
            let y0 = max(0, cy - radius), y1 = min(h - 1, cy + radius), x0 = max(0, cx - radius), x1 = min(w - 1, cx + radius)
            guard y0 <= y1, x0 <= x1 else { continue }   // 🐱 entirely outside the frame
            for yy in y0...y1 {
                let dy = Double(yy) - p.y
                for xx in x0...x1 {
                    let dx = Double(xx) - p.x
                    image[yy * w + xx] += Float(peak * exp(-(dx * dx + dy * dy) * inv2s2))
                }
            }
        }
        configuration.overlay?(frameNumber, &image)
        if configuration.noiseStd > 0 {
            for i in image.indices { image[i] += Float(rng.nextGaussian() * configuration.noiseStd) }
        }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = luma + y * lumaStride
            for x in 0..<w { row[x] = UInt8(max(0, min(255, image[y * w + x].rounded()))) }
        }
        if CVPixelBufferGetPlaneCount(pixels) > 1, let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) {
            let rows = CVPixelBufferGetHeightOfPlane(pixels, 1)
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * rows)
        }
    }
}

/// 🐱 Small deterministic RNG so synthetic experiments are reproducible from their seed.
public struct SplitMix64 {
    private var state: UInt64
    private var spare: Double?

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 🐱 Uniform in [0, 1).
    public mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    public mutating func nextGaussian() -> Double {
        if let s = spare { spare = nil; return s }
        var u1 = nextUnit()
        while u1 <= .leastNormalMagnitude { u1 = nextUnit() }
        let u2 = nextUnit()
        let r = sqrt(-2 * log(u1))
        spare = r * sin(2 * .pi * u2)
        return r * cos(2 * .pi * u2)
    }
}
