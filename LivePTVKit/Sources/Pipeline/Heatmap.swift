import CoreGraphics
import Foundation
import PTVCore

/// 🐱 Perceptual colour maps: viridis for magnitudes, cool-warm (Moreland) for signed quantities.
public enum Colormap: String, Codable, Sendable {
    case viridis, coolwarm

    private static let viridisStops: [(Double, Double, Double)] = [
        (0.267, 0.005, 0.329), (0.283, 0.141, 0.458), (0.254, 0.265, 0.530), (0.207, 0.372, 0.553),
        (0.164, 0.471, 0.558), (0.128, 0.567, 0.551), (0.135, 0.659, 0.518), (0.267, 0.749, 0.441),
        (0.478, 0.821, 0.318), (0.741, 0.873, 0.150), (0.993, 0.906, 0.144),
    ]
    private static let coolwarmStops: [(Double, Double, Double)] = [
        (0.230, 0.299, 0.754), (0.552, 0.690, 0.996), (0.865, 0.865, 0.865), (0.958, 0.604, 0.482), (0.706, 0.016, 0.150),
    ]

    /// 🐱 t in 0...1 → RGB 0...1
    public func rgb(_ t: Double) -> (r: Double, g: Double, b: Double) {
        let stops = self == .viridis ? Self.viridisStops : Self.coolwarmStops
        let x = max(0, min(1, t.isFinite ? t : 0)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x))
        let f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }
}

/// 🐱 What a heatmap shows.
public enum HeatmapQuantity: String, CaseIterable, Codable, Sendable, Identifiable {
    case off, speed, u, v, vorticity, divergence, samples
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .speed: return "Speed |v|"
        case .u: return "u (x velocity)"
        case .v: return "v (y velocity, down +)"
        case .vorticity: return "Vorticity ω (ccw +)"
        case .divergence: return "Divergence"
        case .samples: return "Samples per cell"
        }
    }

    public var colormap: Colormap { (self == .u || self == .v || self == .vorticity || self == .divergence) ? .coolwarm : .viridis }
    public var isVelocity: Bool { self == .speed || self == .u || self == .v }
}

/// 🐱 Velocity unit for display: px/s without calibration; µm/s for slow (micro/nano) flows; mm/s otherwise.
public struct SpeedUnit: Equatable, Sendable {
    public let label: String
    /// 🐱 Multiply px/s by this.
    public let factor: Double

    public static func choose(mmPerPixel: Double?, typicalPxPerSecond: Double) -> SpeedUnit {
        guard let mm = mmPerPixel else { return SpeedUnit(label: "px/s", factor: 1) }
        return typicalPxPerSecond * mm < 0.1 ? SpeedUnit(label: "µm/s", factor: mm * 1000) : SpeedUnit(label: "mm/s", factor: mm)
    }
}

/// 🐱 One heatmap ready to draw: values per grid cell (nil = no data) with a colour range.
public struct HeatmapLayer: Sendable {
    public var quantity: HeatmapQuantity
    public var grid: GridGeometry
    public var values: [Double?]
    public var lo: Double
    public var hi: Double
    public var unit: String

    /// 🐱 Colour for a value, nil when the cell has no data.
    public func rgb(at k: Int) -> (r: Double, g: Double, b: Double)? {
        guard let v = values[k], hi > lo else { return nil }
        return quantity.colormap.rgb((v - lo) / (hi - lo))
    }

    /// 🐱 Automatic range, symmetric around 0 for signed quantities. `robust` (live view) uses the 2nd–98th
    /// 🐱 percentile so single noisy cells do not wash out the colours; session reports use the full range.
    public static func autoRange(_ values: [Double?], quantity: HeatmapQuantity, robust: Bool = true) -> (lo: Double, hi: Double) {
        var raw: [Double] = []
        raw.reserveCapacity(values.count)
        var k = 0
        while k < values.count {
            if let x = values[k], x.isFinite { raw.append(x) }
            k += 1
        }
        let v = GridKernels.sorted(raw)
        guard !v.isEmpty else { return (0, 1) }
        func pct(_ p: Double) -> Double { v[min(v.count - 1, max(0, Int((p * Double(v.count - 1)).rounded())))] }
        let (a, b) = robust ? (pct(0.02), pct(0.98)) : (v.first!, v.last!)
        if quantity.colormap == .coolwarm {
            let m = max(abs(a), abs(b), 1e-12)
            return (-m, m)
        }
        return (0, max(b, 1e-12))
    }

