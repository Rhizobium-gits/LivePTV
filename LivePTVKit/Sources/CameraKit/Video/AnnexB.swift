import Foundation

/// 🐱 Helpers for H.264 / H.265 Annex B byte streams (NAL units separated by 00 00 01 / 00 00 00 01).
public enum AnnexB {
    /// 🐱 Split a byte stream into NAL units (start codes and trailing zero bytes removed).
    public static func split(_ data: Data) -> [Data] {
        var nals: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var starts: [Int] = []     // 🐱 index of first byte after each start code
            var codeAt: [Int] = []     // 🐱 index of the first 00 of each start code
            var i = 0
            while i + 2 < n {
                if p[i] == 0, p[i + 1] == 0, p[i + 2] == 1 {
                    codeAt.append(i)
                    starts.append(i + 3)
                    i += 3
                } else {
                    i += 1
                }
            }
            for k in 0..<starts.count {
                let begin = starts[k]
                var end = (k + 1 < starts.count) ? codeAt[k + 1] : n
                // 🐱 Zero bytes before the next start code are trailing_zero_8bits, not NAL data.
                while end > begin, p[end - 1] == 0 { end -= 1 }
                if end > begin {
                    nals.append(Data(bytes: p + begin, count: end - begin))
                }
            }
        }
        return nals
    }

    @inline(__always) public static func h264Type(_ header: UInt8) -> Int { Int(header & 0x1F) }
    @inline(__always) public static func hevcType(_ header: UInt8) -> Int { Int((header >> 1) & 0x3F) }

    /// 🐱 Identify the codec from the first parameter set found. Returns nil if none present yet.
    /// 🐱 The two tests cannot both match: an HEVC VPS/SPS header byte (0x40/0x42) is H.264 type 0/2, and an
    /// 🐱 H.264 SPS header (0x67/0x27...) is HEVC type 51/19.
    public static func detectCodec(nals: [Data]) -> VideoCodec? {
        for nal in nals where nal.count >= 2 {
            let b0 = nal[nal.startIndex], b1 = nal[nal.startIndex + 1]
            let ht = hevcType(b0)
            if (ht == 32 || ht == 33), (b0 & 0x80) == 0, b1 == 0x01 { return .hevc }
            if h264Type(b0) == 7, (b0 & 0x80) == 0 { return .h264 }
        }
        return nil
    }

    public static func detectCodec(_ data: Data) -> VideoCodec? { detectCodec(nals: split(data)) }

    public static func type(of nal: Data, codec: VideoCodec) -> Int {
        guard let b0 = nal.first else { return -1 }
        return codec == .hevc ? hevcType(b0) : h264Type(b0)
    }

    /// 🐱 Coded slice data (what the decoder needs per picture).
    public static func isVCL(_ type: Int, codec: VideoCodec) -> Bool {
        codec == .hevc ? (0...31).contains(type) : (1...5).contains(type)
    }

    /// 🐱 Random access point: H.264 IDR, HEVC BLA/IDR/CRA (IRAP range 16...23).
    public static func isKeyFrame(_ type: Int, codec: VideoCodec) -> Bool {
        codec == .hevc ? (16...23).contains(type) : type == 5
    }

    public static func isParameterSet(_ type: Int, codec: VideoCodec) -> Bool {
        codec == .hevc ? (32...34).contains(type) : (type == 7 || type == 8)
    }

    public static func containsKeyFrame(_ nals: [Data], codec: VideoCodec) -> Bool {
        nals.contains { isKeyFrame(type(of: $0, codec: codec), codec: codec) }
    }

    /// 🐱 Length-prefixed (AVCC/HVCC, 4-byte big-endian) sample data, as CoreMedia expects.
    public static func lengthPrefixed(_ nals: [Data]) -> Data {
        var out = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }

    /// 🐱 Re-serialise NAL units with 4-byte start codes.
    public static func join(_ nals: [Data]) -> Data {
        var out = Data()
        for nal in nals {
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(nal)
        }
        return out
    }
}
