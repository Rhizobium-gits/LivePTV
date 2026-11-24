// 🐱 ace-probe: verify the Ace Pro 2 Wi-Fi live preview from a Mac, using exactly the same client code as the
// 🐱 iPad app, before anyone builds the app. Also benchmarks the analysis on synthetic frames.
// 🐱
// 🐱   swift run -c release ace-probe probe [--host 192.168.42.1] [--port 6666] [--seconds 20] [--out DIR]
// 🐱                                        [--res 29,43,9] [--low-latency] [--no-secondary]
// 🐱   swift run -c release ace-probe benchmark [--method piv|ptv] [--windows 64,32] [--width 1920] [--height 1080] [--particles 3000] [--frames 150]
// 🐱                                            [--gpu 0]   (0 = correlate on the CPU even when a GPU is available)
// 🐱   swift run -c release ace-probe usb [--seconds 30] [--width 1920 --height 1080] [--out DIR] [--cell 48]
// 🐱       live analysis from a USB (UVC) camera, e.g. the Ace Pro 2 in Webcam mode
// 🐱   swift run -c release ace-probe file --path clip.mov [--out DIR]
// 🐱       a recorded video through the same pipeline, every frame analysed
// 🐱   usb and file also take: --method piv|ptv  --shake 0  --shake-model auto|translation|similarity|affine|perspective|pivot
// 🐱                           --deform 0  --gpu 0  --background off|mean|…  --resolution auto|full|half|quarter  --spacing K
import AVFoundation
import CameraKit
import CoreImage
import Foundation
import ImageIO
import Pipeline
import PTVCore
import Vision

struct Args {
    var command = "probe"
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        var rest = Array(argv.dropFirst())
        if let first = rest.first, !first.hasPrefix("--") { command = first; rest.removeFirst() }
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") { options[key] = rest[i + 1]; i += 2 } else { flags.insert(key); i += 1 }
            } else { i += 1 }
        }
    }

    func string(_ k: String, _ d: String) -> String { options[k] ?? d }
    func double(_ k: String, _ d: Double) -> Double { options[k].flatMap(Double.init) ?? d }
    func int(_ k: String, _ d: Int) -> Int { options[k].flatMap(Int.init) ?? d }
}

