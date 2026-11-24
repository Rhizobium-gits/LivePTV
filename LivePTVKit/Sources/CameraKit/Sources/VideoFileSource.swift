import AVFoundation
import CoreMedia
import Foundation

/// 🐱 Prerecorded video (MP4/MOV, H.264/HEVC) through the same interface as the live camera.
/// 🐱 Use `.realTime` to rehearse the live pipeline, `.asFastAsPossible` for offline analysis where every frame
/// 🐱 must be analysed (no drops: the reader waits for the analysis).
public final class VideoFileSource: CameraVideoSource, @unchecked Sendable {
    public enum Pacing: String, Sendable, Codable { case realTime, asFastAsPossible }

    public let url: URL
    public let pacing: Pacing
    public let loop: Bool
    public let info: SourceInfo

    public var onEvent: (@Sendable (SourceEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    private let lock = NSLock()
    private var _onEvent: (@Sendable (SourceEvent) -> Void)?
    private var _state: ConnectionState = .disconnected
    private var _stats = SourceStatistics()
    private var track: AVAssetTrack?
    private var asset: AVURLAsset?
    private var readTask: Task<Void, Never>?
    private let mailbox: FrameMailbox

    public init(url: URL, pacing: Pacing = .realTime, loop: Bool = false) {
        self.url = url
        self.pacing = pacing
        self.loop = loop
        self.mailbox = FrameMailbox(policy: pacing == .realTime ? .latestOnly : .lossless)
        self.info = SourceInfo(kind: .videoFile, name: url.lastPathComponent, address: url.path, isLive: false)
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

    private func emit(_ e: SourceEvent) { onEvent?(e) }

    public func connect() async throws {
        if getConnectionState().isActive { return }
        setState(.connecting("opening \(url.lastPathComponent)"))
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw CameraError.fileError("\(url.lastPathComponent) has no video track")
            }
            let (size, fps, formats) = try await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
            let codec: VideoCodec
            switch formats.first.map(CMFormatDescriptionGetMediaSubType) {
            case kCMVideoCodecType_H264?: codec = .h264
            case kCMVideoCodecType_HEVC?: codec = .hevc
            default: codec = .unknown
            }
            self.asset = asset
            self.track = track
            emit(.streamParameters(StreamParameters(codec: codec, width: Int(size.width), height: Int(size.height),
                                                    nominalFPS: fps > 0 ? Double(fps) : nil, origin: "file track")))
            setState(.connected)
        } catch let e as CameraError {
            setState(.failed(e))
            throw e
        } catch {
            let e = CameraError.fileError(error.localizedDescription)
            setState(.failed(e))
            throw e
        }
    }

    public func disconnect() async {
        await stopPreview()
        setState(.disconnected)
    }

    public func startPreview() async throws {
        if !getConnectionState().isActive { try await connect() }
        guard let asset, let track else { throw CameraError.notConnected }
        readTask?.cancel()
        mailbox.reset()
        lock.withLock { _stats = SourceStatistics() }
        setState(.streaming)
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.readLoop(asset: asset, track: track)
        }
    }

    public func stopPreview() async {
        readTask?.cancel()
        readTask = nil
        mailbox.close()
        if getConnectionState() == .streaming { setState(.connected) }
    }

    private func readLoop(asset: AVAsset, track: AVAssetTrack) async {
        var index = 0
        var segment = 0
        repeat {
            let reader: AVAssetReader
            do { reader = try AVAssetReader(asset: asset) } catch {
                setState(.failed(.fileError(error.localizedDescription)))
                return
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                // 🐱 IOSurface-backed so the display layer can show the buffers without a copy
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                setState(.failed(.fileError(reader.error?.localizedDescription ?? "cannot read")))
                return
            }
            var firstPTS: Double?
            let startHost = HostClock.now()
            while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let seconds = pts.seconds
                if firstPTS == nil { firstPTS = seconds }
                if pacing == .realTime {
                    let due = startHost + (seconds - firstPTS!)
                    let wait = due - HostClock.now()
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                }
                let now = HostClock.now()
                let frame = VideoFrame(index: index, pixelBuffer: pixels, presentationTime: seconds, timestampQuality: .source,
                                       segment: segment, timing: FrameTiming(sourceTimestampRaw: pts.value, receivedHostTime: now, decodedHostTime: now))
                index += 1
                lock.withLock {
                    _stats.framesDecoded += 1
                    _stats.lastFrameHostTime = now
                }
                if pacing == .realTime { mailbox.put(frame) } else { await mailbox.putWaiting(frame) }
            }
            if reader.status == .failed {
                emit(.log(level: .error, message: "Reader failed: \(reader.error?.localizedDescription ?? "?")"))
                break
            }
            segment += 1
        } while loop && !Task.isCancelled
        if !Task.isCancelled {
            emit(.log(level: .info, message: "End of file after \(index) frames"))
            mailbox.close()
            setState(.connected)
        }
    }
}
