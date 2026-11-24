import CoreGraphics
import Foundation
import PTVCore

/// 🐱 Picture of what is excluded from the analysis, for the live overlay and the quality figure:
/// 🐱 dark blue = outside the fluid / wall band / user exclusions, orange = static glare, red = moving glints.
public struct MaskOverlay: @unchecked Sendable {
    public let image: CGImage
    /// 🐱 Full-frame rectangle the image covers (px).
    public let rect: CGRect
    public let statistics: MaskStatistics

    public static let staticColor: (UInt8, UInt8, UInt8, UInt8) = (30, 50, 90, 120)
    public static let glareColor: (UInt8, UInt8, UInt8, UInt8) = (255, 150, 0, 150)
    public static let glintColor: (UInt8, UInt8, UInt8, UInt8) = (235, 30, 40, 170)

    /// 🐱 Every `step`-th analysed pixel (the overlay is drawn smoothed). Nil when nothing is masked.
    public static func make(staticMask: [Float]?, glare: [Float]?, saturation: [Float]?, width w: Int, height h: Int,
                            originX: Int, originY: Int, scale: Int, statistics: MaskStatistics, step: Int = 2) -> MaskOverlay? {
        guard w > 0, h > 0, staticMask != nil || glare != nil || saturation != nil else { return nil }
        let st = max(1, step)
        let W = (w + st - 1) / st, H = (h + st - 1) / st
        var px = [UInt8](repeating: 0, count: W * H * 4)
        var any = false
        px.withUnsafeMutableBufferPointer { P in
            let p = P.baseAddress!
            var j = 0
            while j < H {
                var i = 0
                while i < W {
                    let k = (j * st) * w + i * st
                    var c: (UInt8, UInt8, UInt8, UInt8)?
                    if let m = staticMask, m[k] < 0.5 { c = staticColor }
                    if let m = glare, m[k] < 0.5 { c = glareColor }
                    if let m = saturation, m[k] < 0.5 { c = glintColor }
                    if let c {
                        // 🐱 premultiplied alpha
                        let o = (j * W + i) * 4
                        let a = UInt16(c.3)
                        p[o] = UInt8(UInt16(c.0) * a / 255); p[o + 1] = UInt8(UInt16(c.1) * a / 255)
                        p[o + 2] = UInt8(UInt16(c.2) * a / 255); p[o + 3] = c.3
                        any = true
                    }
                    i += 1
                }
                j += 1
            }
        }
        guard any, let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let s = Double(max(1, scale))
        let rect = CGRect(x: Double(originX) - 0.5, y: Double(originY) - 0.5, width: Double(W * st) * s, height: Double(H * st) * s)
        return MaskOverlay(image: img, rect: rect, statistics: statistics)
    }

    /// 🐱 From the masks of a suppressor's last frame.
    public static func make(from r: ReflectionSuppressor, step: Int = 2) -> MaskOverlay? {
        let g = r.geometry
        return make(staticMask: r.lastStaticMask, glare: r.lastGlareMask, saturation: r.lastSaturationMask, width: g.width, height: g.height,
                    originX: g.originX, originY: g.originY, scale: g.scale, statistics: r.lastStatistics, step: step)
    }
}
