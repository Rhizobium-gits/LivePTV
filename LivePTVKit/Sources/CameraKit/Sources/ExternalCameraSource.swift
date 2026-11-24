import AVFoundation
import CoreMedia
import Foundation

/// 🐱 USB (UVC) camera through AVFoundation. On iPad this needs iPadOS 17+ and a USB-C iPad.
/// 🐱
/// 🐱 Fallback that keeps the same experimental camera: the Ace Pro 2 has a USB "Webcam mode". Whether iPadOS
/// 🐱 accepts it as an external camera has NOT been verified (Insta360 documents webcam mode for computers only).
public final class ExternalCameraSource: NSObject, CameraVideoSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public private(set) var info: SourceInfo
    public var onEvent: (@Sendable (SourceEvent) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    private let lock = NSLock()
    private var _onEvent: (@Sendable (SourceEvent) -> Void)?
    private var _state: ConnectionState = .disconnected
    private var _stats = SourceStatistics()
    private let mailbox = FrameMailbox(policy: .latestOnly)
    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "liveptv.uvc.output", qos: .userInteractive)
    private var device: AVCaptureDevice?
    private var index = 0
    private let preferredDeviceID: String?
    private let preferredSize: (width: Int, height: Int)?
    private var chosenFormat: AVCaptureDevice.Format?

    /// 🐱 External cameras currently attached.
    public static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    }

    /// 🐱 `preferredWidth/Height` nil = the largest format the device offers (at its highest frame rate).
    public init(deviceUniqueID: String? = nil, preferredWidth: Int? = nil, preferredHeight: Int? = nil) {
        preferredDeviceID = deviceUniqueID
        if let w = preferredWidth, let h = preferredHeight { preferredSize = (w, h) } else { preferredSize = nil }
        info = SourceInfo(kind: .usbCamera, name: "USB camera", address: deviceUniqueID ?? "first external camera", isLive: true)
        super.init()
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
        setState(.connecting("camera permission"))
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            let e = CameraError.deviceUnavailable("camera access denied (Settings > Privacy & Security > Camera)")
            setState(.failed(e))
            throw e
        }
        let devices = Self.availableDevices()
        guard let dev = devices.first(where: { $0.uniqueID == preferredDeviceID }) ?? devices.first else {
            let e = CameraError.deviceUnavailable("no external USB camera found")
            setState(.failed(e))
            throw e
        }
        session.beginConfiguration()
        // 🐱 Keep the device format chosen below instead of letting a session preset override it.
        // 🐱 (On macOS setting activeFormat already takes precedence over the preset.)
        #if os(iOS)
        if session.canSetSessionPreset(.inputPriority) { session.sessionPreset = .inputPriority }
        #endif
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(input) else { throw CameraError.deviceUnavailable("cannot use \(dev.localizedName)") }
            session.addInput(input)
            chosenFormat = Self.bestFormat(dev, preferred: preferredSize)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: outputQueue)
            guard session.canAddOutput(output) else { throw CameraError.deviceUnavailable("cannot read frames from \(dev.localizedName)") }
            session.addOutput(output)
        } catch {
            session.commitConfiguration()
            let e = (error as? CameraError) ?? .deviceUnavailable(error.localizedDescription)
            setState(.failed(e))
            throw e
        }
        session.commitConfiguration()
        device = dev
        info = SourceInfo(kind: .usbCamera, name: dev.localizedName, address: dev.uniqueID, isLive: true)
        let format = chosenFormat ?? dev.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max()
        onEvent?(.streamParameters(StreamParameters(codec: .raw, width: Int(dims.width), height: Int(dims.height),
                                                    nominalFPS: fps, origin: "USB device active format")))
        setState(.connected)
    }

    /// 🐱 Pick the requested size (or the largest), preferring 4:2:0 formats; it is applied in startPreview().
    static func bestFormat(_ dev: AVCaptureDevice, preferred: (width: Int, height: Int)?) -> AVCaptureDevice.Format? {
        func area(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        func is420(_ f: AVCaptureDevice.Format) -> Bool {
            let t = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return t == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || t == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        var candidates = dev.formats
        if let p = preferred {
            let exact = candidates.filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return Int(d.width) == p.width && Int(d.height) == p.height
            }
            if !exact.isEmpty { candidates = exact }
        }
        return candidates.max(by: { (area($0), is420($0) ? 1 : 0, maxFPS($0)) < (area($1), is420($1) ? 1 : 0, maxFPS($1)) })
    }

    public func disconnect() async {
        await stopPreview()
        setState(.disconnected)
    }

    public func startPreview() async throws {
        if !getConnectionState().isActive { try await connect() }
        mailbox.reset()
        index = 0
        lock.withLock { _stats = SourceStatistics() }
        outputQueue.sync {
            // 🐱 The device must stay locked while the session starts; otherwise macOS replaces the chosen format with
            // 🐱 the session preset (observed with the Ace Pro 2: zero frames delivered).
            if let dev = device, let format = chosenFormat, (try? dev.lockForConfiguration()) != nil {
                dev.activeFormat = format
                if let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                    dev.activeVideoMinFrameDuration = range.minFrameDuration
                }
                session.startRunning()
                dev.unlockForConfiguration()
            } else {
                session.startRunning()
            }
        }
        setState(.streaming)
    }

    public func stopPreview() async {
        outputQueue.sync { if session.isRunning { session.stopRunning() } }
        mailbox.close()
        if getConnectionState() == .streaming { setState(.connected) }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = HostClock.now()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frame = VideoFrame(index: index, pixelBuffer: pixels, presentationTime: pts.seconds, timestampQuality: .source, segment: 0,
                               timing: FrameTiming(sourceTimestampRaw: pts.value, receivedHostTime: now, decodedHostTime: now))
        index += 1
        lock.withLock {
            _stats.framesDecoded += 1
            _stats.lastFrameHostTime = now
        }
        mailbox.put(frame)
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.withLock { _stats.framesDiscardedBeforeDecode += 1 }
    }
}
