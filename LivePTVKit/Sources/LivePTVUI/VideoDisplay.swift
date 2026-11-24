import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 🐱 Camera frames → screen through AVSampleBufferDisplayLayer.
/// 🐱
/// 🐱 Frames are enqueued straight from the camera / decoder thread and composited by the system, never through
/// 🐱 SwiftUI or the main thread, so the preview runs at the camera's frame rate however busy the UI or the analysis
/// 🐱 is (the previous SwiftUI `Image` path re-rendered the whole window for every frame).
public final class VideoDisplay: @unchecked Sendable {
    public let layer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var size: CGSize?
    private var _onSizeChange: (@Sendable (CGSize) -> Void)?
    private var _framesShown = 0
    private var _failures = 0

    /// 🐱 Called (on any thread) when the frame size changes, e.g. on the first frame.
    public var onSizeChange: (@Sendable (CGSize) -> Void)? {
        get { lock.withLock { _onSizeChange } }
        set { lock.withLock { _onSizeChange = newValue } }
    }

    public var framesShown: Int { lock.withLock { _framesShown } }
    public var currentSize: CGSize? { lock.withLock { size } }

    @MainActor
    public init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        renderer = layer.sampleBufferRenderer
    }

    /// 🐱 Show this frame as soon as possible (no presentation-time scheduling: always the newest frame).
    public func show(_ pixelBuffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var fd: CMVideoFormatDescription? = lock.withLock { format }
        if fd == nil || !CMVideoFormatDescriptionMatchesImageBuffer(fd!, imageBuffer: pixelBuffer) {
            fd = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fd)
            lock.withLock { format = fd }
        }
        guard let fd else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: fd,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        // 🐱 a failed renderer (e.g. after the app was in the background) must be flushed before it shows frames again
        if renderer.status == .failed {
            renderer.flush()
            lock.withLock { _failures += 1 }
        }
        renderer.enqueue(sample)

        let newSize = CGSize(width: w, height: h)
        let notify: (@Sendable (CGSize) -> Void)? = lock.withLock {
            _framesShown += 1
            guard size != newSize else { return nil }
            size = newSize
            return _onSizeChange
        }
        notify?(newSize)
    }

    /// 🐱 Remove the last picture (source changed / stopped).
    public func clear() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        lock.withLock {
            size = nil
            format = nil
        }
    }
}

#if os(iOS)
/// 🐱 Hosts the model's display layer; it survives SwiftUI re-creating this view.
final class VideoHostView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            guard oldValue !== displayLayer else { return }
            oldValue?.removeFromSuperlayer()
            if let l = displayLayer {
                l.removeFromSuperlayer()
                layer.addSublayer(l)
                setNeedsLayout()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct VideoLayerView: UIViewRepresentable {
    let display: VideoDisplay

    func makeUIView(context: Context) -> VideoHostView {
        let v = VideoHostView(frame: .zero)
        v.displayLayer = display.layer
        return v
    }

    func updateUIView(_ v: VideoHostView, context: Context) {
        if v.displayLayer !== display.layer { v.displayLayer = display.layer }
    }
}
#else
final class VideoHostView: NSView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            guard oldValue !== displayLayer else { return }
            oldValue?.removeFromSuperlayer()
            if let l = displayLayer {
                l.removeFromSuperlayer()
                layer?.addSublayer(l)
                needsLayout = true
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct VideoLayerView: NSViewRepresentable {
    let display: VideoDisplay

    func makeNSView(context: Context) -> VideoHostView {
        let v = VideoHostView(frame: .zero)
        v.displayLayer = display.layer
        return v
    }

    func updateNSView(_ v: VideoHostView, context: Context) {
        if v.displayLayer !== display.layer { v.displayLayer = display.layer }
    }
}
#endif