func say(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

final class Capture: @unchecked Sendable {
    let lock = NSLock()
    var rawHandle: FileHandle?
    var rawURL: URL?
    var index: FileHandle?
    var offset = 0
    var units = 0
    var keyFrames = 0
    var bytes = 0
    var firstArrival: Double?
    var lastArrival: Double?
    let dir: URL

    init(dir: URL) { self.dir = dir }

    func add(_ au: CompressedAccessUnit) {
        lock.withLock {
            if rawHandle == nil {
                let url = dir.appendingPathComponent(au.codec == .hevc ? "preview.h265" : "preview.h264")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                rawHandle = try? FileHandle(forWritingTo: url)
                rawURL = url
                let iu = dir.appendingPathComponent("preview_index.csv")
                FileManager.default.createFile(atPath: iu.path, contents: "au_index,byte_offset,byte_length,source_ts_raw,received_host_s,key_frame\n".data(using: .utf8))
                index = try? FileHandle(forWritingTo: iu)
                index?.seekToEndOfFile()
            }
            rawHandle?.write(au.annexB)
            index?.write("\(units),\(offset),\(au.annexB.count),\(au.sourceTimestampRaw),\(String(format: "%.6f", au.receivedHostTime)),\(au.isKeyFrame ? 1 : 0)\n".data(using: .utf8)!)
            offset += au.annexB.count
            units += 1
            bytes += au.annexB.count
            if au.isKeyFrame { keyFrames += 1 }
            firstArrival = firstArrival ?? au.receivedHostTime
            lastArrival = au.receivedHostTime
        }
    }

    func close() { lock.withLock { try? rawHandle?.close(); try? index?.close() } }
}

func median(_ v: [Double]) -> Double? {
    guard !v.isEmpty else { return nil }
    let s = v.sorted()
    return s[s.count / 2]
}

func probe(_ args: Args) async -> Int32 {
    let host = args.string("host", Insta360Protocol.defaultHost)
    let port = UInt16(args.int("port", Int(Insta360Protocol.defaultPort)))
    let seconds = args.double("seconds", 20)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let out = URL(fileURLWithPath: args.string("out", "ace-probe-\(stamp)"))
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var findings: [String: Any] = ["host": host, "port": Int(port), "started_utc": ISO8601DateFormatter().string(from: Date())]

    say("== 1. Network path to \(host):\(port)")
    let steps = await NetworkDiagnostics.checkPath(to: host, port: port, requireWiFi: false)
    for s in steps { say("   [\(s.status.rawValue.uppercased())] \(s.title): \(s.detail)") }
    findings["network_checks"] = steps.map { ["title": $0.title, "status": $0.status.rawValue, "detail": $0.detail] }

    var cfg = Insta360AcePro2WiFiSource.Configuration()
    cfg.host = host
    cfg.port = port
    cfg.requireWiFiInterface = false
    cfg.autoReconnect = false
    cfg.emitCompressedAccessUnits = true
    cfg.packetLogLimit = 3000
    if args.flags.contains("low-latency") { cfg.assemblyMode = .lowLatency }
    if args.flags.contains("no-secondary") { cfg.secondaryResolution = nil }
    if let list = args.options["res"] {
        let parsed = list.split(separator: ",").compactMap { Int($0) }.compactMap(Insta360Messages.PreviewResolution.init(rawValue:))
        if !parsed.isEmpty { cfg.previewResolutions = parsed }
    }
    let source = Insta360AcePro2WiFiSource(configuration: cfg)
    let capture = Capture(dir: out)
    let logLines = LogBox()
    source.onEvent = { e in
        switch e {
        case let .log(level, message):
            logLines.add("[\(level.rawValue)] \(message)")
            if level != .debug { say("   \(level.rawValue): \(message)") }
        case let .stateChanged(s): logLines.add("[state] \(s)")
        case let .streamParameters(p): say("   stream parameters: \(p.codec.rawValue) \(p.width)x\(p.height) fps=\(p.nominalFPS.map { String($0) } ?? "?") [\(p.origin)]")
        case let .compressedAccessUnit(au): capture.add(au)
        }
    }

    func finish(_ verdict: String, _ code: Int32) -> Int32 {
        capture.close()
        findings["verdict"] = verdict
        findings["packet_histogram"] = source.statistics().packetTypes
        findings["log"] = logLines.lines
        let enc = try? JSONSerialization.data(withJSONObject: findings, options: [.prettyPrinted, .sortedKeys])
        try? enc?.write(to: out.appendingPathComponent("summary.json"))
        let pl = JSONEncoder()
        pl.outputFormatting = [.sortedKeys]
        let lines = source.packetLog.compactMap { try? pl.encode($0) }.map { String(data: $0, encoding: .utf8)! }.joined(separator: "\n")
        try? lines.write(to: out.appendingPathComponent("packets.jsonl"), atomically: true, encoding: .utf8)
        say("\n== Verdict: \(verdict)")
        say("   Evidence written to \(out.path)/ (summary.json, packets.jsonl, frames.csv, preview stream)")
        return code
    }

    say("\n== 2. Protocol handshake")
    do {
        try await source.connect()
        let info = source.cameraInfo
        say("   connected. camera type: \(info?.cameraType ?? "not reported"), firmware: \(info?.firmware ?? "not reported")")
        findings["camera_type"] = info?.cameraType ?? NSNull()
        findings["firmware"] = info?.firmware ?? NSNull()
    } catch {
        say("   FAILED: \(error)")
        if let e = error as? CameraError { say("   hint: \(e.hint)") }
        findings["error"] = "\(error)"
        return finish("NOT VERIFIED - could not complete the protocol handshake", 2)
    }

    say("\n== 3. Start live preview")
    do {
        try await source.startPreview()
    } catch {
        say("   FAILED: \(error)")
        if let e = error as? CameraError { say("   hint: \(e.hint)") }
        findings["error"] = "\(error)"
        await source.disconnect()
        return finish("NOT VERIFIED - camera did not start a preview stream", 3)
    }

    say("\n== 4. Receiving for \(Int(seconds)) s")
    var rows = ["frame_index,segment,timestamp_quality,source_ts_raw,pts_s,received_host_s,assembled_host_s,decoded_host_s,width,height"]
    var pts: [Double] = [], recv: [Double] = [], decodeMs: [Double] = [], waitMs: [Double] = []
    var lastFrame: VideoFrame?
    let deadline = HostClock.now() + seconds
    var lastReport = HostClock.now()
    while HostClock.now() < deadline {
        guard let f = source.getFrame() else {
            try? await Task.sleep(nanoseconds: 2_000_000)
            continue
        }
        lastFrame = f
        rows.append("\(f.index),\(f.segment),\(f.timestampQuality.rawValue),\(f.timing.sourceTimestampRaw ?? -1),\(String(format: "%.6f", f.presentationTime)),\(String(format: "%.6f", f.timing.receivedHostTime)),\(String(format: "%.6f", f.timing.assembledHostTime)),\(String(format: "%.6f", f.timing.decodedHostTime)),\(f.width),\(f.height)")
        if f.timestampQuality == .source { pts.append(f.presentationTime); recv.append(f.timing.receivedHostTime) }
        waitMs.append((f.timing.assembledHostTime - f.timing.receivedHostTime) * 1000)
        decodeMs.append((f.timing.decodedHostTime - f.timing.assembledHostTime) * 1000)
        if HostClock.now() - lastReport > 2 {
            lastReport = HostClock.now()
            let st = source.statistics()
            say("   decoded \(st.framesDecoded) frames, \(st.decodeErrors) decode errors, \(st.bytesReceived / 1024) KiB received")
        }
    }
    try? rows.joined(separator: "\n").write(to: out.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
    let stats = source.statistics()
    let assembler = source.assemblerStatus
    let unit = source.timestampUnit
    await source.stopPreview()
    await source.disconnect()

    // 🐱 Analysis of what was observed.
    let intervals = zip(pts.dropFirst(), pts).map { $0 - $1 }.filter { $0 > 0 }
    let medianInterval = median(intervals)
    let fps = medianInterval.map { 1 / $0 }
    var gapFrames = 0
    if let mi = medianInterval { for d in intervals { gapFrames += max(0, Int((d / mi).rounded()) - 1) } }
    // 🐱 Arrival jitter: residual of (arrival − camera time) after a linear fit against camera time, which
    // 🐱 removes both the clock offset and any rate difference between the camera clock and the host clock.
    let jitterMs: Double? = {
        guard pts.count > 3 else { return nil }
        let x = pts.map { $0 - pts[0] }
        let y = zip(recv, pts).map { $0 - $1 }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        let sxx = x.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        let sxy = zip(x, y).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let slope = sxx > 0 ? sxy / sxx : 0
        let res = zip(x, y).map { $1 - (my + slope * ($0 - mx)) }
        return sqrt(res.map { $0 * $0 }.reduce(0, +) / n) * 1000
    }()
    let duration = (capture.lastArrival ?? 0) - (capture.firstArrival ?? 0)
    let mbps = duration > 0 ? Double(capture.bytes) * 8 / duration / 1e6 : nil

    findings["frames_decoded"] = stats.framesDecoded
    findings["decode_errors"] = stats.decodeErrors
    findings["discarded_before_decode"] = stats.framesDiscardedBeforeDecode
    findings["access_units"] = capture.units
    findings["key_frames"] = capture.keyFrames
    findings["resolution"] = lastFrame.map { "\($0.width)x\($0.height)" } ?? NSNull()
    findings["codec"] = source.streamParameters?.codec.rawValue ?? NSNull()
    findings["stream_parameters_origin"] = source.streamParameters?.origin ?? NSNull()
    findings["timestamp_unit"] = unit?.rawValue ?? NSNull()
    findings["measured_fps_from_camera_timestamps"] = fps ?? NSNull()
    findings["missing_frames_from_timestamps"] = gapFrames
    findings["arrival_jitter_ms"] = jitterMs ?? NSNull()
    findings["decode_latency_median_ms"] = median(decodeMs) ?? NSNull()
    findings["assembly_wait_median_ms"] = median(waitMs) ?? NSNull()
    findings["video_bitrate_mbps"] = mbps ?? NSNull()
    findings["assembler_mode_final"] = assembler.mode.rawValue
    findings["late_slices"] = assembler.lateSlices

    say("\n== 5. Observed stream")
    say("   codec:            \(source.streamParameters?.codec.rawValue ?? "?")")
    say("   decoded size:     \(lastFrame.map { "\($0.width)x\($0.height)" } ?? "none")")
    say("   frames decoded:   \(stats.framesDecoded) (decode errors \(stats.decodeErrors), discarded before decode \(stats.framesDiscardedBeforeDecode))")
    say("   timestamp unit:   \(unit?.rawValue ?? "not determined")")
    say("   frame rate:       \(fps.map { String(format: "%.2f fps (camera timestamps)", $0) } ?? "not measurable")")
    say("   missing frames:   \(gapFrames) (gaps in camera timestamps)")
    say("   arrival jitter:   \(jitterMs.map { String(format: "%.1f ms RMS", $0) } ?? "n/a")")
    say("   assembly wait:    \(median(waitMs).map { String(format: "%.1f ms median (picture complete → decoder)", $0) } ?? "n/a")")
    say("   decode time:      \(median(decodeMs).map { String(format: "%.1f ms median (hardware decoder)", $0) } ?? "n/a")")
    say("   bitrate:          \(mbps.map { String(format: "%.2f Mbit/s", $0) } ?? "n/a")")
    say("   late slices:      \(assembler.lateSlices) (assembler mode \(assembler.mode.rawValue))")
    say("   note: glass-to-glass latency needs the in-app flash test (camera pointed at the iPad screen).")

    if stats.framesDecoded > 0 && unit != nil {
        return finish("VERIFIED - live preview received and decoded locally with camera timestamps", 0)
    } else if stats.framesDecoded > 0 {
        return finish("PARTIAL - frames decoded, but camera timestamps were not usable", 4)
    } else {
        return finish("NOT VERIFIED - preview command accepted but no decodable video arrived", 5)
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var lines: [String] { lock.withLock { v } }
}

func benchmark(_ args: Args) async -> Int32 {
    var cfg = TestVideoSource.Configuration()
    cfg.width = args.int("width", 1920)
    cfg.height = args.int("height", 1080)
    cfg.particleCount = args.int("particles", 3000)
    cfg.frameLimit = args.int("frames", 150)
    cfg.realTime = false
    cfg.flow = .lambOseen(circulation: Double(cfg.height) * 120, coreRadius: Double(cfg.height) / 8)
    say("Benchmark: \(cfg.width)x\(cfg.height), \(cfg.particleCount) particles, \(cfg.frameLimit!) frames (synthetic, analysis only)")
    let source = TestVideoSource(configuration: cfg)
    var settings = AnalysisSettings()
    settings.method = AnalysisMethod(rawValue: args.string("method", "piv")) ?? .piv
    if let w = args.options["windows"] { settings.piv.windowSizes = w.split(separator: ",").compactMap { Int($0) } }
    // 🐱 switches to measure what each refinement costs
    if let i = args.options["interp"], let v = PIVParameters.WindowInterpolation(rawValue: i) { settings.piv.windowInterpolation = v }
    if let b = args.options["background"], let v = ReflectionParameters.Background(rawValue: b) { settings.reflections.background = v }
    if args.options["uncertainty"] == "0" { settings.piv.uncertainty = false }
    if args.options["masks"] == "0" { settings.reflections.glareMasking = false; settings.reflections.saturationMasking = false }
    if args.options["gpu"] == "0" { settings.piv.useGPU = false }
    settings.pivResolution = .full
    say("interpolation \(settings.piv.windowInterpolation.rawValue), background \(settings.reflections.background.rawValue), uncertainty \(settings.piv.uncertainty), masks \(settings.reflections.glareMasking)")
    say("method: \(settings.method.title)\(settings.method == .piv ? ", windows \(settings.piv.windowSizes), overlap \(Int(settings.piv.overlap * 100)) %, final iterations \(settings.piv.finalIterations)" : "")")
    let pipeline = AnalysisPipeline(source: source, settings: settings)
    do { try await source.startPreview() } catch { say("cannot start synthetic source: \(error)"); return 1 }
    pipeline.start()
    while pipeline.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
    let m = pipeline.metrics
    say(String(format: "analysis per frame (median of last 120): %.1f ms  → max sustainable %.0f fps on this machine",
               m.analysisDurationMs ?? .nan, 1000 / (m.analysisDurationMs ?? .nan)))
    if let d = m.pivDevice { say("PIV correlation on: \(d)  (--gpu 0 forces the CPU)") }
    if settings.method == .piv {
        say(String(format: "PIV vectors/field %d, valid %.1f %%", m.pivVectors, m.pivValidPercent ?? .nan))
    } else {
        say("particles/frame \(m.particles), active tracks \(m.activeTracks), samples/frame \(m.samples)")
    }
    say("Note: excludes synthetic image generation; an iPad's per-core speed differs from this Mac.")
    return 0
}

// 🐱 MARK: live analysis from a USB camera

final class LatestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var r: FrameResult?
    func set(_ x: FrameResult) { lock.withLock { r = x } }
    var value: FrameResult? { lock.withLock { r } }
}

/// 🐱 Frame + particles + tails + velocity field, drawn in image pixel coordinates, saved as PNG.
func saveOverlay(_ r: FrameResult, to url: URL, vectorSeconds: Double) {
    guard let img = renderOverlay(r, vectorSeconds: vectorSeconds),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

private let overlayContext = CIContext()

/// 🐱 Privacy for published overlays: faces (Vision) and fixed rectangles (image px, origin top-left) are blurred in
/// 🐱 the picture only; the analysis always runs on the unblurred frames. A face keeps its last box for up to 1 s when
/// 🐱 detection misses it for a moment.
final class PrivacyBlur: @unchecked Sendable {
    let faces: Bool
    let rects: [CGRect]
    private var lastFaces: [CGRect] = []
    private var lastFaceTime = -Double.infinity
    init(faces: Bool, rects: [CGRect]) { self.faces = faces; self.rects = rects }

    func apply(_ image: CIImage, pixelBuffer: CVPixelBuffer, time: Double) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        var boxes: [CGRect] = rects.map { CGRect(x: $0.minX, y: h - $0.maxY, width: $0.width, height: $0.height) }   // 🐱 → CI (origin bottom-left)
        if faces {
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
            let found = (request.results ?? []).map { o -> CGRect in
                let b = o.boundingBox
                let r = CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h)
                return r.insetBy(dx: -0.45 * r.width, dy: -0.55 * r.height)   // 🐱 hair, ears, chin
            }
            if !found.isEmpty { lastFaces = found; lastFaceTime = time } else if time - lastFaceTime > 1 { lastFaces = [] }
            boxes += lastFaces
        }
        guard !boxes.isEmpty else { return image }
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: max(12, Double(w) / 60)).cropped(to: image.extent)
        var out = image
        for b in boxes { out = blurred.cropped(to: b.intersection(image.extent)).composited(over: out) }
        return out
    }
}

