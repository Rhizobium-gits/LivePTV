import Accelerate
import Foundation

/// 🐱 Region of interest in full-frame pixel coordinates (x right, y down, origin top-left).
public struct PixelROI: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static func full(width: Int, height: Int) -> PixelROI { PixelROI(x: 0, y: 0, width: width, height: height) }

    /// 🐱 Intersect with the frame; never returns an empty rectangle for a non-empty frame.
    public func clamped(toWidth w: Int, height h: Int) -> PixelROI {
        let x0 = min(max(0, x), max(0, w - 1)), y0 = min(max(0, y), max(0, h - 1))
        let x1 = min(w, max(x0 + 1, x + width)), y1 = min(h, max(y0 + 1, y + height))
        return PixelROI(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= Double(x) && py >= Double(y) && px < Double(x + width) && py < Double(y + height)
    }
}

/// 🐱 8-bit luminance converted to Float, cropped to an ROI. `originX/Y` place it in the full frame.
public struct LumaImage: Sendable {
    public let width: Int
    public let height: Int
    public let originX: Int
    public let originY: Int
    /// 🐱 1 pixel here = `scale` full-frame pixels (analysis at reduced resolution); origin stays in full-frame px.
    public let scale: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, originX: Int = 0, originY: Int = 0, scale: Int = 1, pixels: [Float]) {
        precondition(pixels.count == width * height, "pixel count mismatch")
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        self.scale = max(1, scale)
        self.pixels = pixels
    }

    /// 🐱 Average f×f blocks (vDSP); the result covers the same full-frame area at 1/f resolution.
    public func downsampled(by f: Int) -> LumaImage {
        guard f > 1, width >= f, height >= f else { return self }
        let w2 = width / f, h2 = height / f
        var out = [Float](repeating: 0, count: w2 * h2)
        var rowSum = [Float](repeating: 0, count: width)
        var k = 1 / Float(f * f)
        pixels.withUnsafeBufferPointer { P in
            out.withUnsafeMutableBufferPointer { O in
                rowSum.withUnsafeMutableBufferPointer { R in
                    let p = P.baseAddress!, o = O.baseAddress!, r = R.baseAddress!
                    var y = 0
                    while y < h2 {
                        memcpy(r, p + (y * f) * width, width * MemoryLayout<Float>.size)
                        var dy = 1
                        while dy < f { vDSP_vadd(r, 1, p + (y * f + dy) * width, 1, r, 1, vDSP_Length(width)); dy += 1 }
                        let dst = o + y * w2
                        vDSP_vclr(dst, 1, vDSP_Length(w2))
                        var dx = 0
                        while dx < f { vDSP_vadd(dst, 1, r + dx, f, dst, 1, vDSP_Length(w2)); dx += 1 }
                        vDSP_vsmul(dst, 1, &k, dst, 1, vDSP_Length(w2))
                        y += 1
                    }
                }
            }
        }
        return LumaImage(width: w2, height: h2, originX: originX, originY: originY, scale: scale * f, pixels: out)
    }

    /// 🐱 Copy an ROI out of an 8-bit plane with arbitrary row stride.
    public init(plane: UnsafePointer<UInt8>, bytesPerRow: Int, roi: PixelROI) {
        width = roi.width
        height = roi.height
        originX = roi.x
        originY = roi.y
        scale = 1
        var px = [Float](repeating: 0, count: roi.width * roi.height)
        px.withUnsafeMutableBufferPointer { dst in
            var row = 0
            while row < roi.height {
                vDSP_vfltu8(plane + (roi.y + row) * bytesPerRow + roi.x, 1, dst.baseAddress! + row * roi.width, 1, vDSP_Length(roi.width))
                row += 1
            }
        }
        pixels = px
    }

    public var meanIntensity: Double {
        guard !pixels.isEmpty else { return 0 }
        var m: Float = 0
        vDSP_meanv(pixels, 1, &m, vDSP_Length(pixels.count))
        return Double(m)
    }
}
