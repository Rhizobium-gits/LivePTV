import Foundation
import Metal

// 🐱 GPU (Metal) version of CorrelationWork for 32 × 32 windows: window fill (integer copy, bilinear or Lanczos-4),
// 🐱 mean / σ, optional Wieneke (2015) uncertainty, normalised cyclic cross-correlation plane by 2-D FFT, and the
// 🐱 first-index maximum with its four cyclic neighbours. The sub-pixel fit stays on the CPU (double precision).
// 🐱 The shader is compiled from source at run time (no .metallib), so it also works in Swift Playgrounds.

/// 🐱 One window pair (same layout as the shader: 48 bytes).
struct GPUWindow {
    var ax: Int32, ay: Int32, bx: Int32, by: Int32      // 🐱 top-left of window A / B: floor(x0), floor(y0)
    var fax: Float, fay: Float, fbx: Float, fby: Float  // 🐱 fractions: Float(x0 − floor(x0))
    var tapsA: Int32, tapsB: Int32                      // 🐱 1 = integer copy, 2 = bilinear, 8 = Lanczos-4
    var pad0: Int32 = 0, pad1: Int32 = 0
}

/// 🐱 Result per window (32 bytes).
struct GPUWindowResult {
    var index: Int32        // 🐱 first index (r·32 + c) of the maximum of the normalised plane; −1 = a window's σ < minContrast
    var peak: Float, xm: Float, xp: Float, ym: Float, yp: Float   // 🐱 peak and its cyclic neighbours (pr,pc∓1), (pr∓1,pc)
    var sigmaX: Float, sigmaY: Float                              // 🐱 uncertainty (px); −1 when not requested or nil
}

final class MetalCorrelator: @unchecked Sendable {
    static let windowSize = 32
    /// 🐱 nil without a capable GPU (Apple7+ / Mac2, 32-wide SIMD groups), if the shader fails to build, or if the self-test fails.
    static let shared: MetalCorrelator? = MetalCorrelator()

    let deviceName: String
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let plain: MTLComputePipelineState
    private let withSigma: MTLComputePipelineState
    private let lock = NSLock()
    private var bufA: MTLBuffer?
    private var bufB: MTLBuffer?
    private var bufW: MTLBuffer?
    private var bufR: MTLBuffer?
    private var gpuMs: Double = 0

    private static let threadsPerGroup = 128

    /// 🐱 Matches `struct Params` in the shader.
    private struct Params { var width: Int32; var height: Int32; var count: Int32; var minContrast: Float }

    private init?() {
        guard MemoryLayout<GPUWindow>.stride == 48, MemoryLayout<GPUWindowResult>.stride == 32,
              let device = MTLCreateSystemDefaultDevice(),
              device.supportsFamily(.apple7) || device.supportsFamily(.mac2),   // 🐱 SIMD-group reductions
              let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        #if compiler(>=6.0)
        if #available(iOS 18.0, macOS 15.0, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
        #else
        options.fastMathEnabled = false
        #endif
        guard let library = try? device.makeLibrary(source: Self.source, options: options),
              let plain = Self.pipeline(device, library, sigma: false),
              let withSigma = Self.pipeline(device, library, sigma: true) else { return nil }
        self.device = device
        self.queue = queue
        self.plain = plain
        self.withSigma = withSigma
        deviceName = device.name
        guard selfTest() else { return nil }
    }

    private static func pipeline(_ device: MTLDevice, _ library: MTLLibrary, sigma: Bool) -> MTLComputePipelineState? {
        let constants = MTLFunctionConstantValues()
        var flag = sigma
        constants.setConstantValue(&flag, type: .bool, index: 0)
        guard let function = try? library.makeFunction(name: "correlate32", constantValues: constants),
              let pso = try? device.makeComputePipelineState(function: function),
              pso.threadExecutionWidth == 32, pso.maxTotalThreadsPerThreadgroup >= threadsPerGroup else { return nil }
        return pso
    }

    /// 🐱 GPU execution time of the last `correlate` call (ms).
    var lastGPUMilliseconds: Double { lock.lock(); defer { lock.unlock() }; return gpuMs }