/// 🐱 The same drawing, scaled to `width` px and saved as JPEG (frames of an animation).
func saveOverlayJPEG(_ r: FrameResult, to url: URL, vectorSeconds: Double, width: Int, privacy: PrivacyBlur? = nil, lineScale: Double = 1) {
    guard let img = renderOverlay(r, vectorSeconds: vectorSeconds, privacy: privacy, lineScale: lineScale) else { return }
    let w = min(width, img.width), h = Int((Double(img.height) * Double(w) / Double(img.width)).rounded())
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let small = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

func renderOverlay(_ r: FrameResult, vectorSeconds: Double, privacy: PrivacyBlur? = nil, lineScale: Double = 1) -> CGImage? {
    var ci = CIImage(cvPixelBuffer: r.frame.pixelBuffer)
    if let privacy { ci = privacy.apply(ci, pixelBuffer: r.frame.pixelBuffer, time: r.frame.presentationTime) }
    guard let frame = overlayContext.createCGImage(ci, from: ci.extent) else { return nil }
    let w = frame.width, h = frame.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)   // 🐱 from here on y points down, like image coordinates
    ctx.setStrokeColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 0.9))
    ctx.setLineWidth(2)
    ctx.stroke(CGRect(x: r.roi.x, y: r.roi.y, width: r.roi.width, height: r.roi.height))
    ctx.setStrokeColor(CGColor(red: 0, green: 0.9, blue: 1, alpha: 0.7))
    ctx.setLineWidth(1)
    for t in r.tails where t.count > 1 {
        ctx.move(to: CGPoint(x: t[0].x, y: t[0].y))
        for q in t.dropFirst() { ctx.addLine(to: CGPoint(x: q.x, y: q.y)) }
    }
    ctx.strokePath()
    ctx.setStrokeColor(CGColor(red: 0.2, green: 1, blue: 0.2, alpha: 0.9))
    for p in r.particles { ctx.strokeEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)) }
    if let f = r.field {
        let speeds = f.cells.filter(\.valid).map { hypot($0.u, $0.v) }.sorted()
        let ref = speeds.isEmpty ? 1 : max(1e-9, speeds[min(speeds.count - 1, Int(Double(speeds.count) * 0.95))])
        ctx.setLineWidth(2.5 * lineScale)
        for c in f.cells where c.valid {
            let t = min(1, hypot(c.u, c.v) / ref)
            ctx.setStrokeColor(CGColor(red: t, green: 1 - abs(t - 0.5) * 2 * 0.6, blue: 1 - t, alpha: 1))
            let ex = c.x + c.u * vectorSeconds, ey = c.y + c.v * vectorSeconds
            ctx.move(to: CGPoint(x: c.x, y: c.y))
            ctx.addLine(to: CGPoint(x: ex, y: ey))
            let len = hypot(ex - c.x, ey - c.y)
            if len > 4 {
                let ux = (ex - c.x) / len, uy = (ey - c.y) / len, hd = min(8 * lineScale, len * 0.35)
                ctx.move(to: CGPoint(x: ex, y: ey)); ctx.addLine(to: CGPoint(x: ex - hd * (ux - 0.5 * uy), y: ey - hd * (uy + 0.5 * ux)))
                ctx.move(to: CGPoint(x: ex, y: ey)); ctx.addLine(to: CGPoint(x: ex - hd * (ux + 0.5 * uy), y: ey - hd * (uy - 0.5 * ux)))
            }
            ctx.strokePath()
        }
    }
    return ctx.makeImage()
}

