import CameraKit
import CoreVideo
import Foundation
@testable import Pipeline
@testable import PTVCore
import Testing
@testable import LivePTVUI

@Suite struct LiveDisplayTests {
    private func pixelBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return pb!
    }

    @MainActor @Test func displayLayerTakesFramesFromAnyThreadAndReportsSize() async {
        let display = VideoDisplay()
        let sizes = SizeBox()
        display.onSizeChange = { sizes.append($0) }
        let a = pixelBuffer(640, 360), b = pixelBuffer(320, 240)
        await Task.detached {
            for _ in 0..<5 { display.show(a) }
            display.show(b)
        }.value
        #expect(display.framesShown == 6)
        #expect(sizes.values == [CGSize(width: 640, height: 360), CGSize(width: 320, height: 240)])
        #expect(display.currentSize == CGSize(width: 320, height: 240))
        display.clear()
        #expect(display.currentSize == nil)
    }

    @Test func overlayBuilderPreparesArrowsAndOneHeatmapImage() {
        let cols = 60, rows = 30, cs = 16.0
        var cells: [FieldCell] = []
        for j in 0..<rows {
            for i in 0..<cols {
                // 🐱 solid-body rotation around the centre, px/s
                let x = (Double(i) + 0.5) * cs, y = (Double(j) + 0.5) * cs
                let u = -(y - 240) * 0.1, v = (x - 480) * 0.1
                cells.append(FieldCell(i: i, j: j, x: x, y: y, u: u, v: v, stdU: 0, stdV: 0, count: 5, valid: !(i == 3 && j == 3), outlier: i == 3 && j == 3))
            }
        }
        let snap = FieldSnapshot(time: 1, cellSize: cs, columns: cols, rows: rows, originX: 0, originY: 0, cells: cells)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 960, 480, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
        let frame = VideoFrame(index: 0, pixelBuffer: pb!, presentationTime: 1, timestampQuality: .source, segment: 0,
                               timing: FrameTiming(sourceTimestampRaw: nil, receivedHostTime: 0, decodedHostTime: 0))
        let result = FrameResult(frame: frame, roi: PixelROI(x: 0, y: 0, width: 960, height: 480), particles: [], trackIDs: [], samples: [],
                                 tails: [], field: snap, metrics: PipelineMetrics(), velocityEnabled: true, shake: nil)
        let builder = OverlayBuilder()
        let o = builder.build(result)
        // 🐱 60 columns → every 2nd cell, ~30 × 15 arrows; the outlier cell is a red dot, not an arrow
        #expect(o.arrows.count > 300 && o.arrows.count <= 30 * 15)
        #expect(o.arrows.allSatisfy { $0.bin >= 0 && $0.bin < OverlayData.colorBins })
        #expect(o.heatmapImage?.width == cols && o.heatmapImage?.height == rows)
        #expect(o.heatmapRect == CGRect(x: 0, y: 0, width: 960, height: 480))
        // 🐱 fastest arrows (corners) get the top colour bins, the centre the lowest
        func r(_ a: OverlayData.Arrow) -> Double { hypot(a.x - 480, a.y - 240) }
        let centre = o.arrows.min { r($0) < r($1) }!
        #expect(centre.bin <= 1)
        let topBin = o.arrows.map { $0.bin }.max() ?? 0
        #expect(topBin >= OverlayData.colorBins - 2)
    }
}

final class SizeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [CGSize] = []
    func append(_ s: CGSize) { lock.withLock { _values.append(s) } }
    var values: [CGSize] { lock.withLock { _values } }
}
