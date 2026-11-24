import CameraKit
import CoreGraphics
import Foundation
import Pipeline
import PTVCore
import SwiftUI

/// 🐱 Everything the live overlay draws, prepared on the analysis thread in full-frame image coordinates, so the
/// 🐱 main thread only strokes a handful of paths and draws one small heatmap image per update.
public struct OverlayData: @unchecked Sendable {
    public struct Arrow: Sendable {
        public var x: Double
        public var y: Double
        /// 🐱 arrow vector in image px (already scaled for display)
        public var ex: Double
        public var ey: Double
        /// 🐱 colour bin 0..<OverlayData.colorBins (slow → fast)
        public var bin: Int
    }

    public static let colorBins = 12

    public var imageSize: CGSize
    public var roi: PixelROI
    public var particles: [CGPoint] = []
    public var tails: [[CGPoint]] = []
    public var arrows: [Arrow] = []
    public var outliers: [CGPoint] = []
    /// 🐱 Reference speed (px/s, ≈ 95th percentile) and the arrow time scale (s) used for `arrows`.
    public var referenceSpeed = 1.0
    public var arrowSeconds = 0.4
    public var heatmapImage: CGImage?
    public var heatmapRect: CGRect = .zero
    public var heatmap: HeatmapLayer?
    public var velocityEnabled = true
    public var status = ""
    public var shakeReference: PixelROI?
    /// 🐱 Masks (full-frame rectangle of the image), container outline and the usable fluid across it, exclusions.
    public var maskImage: CGImage?
    public var maskRect: CGRect = .zero
    public var containerOutline: PixelROI?
    public var containerVertical = true
    public var usableLateral: (Double, Double)?
    public var containerLabel = ""
    public var exclusions: [PixelROI] = []

    /// 🐱 Blue (slow) → red (fast).
    public static func binColor(_ b: Int) -> Color {
        let x = Double(b) / Double(colorBins - 1)
        return Color(hue: 0.66 * (1 - x), saturation: 0.9, brightness: 1)
    }
}

/// 🐱 High-rate state for the video overlay only. Kept out of `AppModel` so a new analysis result re-renders the
/// 🐱 overlay and nothing else (the settings panel is not touched).
@MainActor
public final class LiveOverlayModel: ObservableObject {
    @Published public private(set) var overlay: OverlayData?
    /// 🐱 Pixel size of the displayed camera frames (nil until the first frame).
    @Published public private(set) var videoSize: CGSize?

    public init() {}

    func set(_ o: OverlayData?) { overlay = o }

    func setVideoSize(_ s: CGSize?) {
        if videoSize != s { videoSize = s }
    }
}

/// 🐱 Numbers for the metrics bar, at most a few updates per second.
@MainActor
public final class MetricsModel: ObservableObject {
    @Published public private(set) var metrics = PipelineMetrics()
    @Published public private(set) var status = ""

    public init() {}

    func set(_ m: PipelineMetrics, status s: String) {
        if metrics != m { metrics = m }
        if status != s { status = s }
    }
}

/// 🐱 Hand values to the main thread without ever queueing more than one update: if the main thread is busy, only
/// 🐱 the newest value is applied when it gets to it.
final class LatestOnMain<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: T?
    private var scheduled = false
    private let apply: @MainActor (T) -> Void

    init(_ apply: @escaping @MainActor (T) -> Void) { self.apply = apply }

    func post(_ value: T) {
        let schedule: Bool = lock.withLock {
            pending = value
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            let v: T? = lock.withLock {
                scheduled = false
                defer { pending = nil }
                return pending
            }
            if let v { MainActor.assumeIsolated { apply(v) } }
        }
    }
}

/// 🐱 What the analysis thread needs to know about the display (copied from the main actor on change).
struct OverlayConfig: Sendable {
    var display = DisplayOptions()
    var mmPerPixel: Double?
    var method: AnalysisMethod = .piv
    var shakeEnabled = true
    var shakeReference: PixelROI?
    var exclusions: [PixelROI] = []
}

/// 🐱 Builds `OverlayData` from analysis results on the analysis thread.
final class OverlayBuilder: @unchecked Sendable {
    private let lock = NSLock()
    private var _config = OverlayConfig()
    private var range: (quantity: HeatmapQuantity, lo: Double, hi: Double)?
    private var refSpeed: Double?

    var config: OverlayConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    func reset() {
        lock.withLock {
            range = nil
            refSpeed = nil
        }
    }