/// 🐱 Every frame the camera delivered, as ProRes 422 with the camera's timestamps (re-analysis of exactly what was
/// 🐱 analysed live, by LivePTV or other tools).
final class StreamWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private(set) var written = 0
    private(set) var dropped = 0
    private var closed = false

    init(url: URL) { self.url = url; try? FileManager.default.removeItem(at: url) }

    func append(_ f: VideoFrame) {
        lock.withLock {
            guard !closed else { return }
            let t = CMTime(seconds: f.presentationTime, preferredTimescale: 90_000)
            if writer == nil {
                guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { closed = true; return }
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422,
                                                                                 AVVideoWidthKey: f.width, AVVideoHeightKey: f.height])
                i.expectsMediaDataInRealTime = true
                let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: nil)
                guard w.canAdd(i) else { closed = true; return }
                w.add(i)
                guard w.startWriting() else { closed = true; return }
                w.startSession(atSourceTime: t)
                writer = w; input = i; adaptor = a
            }
            guard let i = input, let a = adaptor, i.isReadyForMoreMediaData else { dropped += 1; return }
            if a.append(f.pixelBuffer, withPresentationTime: t) { written += 1 } else { dropped += 1 }
        }
    }

    func finish() async {
        let w: AVAssetWriter? = lock.withLock {
            closed = true
            input?.markAsFinished()
            return writer
        }
        if let w { await w.finishWriting() }
    }
}

