import Foundation
@testable import CameraKit

enum Fixtures {
    static func data(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw CameraError.fileError("missing fixture \(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }

    static var h264: Data { get throws { try data("testsrc_160x120_30f", "h264") } }
    static var hevc: Data { get throws { try data("testsrc_160x120_30f", "h265") } }

    /// 🐱 Group a raw elementary stream into access units (one picture each), the way an encoder emits them.
    /// 🐱 A new picture starts at a non-VCL NAL that follows picture data, or at a VCL NAL whose
    /// 🐱 first_mb_in_slice (H.264) / first_slice_segment_in_pic_flag (HEVC) marks the first slice.
    static func accessUnits(_ stream: Data, codec: VideoCodec) -> [[Data]] {
        var units: [[Data]] = []
        var current: [Data] = []
        var currentHasPicture = false
        for nal in AnnexB.split(stream) {
            let t = AnnexB.type(of: nal, codec: codec)
            let vcl = AnnexB.isVCL(t, codec: codec)
            let firstSlice: Bool
            if codec == .hevc { firstSlice = vcl && nal.count > 2 && (nal[nal.startIndex + 2] & 0x80) != 0 }
            else { firstSlice = vcl && nal.count > 1 && (nal[nal.startIndex + 1] & 0x80) != 0 }
            if currentHasPicture && (!vcl || firstSlice) {
                units.append(current)
                current = []
                currentHasPicture = false
            }
            current.append(nal)
            if vcl { currentHasPicture = true }
        }
        if !current.isEmpty { units.append(current) }
        return units
    }
}