    func build(_ r: FrameResult) -> OverlayData {
        let cfg = config
        let opts = cfg.display
        var o = OverlayData(imageSize: CGSize(width: r.frame.width, height: r.frame.height), roi: r.roi)
        o.velocityEnabled = r.velocityEnabled
        o.shakeReference = cfg.method == .piv ? cfg.shakeReference : nil
        o.status = Self.statusText(r.metrics, cfg)
        o.exclusions = cfg.exclusions
        if let m = r.mask {
            o.maskImage = m.image
            o.maskRect = m.rect
        }
        if let c = r.container, let outline = c.geometry.outline {
            o.containerOutline = outline
            o.containerVertical = c.geometry.axis == .vertical
            o.usableLateral = c.usableLateralRange
            o.containerLabel = c.isIdentity ? "container (wall band masked)"
                : String(format: "bottle ⌀%.0f mm · %.4f mm/px · centre ×%.3f", c.geometry.outerDiameterMM, c.mmPerPixel ?? 0, c.centreMagnification ?? .nan)
        }
        if opts.particles {
            o.particles = r.particles.map { CGPoint(x: $0.x, y: $0.y) }
        }
        if opts.tails {
            o.tails = r.tails.map { $0.map { CGPoint(x: $0.x, y: $0.y) } }
        }
        guard let f = r.field else { return o }

        // 🐱 heatmap: one pixel per cell, colour range smoothed over time so colours do not flicker
        if opts.heatmap != .off, var h = HeatmapLayer.from(snapshot: f, quantity: opts.heatmap, mmPerPixel: cfg.mmPerPixel) {
            lock.withLock {
                if let rg = range, rg.quantity == h.quantity {
                    h.lo = rg.lo + 0.15 * (h.lo - rg.lo)
                    h.hi = rg.hi + 0.15 * (h.hi - rg.hi)
                }
                range = (h.quantity, h.lo, h.hi)
            }
            o.heatmap = h
            o.heatmapImage = h.cellImage()
            o.heatmapRect = CGRect(x: h.grid.originX, y: h.grid.originY,
                                   width: Double(h.grid.columns) * h.grid.cellSize, height: Double(h.grid.rows) * h.grid.cellSize)
        }

        guard opts.vectors else { return o }
        // 🐱 reference speed: 95th percentile of valid cells, smoothed so arrow lengths do not pump
        var speeds: [Double] = []
        speeds.reserveCapacity(f.cells.count)
        for c in f.cells where c.valid { speeds.append(hypot(c.u, c.v)) }
        let sorted = GridKernels.sorted(speeds)
        let p95 = sorted.isEmpty ? 1 : max(1e-9, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        let ref: Double = lock.withLock {
            let v = refSpeed.map { $0 + 0.15 * (p95 - $0) } ?? p95
            refSpeed = v
            return v
        }
        o.referenceSpeed = ref
        // 🐱 thin dense grids to about 40 arrows across so they stay readable
        let stride = max(1, Int(ceil(Double(f.columns) / 40)))
        let seconds = opts.autoArrowScale ? 0.9 * Double(stride) * f.cellSize / ref : opts.vectorSeconds
        o.arrowSeconds = seconds
        let bins = Double(OverlayData.colorBins - 1)
        var arrows: [OverlayData.Arrow] = []
        arrows.reserveCapacity(f.cells.count / (stride * stride) + 1)
        var outliers: [CGPoint] = []
        let half = stride / 2
        for c in f.cells where c.count > 0 && c.i % stride == half && c.j % stride == half {
            if c.outlier {
                outliers.append(CGPoint(x: c.x, y: c.y))
                continue
            }
            guard c.valid else { continue }
            let t = min(1, hypot(c.u, c.v) / ref)
            arrows.append(OverlayData.Arrow(x: c.x, y: c.y, ex: c.u * seconds, ey: c.v * seconds, bin: Int((t * bins).rounded())))
        }
        o.arrows = arrows
        o.outliers = outliers
        return o
    }

    /// 🐱 One line describing what the live analysis is doing right now.
    static func statusText(_ m: PipelineMetrics, _ cfg: OverlayConfig) -> String {
        var parts: [String] = []
        if cfg.method == .piv {
            let dt = m.sourceFPS.map { Double(m.pivPairSpacing) / $0 }
            parts.append("PIV \(String(format: "%.1f", m.processingFPS ?? 0)) fps")
            parts.append("pairs \(m.pivPairSpacing) frame\(m.pivPairSpacing == 1 ? "" : "s")" + (dt.map { String(format: " (%.2f s)", $0) } ?? ""))
            if m.pivScale > 1 { parts.append("1/\(m.pivScale) res") }
            if let v = m.pivValidPercent { parts.append(String(format: "%.0f %% valid", v)) }
            if let n = m.pivEnsemblePairs {
                parts.append("ensemble \(n) pairs" + (m.pivEnsembleValidPercent.map { String(format: ", %.0f %% valid", $0) } ?? "")
                             + ((m.pivEnsembleRecordedPairs ?? 0) > 0 ? ", \(m.pivEnsembleRecordedPairs!) in recording" : ""))
            }
            if cfg.shakeEnabled {
                parts.append(m.shakePx.map { String(format: "shake −%.2f px (%@)", $0, m.shakeStatus) } ?? "shake: \(m.shakeStatus)")
            }
            if let u = m.pivUncertaintyPx { parts.append(String(format: "σ %.3f px", u)) }
        } else {
            parts.append("PTV \(String(format: "%.1f", m.processingFPS ?? 0)) fps, \(m.particles) particles")
        }
        if let mp = m.maskedPercent, mp >= 0.05 { parts.append(String(format: "masked %.0f %%", mp)) }
        if let c = m.containerStatus { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}