/// 🐱 Analysis settings shared by `usb` and `file`: the app's defaults plus the switches below.
func analysisSettings(_ args: Args) -> AnalysisSettings {
    var settings = AnalysisSettings()
    settings.field.cellSize = args.double("cell", 48)
    settings.field.window = args.double("window", 1.0)
    settings.method = AnalysisMethod(rawValue: args.string("method", "piv")) ?? .piv
    if args.options["shake"] == "0" { settings.shake.enabled = false }
    if let m = args.options["shake-model"], let v = ShakeParameters.Model(rawValue: m) { settings.shake.model = v }
    if args.options["deform"] == "0" { settings.piv.deformation = false }
    if args.options["gpu"] == "0" { settings.piv.useGPU = false }
    if let b = args.options["background"], let v = ReflectionParameters.Background(rawValue: b) { settings.reflections.background = v }
    if let r = args.options["resolution"], let v = PIVResolution(rawValue: r) { settings.pivResolution = v }
    if let k = args.options["spacing"].flatMap(Int.init) { settings.piv.pairSpacing = k; settings.piv.autoPairSpacing = false }
    say("method \(settings.method.title), shake \(settings.shake.enabled ? settings.shake.model.rawValue : "off"), deformation \(settings.piv.deformation), GPU \(settings.piv.useGPU), background \(settings.reflections.background.rawValue), resolution \(settings.pivResolution.rawValue)")
    return settings
}