    /// 🐱 Live layer from the sliding-window field snapshot.
    public static func from(snapshot f: FieldSnapshot, quantity: HeatmapQuantity, mmPerPixel: Double?) -> HeatmapLayer? {
        guard quantity != .off else { return nil }
        let grid = GridGeometry(originX: f.originX, originY: f.originY, cellSize: f.cellSize, columns: f.columns, rows: f.rows)
        var speeds: [Double] = []
        speeds.reserveCapacity(f.cells.count)
        for c in f.cells where c.valid { speeds.append(hypot(c.u, c.v)) }
        let typical = GridKernels.median(of: speeds) ?? 0
        let unit = SpeedUnit.choose(mmPerPixel: mmPerPixel, typicalPxPerSecond: typical)
        var values: [Double?]
        var label = unit.label
        switch quantity {
        case .off: return nil
        case .speed: values = f.cells.map { $0.valid ? hypot($0.u, $0.v) * unit.factor : nil }
        case .u: values = f.cells.map { $0.valid ? $0.u * unit.factor : nil }
        case .v: values = f.cells.map { $0.valid ? $0.v * unit.factor : nil }
        case .vorticity: values = f.derivatives().vorticity; label = "1/s"
        case .divergence: values = f.derivatives().divergence; label = "1/s"
        case .samples: values = f.cells.map { $0.count > 0 ? Double($0.count) : nil }; label = "samples"
        }
        let r = autoRange(values, quantity: quantity)
        return HeatmapLayer(quantity: quantity, grid: grid, values: values, lo: r.lo, hi: r.hi, unit: label)
    }

    /// 🐱 Layer from whole-session cell statistics (used by the report).
    public static func from(session cells: [CellStatistics], grid: GridGeometry, quantity: HeatmapQuantity, unit: SpeedUnit) -> HeatmapLayer? {
        var label = unit.label
        let values: [Double?]
        switch quantity {
        case .off: return nil
        case .speed: values = cells.map { $0.valid ? $0.speedOfMean * unit.factor : nil }
        case .u: values = cells.map { $0.valid ? $0.meanU * unit.factor : nil }
        case .v: values = cells.map { $0.valid ? $0.meanV * unit.factor : nil }
        case .vorticity: values = cells.map(\.vorticity); label = "1/s"
        case .divergence: values = cells.map(\.divergence); label = "1/s"
        case .samples: values = cells.map { $0.count > 0 ? Double($0.count) : nil }; label = "samples"
        }
        let r = autoRange(values, quantity: quantity, robust: false)
        return HeatmapLayer(quantity: quantity, grid: grid, values: values, lo: r.lo, hi: r.hi, unit: label)
    }
}

/// 🐱 256-step RGB lookup tables (built once; per-cell colour lookups stay cheap in unoptimised builds).
enum ColormapLUT {
    static let viridis = build(.viridis)
    static let coolwarm = build(.coolwarm)

    static func table(_ c: Colormap) -> [UInt8] { c == .viridis ? viridis : coolwarm }

    private static func build(_ c: Colormap) -> [UInt8] {
        var t = [UInt8](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            let rgb = c.rgb(Double(i) / 255)
            t[3 * i] = UInt8((rgb.r * 255).rounded())
            t[3 * i + 1] = UInt8((rgb.g * 255).rounded())
            t[3 * i + 2] = UInt8((rgb.b * 255).rounded())
        }
        return t
    }
}

extension HeatmapLayer {
    /// 🐱 One pixel per grid cell (transparent where there is no data), meant to be drawn over the grid's rectangle
    /// 🐱 with smoothing, which gives a contour-like map in a single draw call.
    public func cellImage() -> CGImage? {
        let cols = grid.columns, rows = grid.rows, n = cols * rows
        guard n > 0, values.count >= n, hi > lo else { return nil }
        let lut = ColormapLUT.table(quantity.colormap)
        var rgba = [UInt8](repeating: 0, count: n * 4)
        let scale = 255 / (hi - lo)
        lut.withUnsafeBufferPointer { lb in
            rgba.withUnsafeMutableBufferPointer { ob in
                let L = lb.baseAddress!, O = ob.baseAddress!
                var k = 0
                while k < n {
                    if let v = values[k], v.isFinite {
                        var t = (v - lo) * scale
                        t = t < 0 ? 0 : (t > 255 ? 255 : t)
                        let i = Int(t) * 3
                        O[4 * k] = L[i]
                        O[4 * k + 1] = L[i + 1]
                        O[4 * k + 2] = L[i + 2]
                        O[4 * k + 3] = 255
                    }
                    k += 1
                }
            }
        }
        // 🐱 premultiplied alpha: transparent pixels are already (0, 0, 0, 0)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 🐱 Colour-bar stops (bottom = lo → top = hi) as RGB 0...1.
    public var barColors: [(r: Double, g: Double, b: Double)] {
        (0...10).map { quantity.colormap.rgb(Double($0) / 10) }
    }
}