    /// 🐱 Correlates every window pair; waits for the GPU. Serialised by a lock (thread-safe). nil on a GPU error.
    func correlate(a: UnsafeBufferPointer<Float>, b: UnsafeBufferPointer<Float>, width: Int, height: Int,
                   windows: UnsafeBufferPointer<GPUWindow>, minContrast: Float, uncertainty: Bool) -> [GPUWindowResult]? {
        let count = windows.count, pixels = width * height
        guard width > 0, height > 0, a.count >= pixels, b.count >= pixels, count <= Int(Int32.max),
              let pa = a.baseAddress, let pb = b.baseAddress else { return nil }
        guard count > 0, let pw = windows.baseAddress else { return [] }
        lock.lock(); defer { lock.unlock() }
        let imageBytes = pixels * MemoryLayout<Float>.stride
        guard let bA = Self.buffer(device, &bufA, imageBytes), let bB = Self.buffer(device, &bufB, imageBytes),
              let bW = Self.buffer(device, &bufW, count * MemoryLayout<GPUWindow>.stride),
              let bR = Self.buffer(device, &bufR, count * MemoryLayout<GPUWindowResult>.stride) else { return nil }
        memcpy(bA.contents(), pa, imageBytes)
        memcpy(bB.contents(), pb, imageBytes)
        memcpy(bW.contents(), pw, count * MemoryLayout<GPUWindow>.stride)
        var params = Params(width: Int32(width), height: Int32(height), count: Int32(count), minContrast: minContrast)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(uncertainty ? withSigma : plain)
        enc.setBuffer(bA, offset: 0, index: 0)
        enc.setBuffer(bB, offset: 0, index: 1)
        enc.setBuffer(bW, offset: 0, index: 2)
        enc.setBuffer(bR, offset: 0, index: 3)
        enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 4)
        enc.dispatchThreadgroups(MTLSize(width: count, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: Self.threadsPerGroup, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed, cb.error == nil else { return nil }
        gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        let r = bR.contents().bindMemory(to: GPUWindowResult.self, capacity: count)
        return Array(UnsafeBufferPointer(start: r, count: count))
    }

    /// 🐱 Reuses `buffer` while it is large enough; otherwise replaces it (shared memory).
    private static func buffer(_ device: MTLDevice, _ buffer: inout MTLBuffer?, _ length: Int) -> MTLBuffer? {
        if let b = buffer, b.length >= length { return b }
        buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared)
        return buffer
    }

    /// 🐱 Particle image moved by a known integer shift (+3, −2): every fill kind must put the peak at (−2, +3).
    private func selfTest() -> Bool {
        let w = 64, h = 64
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
        var a = [Float](repeating: 10, count: w * h)
        for _ in 0..<160 {
            let px = rnd() * Float(w), py = rnd() * Float(h), amp = 80 + 120 * rnd()
            var y = max(0, Int(py) - 4)
            while y <= min(h - 1, Int(py) + 4) {
                var x = max(0, Int(px) - 4)
                while x <= min(w - 1, Int(px) + 4) {
                    let dx = Float(x) - px, dy = Float(y) - py
                    a[y * w + x] += amp * exp(-(dx * dx + dy * dy) / 2.88)
                    x += 1
                }
                y += 1
            }
        }
        var b = [Float](repeating: 10, count: w * h)
        for y in 0..<h {
            for x in 0..<w where x >= 3 && y + 2 < h { b[y * w + x] = a[(y + 2) * w + x - 3] }
        }
        let windows = [
            GPUWindow(ax: 16, ay: 16, bx: 16, by: 16, fax: 0, fay: 0, fbx: 0, fby: 0, tapsA: 1, tapsB: 1),
            GPUWindow(ax: 16, ay: 15, bx: 16, by: 15, fax: 0.25, fay: 0.5, fbx: 0.25, fby: 0.5, tapsA: 2, tapsB: 2),
            GPUWindow(ax: 15, ay: 16, bx: 15, by: 16, fax: 0.75, fay: 0.375, fbx: 0.75, fby: 0.375, tapsA: 8, tapsB: 8),
        ]
        let expected = Int32((Self.windowSize - 2) * Self.windowSize + 3)
        for sigma in [false, true] {
            let r = a.withUnsafeBufferPointer { A in
                b.withUnsafeBufferPointer { B in
                    windows.withUnsafeBufferPointer { W in
                        correlate(a: A, b: B, width: w, height: h, windows: W, minContrast: 1.5, uncertainty: sigma)
                    }
                }
            }
            guard let r, r.count == windows.count else { return false }
            for v in r where v.index != expected || !(v.peak > 0.5) { return false }
        }
        return true
    }