/// 🐱 A recorded video through the same pipeline and recorder, every frame analysed (offline).
/// 🐱   swift run -c release ace-probe file --path clip.mov [--out DIR] [the usb analysis switches]
func fileRun(_ args: Args) async -> Int32 {
    guard let path = args.options["path"] else { say("--path is required"); return 2 }
    let url = URL(fileURLWithPath: path)
    let out = URL(fileURLWithPath: args.string("out", "file-run"))
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let settings = analysisSettings(args)
    let source = VideoFileSource(url: url, pacing: .asFastAsPossible)
    let pipeline = AnalysisPipeline(source: source, settings: settings)
    source.onEvent = { pipeline.handleSourceEvent($0) }
    do {
        pipeline.attach(recorder: try ExperimentRecorder(parent: out, label: url.deletingPathExtension().lastPathComponent, source: source.info,
                                                         settings: settings, streamParameters: nil, cameraInfo: [:], archivePreviewStream: false))
        try await source.startPreview()
    } catch { say("FAILED: \(error)"); return 3 }
    pipeline.start()
    while pipeline.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
    let m = pipeline.metrics
    let result = await pipeline.finishRecording()
    say("frames analysed \(m.framesAnalyzed), analysis time/frame \(String(format: "%.1f", m.analysisDurationMs ?? .nan)) ms median")
    say("session: \(result?.folder.path ?? "-")")
    if let e = result?.evaluation {
        say(String(format: "field: %d/%d valid cells (%.0f %%), mean speed %@ %@", e.field.validCells, e.field.columns * e.field.rows, e.field.coveragePercent,
                   e.field.meanSpeedOfMeanField.map { String(format: "%.3g", $0) } ?? "-", e.field.speedUnit))
        if let cm = e.cameraMotion { say("camera motion: \(cm.text)") }
    }
    return 0
}