    private static var source: String {
        // 🐱 exp(+2πi m/32), m = 0 … 15 (inverse sign; the forward transform uses the conjugate)
        let tw = (0..<16).map { m -> String in
            let t = 2 * Double.pi * Double(m) / 32
            return "float2(" + String(format: "%.9ef", Double(Float(cos(t)))) + ", " + String(format: "%.9ef", Double(Float(sin(t)))) + ")"
        }.joined(separator: ", ")
        return kernelSource.replacingOccurrences(of: "TW_TABLE", with: "constant float2 TW[16] = { " + tw + " };")
    }

    /// 🐱 One threadgroup (128 threads = 4 SIMD groups) per window. SIMD group `sg` owns rows (in the column phase,
    /// 🐱 columns) sg·8 … sg·8+7, lane = the other coordinate, so each 32-point FFT runs in registers with
    /// 🐱 simd_shuffle_xor; transposes go through threadgroup memory with a padded stride of 33 (no bank conflicts).
    /// 🐱 Threadgroup memory ≈ 10.6 KB, shared in turn by the horizontal pass, a′/b′ and ΔS, and the FFT planes.
    private static let kernelSource = #"""
#include <metal_stdlib>
using namespace metal;

#define N 32
#define NN 1024
#define NSG 4                 // SIMD groups per threadgroup
#define RPS 8                 // rows (columns) per SIMD group
#define HR 39                 // rows of the Lanczos horizontal pass (n + 7)
#define LD 33                 // padded stride of the transposes
#define ZSZ (N * LD)
#define TGSZ (2 * HR * N)     // 2496 floats ≥ 2·ZSZ (FFT planes) and 2·NN (a′, b′ / ΔSx, ΔSy)

constant bool WANT_SIGMA [[function_constant(0)]];

TW_TABLE

struct GPUWindow { int ax, ay, bx, by; float fax, fay, fbx, fby; int tapsA, tapsB, pad0, pad1; };
struct GPUWindowResult { int index; float peak, xm, xp, ym, yp, sigmaX, sigmaY; };
struct Params { int width, height, count; float minContrast; };

static inline float2 cmul(float2 a, float2 b) { return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }

static inline float lanczos4(int k, float t) {
    const float x = float(k - 3) - t;
    if (fabs(x) < 1e-9f) return 1.0f;
    const float px = M_PI_F * x;
    return (precise::sinpi(x) / px) * (precise::sinpi(x * 0.25f) / (px * 0.25f));
}

static inline float pix(device const float* img, int i, int last) { return img[clamp(i, 0, last)]; }

// Pixel (r, c) of a window. taps 8: vertical Lanczos pass over the horizontal rows h; taps 2: bilinear; else copy.
// Multiply-adds are fused like vDSP_vsma.
static inline float window_px(device const float* img, int taps, int ix, int iy, float fx, float fy,
                              threadgroup const float* h, threadgroup const float* wy, int r, int c, int W, int last) {
    if (taps == 8) {
        threadgroup const float* s = h + r * N + c;
        if (fy < 1e-6f) return s[3 * N];
        float d = s[0] * wy[0];
        for (int j = 1; j < 8; j++) d = fma(s[j * N], wy[j], d);
        return d;
    }
    const int i0 = (iy + r) * W + ix + c;
    if (taps == 2) {
        const float w00 = (1.0f - fx) * (1.0f - fy), w10 = fx * (1.0f - fy), w01 = (1.0f - fx) * fy, w11 = fx * fy;
        float d = pix(img, i0, last) * w00;
        d = fma(pix(img, i0 + 1, last), w10, d);
        d = fma(pix(img, i0 + W, last), w01, d);
        d = fma(pix(img, i0 + W + 1, last), w11, d);
        return d;
    }
    return pix(img, i0, last);
}

// Radix-2 DIF across the 32 lanes: natural order in, bit-reversed out. tw[s] = W_{2h}^{lane & (h−1)}, h = 16 >> s.
#define FFT_DIF(z, CONJ)                                                        \
    for (uint s = 0; s < 5; s++) {                                              \
        const ushort h = ushort(16u >> s);                                      \
        const bool up = (lane & h) != 0;                                        \
        const float2 w = CONJ ? float2(tw[s].x, -tw[s].y) : tw[s];              \
        for (uint i = 0; i < RPS; i++) {                                        \
            const float2 o = simd_shuffle_xor(z[i], h);                         \
            z[i] = up ? cmul(o - z[i], w) : z[i] + o;                           \
        }                                                                       \
    }

#define BARRIER() threadgroup_barrier(mem_flags::mem_threadgroup)

kernel void correlate32(device const float* imgA [[buffer(0)]],
                        device const float* imgB [[buffer(1)]],
                        device const GPUWindow* wins [[buffer(2)]],
                        device GPUWindowResult* out [[buffer(3)]],
                        constant Params& P [[buffer(4)]],
                        uint wid [[threadgroup_position_in_grid]],
                        uint tid [[thread_index_in_threadgroup]],
                        uint sg [[simdgroup_index_in_threadgroup]],
                        uint lane [[thread_index_in_simdgroup]])
{
    threadgroup float tg[TGSZ];
    threadgroup float wts[32];
    threadgroup float red[4 * NSG];
    threadgroup float ured[11 * NSG];
    threadgroup float pkv[NSG];
    threadgroup int pki[NSG];

    const GPUWindow g = wins[wid];
    const int W = P.width, last = P.width * P.height - 1;
    float2 tw[5];
    for (uint s = 0; s < 5; s++) tw[s] = TW[(lane & ((16u >> s) - 1u)) << s];
    const uint br = reverse_bits(lane) >> 27;           // 5-bit bit reversal

    // 1. Lanczos-4 weights: lane = image·16 + axis·8 + tap (float sum in tap order, like the app)
    if (sg == 0) {
        const float4 fr = float4(g.fax, g.fay, g.fbx, g.fby);
        const float v = lanczos4(int(lane & 7u), fr[lane >> 3]);
        float sum = 0.0f;
        for (uint j = 0; j < 8; j++) sum += simd_shuffle(v, ushort((lane & ~7u) + j));
        wts[lane] = v / sum;
    }
    BARRIER();

    // 2. horizontal Lanczos pass of the taps-8 windows: tg[img][r][c], r = 0 … 38 ↔ image row iy − 3 + r
    for (uint row = sg; row < 2 * HR; row += NSG) {
        const bool second = row >= HR;
        if ((second ? g.tapsB : g.tapsA) != 8) continue;
        const int r = int(second ? row - HR : row);
        device const float* src = second ? imgB : imgA;
        const int ix = second ? g.bx : g.ax, iy = second ? g.by : g.ay;
        const float fx = second ? g.fbx : g.fax;
        const int i0 = (iy - 3 + r) * W + (ix - 3) + int(lane);
        float d;
        if (fx < 1e-6f) {
            d = pix(src, i0 + 3, last);
        } else {
            threadgroup const float* w = wts + (second ? 16 : 0);
            d = pix(src, i0, last) * w[0];
            for (int j = 1; j < 8; j++) d = fma(pix(src, i0 + j, last), w[j], d);
        }
        tg[row * N + lane] = d;
    }
    BARRIER();

    // 3. both windows into registers: row sg·RPS + i, column lane
    float2 z[RPS];
    float sa = 0.0f, sb = 0.0f;
    for (uint i = 0; i < RPS; i++) {
        const int r = int(sg * RPS + i);
        const float a = window_px(imgA, g.tapsA, g.ax, g.ay, g.fax, g.fay, tg, wts + 8, r, int(lane), W, last);
        const float b = window_px(imgB, g.tapsB, g.bx, g.by, g.fbx, g.fby, tg + HR * N, wts + 24, r, int(lane), W, last);
        z[i] = float2(a, b);
        sa += a; sb += b;
    }

    // 4. mean and population σ
    sa = simd_sum(sa); sb = simd_sum(sb);
    if (lane == 0) { red[sg] = sa; red[NSG + sg] = sb; }
    BARRIER();
    sa = 0.0f; sb = 0.0f;
    for (uint k = 0; k < NSG; k++) { sa += red[k]; sb += red[NSG + k]; }
    const float mA = sa / float(NN), mB = sb / float(NN);
    float qa = 0.0f, qb = 0.0f;
    for (uint i = 0; i < RPS; i++) {
        z[i] -= float2(mA, mB);                         // a′ + i·b′
        qa += z[i].x * z[i].x; qb += z[i].y * z[i].y;
        if (WANT_SIGMA) { const uint x = (sg * RPS + i) * N + lane; tg[x] = z[i].x; tg[NN + x] = z[i].y; }
    }
    qa = simd_sum(qa); qb = simd_sum(qb);
    if (lane == 0) { red[2 * NSG + sg] = qa; red[3 * NSG + sg] = qb; }
    BARRIER();
    qa = 0.0f; qb = 0.0f;
    for (uint k = 0; k < NSG; k++) { qa += red[2 * NSG + k]; qb += red[3 * NSG + k]; }
    const float sdA = sqrt(qa / float(NN)), sdB = sqrt(qb / float(NN));
    if (!(sdA >= P.minContrast && sdB >= P.minContrast)) {   // uniform across the threadgroup
        if (tid == 0) out[wid] = GPUWindowResult{-1, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, -1.0f, -1.0f};
        return;
    }

    // 5. uncertainty (Wieneke 2015), as CorrelationWork.uncertainty(): lag 1 (x, row ends excluded) and lag n (y)
    float sigX = -1.0f, sigY = -1.0f;
    if (WANT_SIGMA) {
        float dX[RPS], dY[RPS];
        float u[7] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};   // C0, C+x, C−x, C+y, C−y, ΣΔSx, ΣΔSy
        for (uint i = 0; i < RPS; i++) {
            const uint r = sg * RPS + i, x = r * N + lane;
            const float a0 = z[i].x, b0 = z[i].y;
            float spx = 0.0f, smx = 0.0f, spy = 0.0f, smy = 0.0f;
            if (lane < N - 1) { spx = a0 * tg[NN + x + 1]; smx = tg[x + 1] * b0; }
            if (r < N - 1) { spy = a0 * tg[NN + x + N]; smy = tg[x + N] * b0; }
            dX[i] = spx - smx; dY[i] = spy - smy;
            u[0] += a0 * b0; u[1] += spx; u[2] += smx; u[3] += spy; u[4] += smy; u[5] += dX[i]; u[6] += dY[i];
        }
        for (uint k = 0; k < 7; k++) { const float t = simd_sum(u[k]); if (lane == 0) ured[k * NSG + sg] = t; }
        BARRIER();
        for (uint k = 0; k < 7; k++) { float t = 0.0f; for (uint q = 0; q < NSG; q++) t += ured[k * NSG + q]; u[k] = t; }
        const float c0 = u[0], cbx = (u[1] + u[2]) / 2.0f, cby = (u[3] + u[4]) / 2.0f;
        if (c0 > 0.0f && cbx > 0.0f && c0 > cbx * 1.0001f && cby > 0.0f && c0 > cby * 1.0001f) {   // uniform
            const float mx = u[5] / float(N * (N - 1)), my = u[6] / float(N * (N - 1));     // 992 pairs per axis
            for (uint i = 0; i < RPS; i++) {
                const uint r = sg * RPS + i;
                dX[i] = lane < N - 1 ? dX[i] - mx : 0.0f;
                dY[i] = r < N - 1 ? dY[i] - my : 0.0f;
            }
            BARRIER();                                   // everyone is done reading a′, b′
            for (uint i = 0; i < RPS; i++) { const uint x = (sg * RPS + i) * N + lane; tg[x] = dX[i]; tg[NN + x] = dY[i]; }
            BARRIER();
            // variance and the covariances at flattened offsets dy·n + dx (dy 0…2, half plane, radius 2), summed together
            const uint offs[12] = {1, 2, 30, 31, 32, 33, 34, 62, 63, 64, 65, 66};
            float v[4] = {0.0f, 0.0f, 0.0f, 0.0f};       // Σ ΔSx², Σ ΔSy², covX, covY
            for (uint i = 0; i < RPS; i++) {
                const uint x = (sg * RPS + i) * N + lane;
                float nx = 0.0f, ny = 0.0f;
                for (uint k = 0; k < 12; k++) {
                    const uint y = x + offs[k];
                    if (y < NN) { nx += tg[y]; ny += tg[NN + y]; }
                }
                v[0] += dX[i] * dX[i]; v[1] += dY[i] * dY[i]; v[2] += dX[i] * nx; v[3] += dY[i] * ny;
            }
            for (uint k = 0; k < 4; k++) { const float t = simd_sum(v[k]); if (lane == 0) ured[(7 + k) * NSG + sg] = t; }
            BARRIER();
            for (uint k = 0; k < 4; k++) { float t = 0.0f; for (uint q = 0; q < NSG; q++) t += ured[(7 + k) * NSG + q]; v[k] = t; }
            const float tx = max(v[0], v[0] + 2.0f * v[2]), ty = max(v[1], v[1] + 2.0f * v[3]);
            sigX = sqrt(tx) / (4.0f * cbx * precise::log(c0 / cbx));
            sigY = sqrt(ty) / (4.0f * cby * precise::log(c0 / cby));
        }
    }

    threadgroup float* Zr = tg;
    threadgroup float* Zi = tg + ZSZ;

    // 6. forward FFT along rows (lanes = columns) → lane l holds kc = br(l); stored as [r][kc]
    FFT_DIF(z, true)
    for (uint i = 0; i < RPS; i++) {
        const uint r = sg * RPS + i;
        Zr[r * LD + br] = z[i].x; Zi[r * LD + br] = z[i].y;
    }
    BARRIER();
    // along columns: column kc = sg·RPS + i, lane = row → lane l holds kr = br(l)
    for (uint i = 0; i < RPS; i++) {
        const uint kc = sg * RPS + i;
        z[i] = float2(Zr[lane * LD + kc], Zi[lane * LD + kc]);
    }
    FFT_DIF(z, true)
    BARRIER();
    for (uint i = 0; i < RPS; i++) {                     // Z stored as [kc][kr]
        const uint kc = sg * RPS + i;
        Zr[kc * LD + br] = z[i].x; Zi[kc * LD + br] = z[i].y;
    }
    BARRIER();

    // 7. FA = (Z(k) + conj Z(−k))/2, FB = (Z(k) − conj Z(−k))/(2i), P = conj(FA)·FB
    {
        const uint mr = (32u - br) & 31u;
        for (uint i = 0; i < RPS; i++) {
            const uint mc = (32u - (sg * RPS + i)) & 31u;
            const float2 m = float2(Zr[mc * LD + mr], Zi[mc * LD + mr]);
            const float far = (z[i].x + m.x) * 0.5f, fai = (z[i].y - m.y) * 0.5f;
            const float fbr = (z[i].y + m.y) * 0.5f, fbi = (m.x - z[i].x) * 0.5f;
            z[i] = float2(far * fbr + fai * fbi, far * fbi - fai * fbr);
        }
    }