func usbLive(_ args: Args) async -> Int32 {
    let seconds = args.double("seconds", 30)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let out = URL(fileURLWithPath: args.string("out", "usb-live-\(stamp)"))
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let devices = ExternalCameraSource.availableDevices()
    say("External cameras: \(devices.map(\.localizedName).joined(separator: ", "))")
    guard let dev = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(args.string("device", "Insta360")) }) ?? devices.first else {
        say("No USB camera found. Put the Ace Pro 2 in Webcam mode (USB menu on the camera).")
        return 2
    }
    let source = ExternalCameraSource(deviceUniqueID: dev.uniqueID,
                                      preferredWidth: args.options["width"].flatMap(Int.init), preferredHeight: args.options["height"].flatMap(Int.init))
    let settings = analysisSettings(args)
    let pipeline = AnalysisPipeline(source: source, settings: settings)
    let latest = LatestResult()
    pipeline.onResult = { latest.set($0) }
    // 🐱 --save-video FILE.mov: every delivered camera frame, ProRes 422 with camera timestamps
    let streamWriter = args.options["save-video"].map { StreamWriter(url: URL(fileURLWithPath: $0)) }
    if let streamWriter { pipeline.onPreviewFrame = { streamWriter.append($0) } }
    // 🐱 --gif-every S [--gif-width W]: the live overlay every S seconds as JPEG (+ the metrics shown, hud.csv)
    let gifEvery = args.options["gif-every"].flatMap(Double.init)
    let gifWidth = Int(args.double("gif-width", 960))
    let gifDir = out.appendingPathComponent("gif")
    var hud = "file,t_s,frame_index,pts_s,camera_fps,analysed_fps,analyse_ms,receive_to_result_ms,vectors,valid_cells,particles\n"
    if gifEvery != nil { try? FileManager.default.createDirectory(at: gifDir, withIntermediateDirectories: true) }
    var gifCount = 0, lastGifIndex = -1
    // 🐱 --blur-faces 1 and/or --blur-rect x,y,w[,h];x,y,w,h (image px): privacy for overlays that will be published
    let blurRects: [CGRect] = (args.options["blur-rect"] ?? "").split(separator: ";").compactMap { part in
        let v = part.split(separator: ",").compactMap { Double($0) }
        return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
    }
    let privacy: PrivacyBlur? = args.options["blur-faces"] == "1" || !blurRects.isEmpty
        ? PrivacyBlur(faces: args.options["blur-faces"] == "1", rects: blurRects) : nil
    source.onEvent = { e in                               // 🐱 stream parameters + log lines into the session
        if case let .log(level, message) = e { say("[\(level.rawValue)] \(message)") }
        pipeline.handleSourceEvent(e)
    }
    do {
        let rec = try ExperimentRecorder(parent: out, label: "usb-live", source: source.info, settings: settings,
                                         streamParameters: nil, cameraInfo: ["device": dev.localizedName, "model": dev.modelID],
                                         archivePreviewStream: false)
        pipeline.attach(recorder: rec)
    } catch { say("cannot create session folder: \(error)") }

    say("Starting \(dev.localizedName)… (macOS may ask for camera permission)")
    do { try await source.startPreview() } catch {
        say("FAILED: \(error)")
        if let e = error as? CameraError { say("hint: \(e.hint)") }
        return 3
    }
    pipeline.start()
    let t0 = HostClock.now()
    var nextReport = t0 + 2
    // 🐱 --restart-at S: exercise the start-up watchdog's stream restart on a running camera
    var restartAt = args.options["restart-at"].flatMap(Double.init)
    var snaps: [Double] = [seconds / 3, 2 * seconds / 3]
    var nextGif = t0
    while HostClock.now() - t0 < seconds {
        try? await Task.sleep(nanoseconds: gifEvery == nil ? 100_000_000 : 10_000_000)
        let now = HostClock.now()
        if let every = gifEvery, now >= nextGif, let r = latest.value, r.frame.index != lastGifIndex {
            nextGif += every
            if nextGif < now { nextGif = now + every }
            lastGifIndex = r.frame.index
            let name = String(format: "frame_%05d.jpg", gifCount)
            saveOverlayJPEG(r, to: gifDir.appendingPathComponent(name), vectorSeconds: args.double("vector-seconds", 0.5), width: gifWidth,
                            privacy: privacy, lineScale: args.double("arrow-scale", 1))
            gifCount += 1
            let m = r.metrics
            hud += String(format: "%@,%.3f,%d,%.6f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d\n", name, now - t0, r.frame.index, r.frame.presentationTime,
                          m.sourceFPS ?? .nan, m.processingFPS ?? .nan, m.analysisDurationMs ?? .nan, m.receiveToResultMs ?? .nan,
                          m.pivVectors, r.field?.cells.filter(\.valid).count ?? 0, r.particles.count)
        }
        if let r = restartAt, now - t0 >= r {
            restartAt = nil
            say("restarting the stream through another format…")
            await source.restartStream()
        }
        if let first = snaps.first, now - t0 >= first, let r = latest.value {
            snaps.removeFirst()
            saveOverlay(r, to: out.appendingPathComponent(String(format: "overlay_%02.0fs.png", now - t0)), vectorSeconds: 0.5)
        }
        if now >= nextReport {
            nextReport += 2
            let m = pipeline.metrics
            say(String(format: "t=%4.0fs  camera %4.1f fps | analysed %4.1f fps | analyse %5.1f ms | receive→result %5.1f ms | particles %4d | vectors %4d | drops %d",
                       now - t0, m.sourceFPS ?? .nan, m.processingFPS ?? .nan, m.analysisDurationMs ?? .nan, m.receiveToResultMs ?? .nan,
                       m.particles, m.samples, m.analysisDrops))
        }
    }
    if let r = latest.value { saveOverlay(r, to: out.appendingPathComponent("overlay_final.png"), vectorSeconds: 0.5) }
    await source.stopPreview()
    if gifEvery != nil { try? hud.write(to: out.appendingPathComponent("hud.csv"), atomically: true, encoding: .utf8) }
    if let streamWriter {
        await streamWriter.finish()
        say("   video:                \(args.options["save-video"]!) (\(streamWriter.written) frames written, \(streamWriter.dropped) dropped)")
    }
    await pipeline.stop()
    let m = pipeline.metrics
    let result = await pipeline.finishRecording()
    let folder = result?.folder
    let size = latest.value.map { "\($0.frame.width)x\($0.frame.height)" } ?? "?"
    say("\n== Result (\(dev.localizedName), \(size))")
    say("   frames analysed:      \(m.framesAnalyzed) in \(Int(seconds)) s")
    say(String(format: "   camera frame rate:    %.2f fps (device timestamps)", m.sourceFPS ?? .nan))
    say(String(format: "   analysis rate:        %.2f fps", m.processingFPS ?? .nan))
    say(String(format: "   analysis time/frame:  %.1f ms median", m.analysisDurationMs ?? .nan))
    say(String(format: "   arrival→result:       %.1f ms median, p95 %.1f ms (excludes camera + USB latency)", m.receiveToResultMs ?? .nan, m.receiveToResultP95Ms ?? .nan))
    say("   analysis drops:       \(m.analysisDrops), missing camera frames: \(m.streamGapFrames)")
    say("   last frame:           \(m.particles) particles, \(m.activeTracks) tracks, \(m.samples) velocity samples")
    say("   session:              \(folder?.path ?? "-")")
    say("   overlays:             \(out.path)/overlay_*.png")
    if let e = result?.evaluation {
        say("\n== Evaluation: \(e.verdict)")
        say(String(format: "   field: %d/%d valid cells (%.0f %%), median uncertainty %@, mean speed %@ %@",
                   e.field.validCells, e.field.columns * e.field.rows, e.field.coveragePercent,
                   e.field.relativeUncertaintyMedian.map { String(format: "%.0f %%", $0 * 100) } ?? "-",
                   e.field.meanSpeedOfMeanField.map { String(format: "%.3g", $0) } ?? "-", e.field.speedUnit))
        if let d = e.diffusion {
            say(String(format: "   Brownian: D = %.3g ± %.2g px²/s, noise %.3f px — %@", d.estimate.d, d.estimate.standardError,
                       d.estimate.localizationNoisePx ?? .nan, d.estimate.significant ? "resolved" : "not resolved"))
        }
        if let cm = e.cameraMotion { say("   camera motion: \(cm.text)") }
        for w in e.warnings { say("   ! \(w)") }
        say("   report: \(folder?.appendingPathComponent("report.html").path ?? "-")")
    }
    return 0
}

let args = Args(CommandLine.arguments)
let code: Int32
switch args.command {
case "probe": code = await probe(args)
case "benchmark": code = await benchmark(args)
case "usb": code = await usbLive(args)
case "file": code = await fileRun(args)
default:
    say("usage: ace-probe [probe|benchmark] [options]  (see Sources/ace-probe/main.swift)")
    code = 64
}
exit(code)