    // 8. inverse FFT along columns: DIT, lanes hold kr bit-reversed → lane = row r
    for (int s = 4; s >= 0; s--) {
        const ushort h = ushort(16u >> s);
        const bool up = (lane & h) != 0;
        const float2 w = tw[s];
        for (uint i = 0; i < RPS; i++) {
            const float2 o = simd_shuffle_xor(z[i], h);
            const float2 t = cmul(up ? z[i] : o, w);
            z[i] = up ? o - t : z[i] + t;
        }
    }
    BARRIER();
    for (uint i = 0; i < RPS; i++) {                     // stored as [r][kc]
        const uint kc = sg * RPS + i;
        Zr[lane * LD + kc] = z[i].x; Zi[lane * LD + kc] = z[i].y;
    }
    BARRIER();
    // along rows: row r = sg·RPS + i, lane = kc → lane l holds column br(l)
    for (uint i = 0; i < RPS; i++) {
        const uint r = sg * RPS + i;
        z[i] = float2(Zr[r * LD + lane], Zi[r * LD + lane]);
    }
    FFT_DIF(z, false)

    // 9. normalise (IFFT is unnormalised: ×nn), plane into threadgroup memory, first-index argmax
    const float scale = 1.0f / (float(NN) * float(NN) * sdA * sdB);
    BARRIER();
    threadgroup float* plane = tg;
    float best = -FLT_MAX;
    int bi = 0x7fffffff;
    for (uint i = 0; i < RPS; i++) {
        const int idx = int((sg * RPS + i) * N + br);
        const float v = z[i].x * scale;
        plane[idx] = v;
        if (v > best) { best = v; bi = idx; }
    }
    const float m = simd_max(best);
    const int cand = simd_min(best == m ? bi : 0x7fffffff);
    if (lane == 0) { pkv[sg] = m; pki[sg] = cand; }
    BARRIER();
    if (tid == 0) {
        float pk = pkv[0];
        int id = pki[0];
        for (uint k = 1; k < NSG; k++) {
            if (pkv[k] > pk || (pkv[k] == pk && pki[k] < id)) { pk = pkv[k]; id = pki[k]; }
        }
        const int pr = id >> 5, pc = id & 31;
        out[wid] = GPUWindowResult{id, pk,
                                   plane[pr * N + ((pc - 1) & 31)], plane[pr * N + ((pc + 1) & 31)],
                                   plane[((pr - 1) & 31) * N + pc], plane[((pr + 1) & 31) * N + pc],
                                   sigX, sigY};
    }
}
"""#
}
