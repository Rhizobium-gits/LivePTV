// Runs LivePTV's PIVEngine / ParticleDetector / ParticleTracker on frames stored as
//   int32 width, int32 height, int32 count, then count × width × height uint8 (row-major).
//
//   liveptv-harness piv    <frames.u8> <out.csv> [--windows 64,32] [--overlap 0.5] [--iters 2]
//                          [--interp lanczos4|bilinear] [--gpu 1|0] [--uncertainty 1|0] [--timing <out.txt>]
//       pairs (0,1), (2,3), ...  → CSV: pair,x,y,dx,dy,status,corr,sigx,sigy
//   liveptv-harness detect <frames.u8> <out.csv> [--bg 0|1]
//       → CSV: frame,x,y,peak,mass,area
//   liveptv-harness ptv    <frames.u8> <out.csv> [--maxdisp 12] [--predrad 4] [--bg 1]
//       → CSV: frame,track,x,y,dx,dy,outlier ; detections in <out.csv>.det.csv
import Foundation
import PTVCore

func readFrames(_ path: String) -> [LumaImage] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: path))
    func i32(_ o: Int) -> Int { Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.load(as: Int32.self) }) }
    let w = i32(0), h = i32(4), n = i32(8)
    var out: [LumaImage] = []
    let bytes = [UInt8](d)
    for k in 0..<n {
        let o = 12 + k * w * h
        out.append(LumaImage(width: w, height: h, pixels: bytes[o..<o + w * h].map { Float($0) }))
    }
    return out
}

var args = Array(CommandLine.arguments.dropFirst())
let mode = args.removeFirst(), input = args.removeFirst(), output = args.removeFirst()
var opt: [String: String] = [:]
while args.count >= 2 { opt[String(args.removeFirst().dropFirst(2))] = args.removeFirst() }
let frames = mode == "track" ? [] : readFrames(input)
var text = ""

switch mode {
case "piv":
    var p = PIVParameters()
    if let s = opt["windows"] { p.windowSizes = s.split(separator: ",").map { Int($0)! } }
    if let s = opt["overlap"] { p.overlap = Double(s)! }
    if let s = opt["iters"] { p.finalIterations = Int(s)! }
    if let s = opt["interp"] { p.windowInterpolation = PIVParameters.WindowInterpolation(rawValue: s)! }
    if let s = opt["gpu"] { p.useGPU = s == "1" }
    if let s = opt["uncertainty"] { p.uncertainty = s == "1" }
    if let s = opt["vthr"] { p.validationThreshold = Double(s)! }
    if let s = opt["deform"] { p.deformation = s == "1" }
    if let s = opt["smooth"] { p.predictorSmoothing = s == "1" }
    let engine = PIVEngine(parameters: p)
    text = "pair,x,y,dx,dy,status,corr,sigx,sigy\n"
    var times: [Double] = []
    var pair = 0
    while 2 * pair + 1 < frames.count {
        let a = frames[2 * pair], b = frames[2 * pair + 1]
        let clock = ContinuousClock()
        var field: PIVField?
        let t = clock.measure { field = engine.compute(a: a, b: b, dt: 1) }
        times.append(Double(t.components.attoseconds) / 1e15 + Double(t.components.seconds) * 1e3)
        guard let f = field else { pair += 1; continue }
        for k in 0..<f.count {
            let sx = f.sigmaX.isEmpty ? Float.nan : f.sigmaX[k], sy = f.sigmaY.isEmpty ? Float.nan : f.sigmaY[k]
            text += "\(pair),\(f.x(k)),\(f.y(k)),\(f.dx[k]),\(f.dy[k]),\(f.status[k].rawValue),\(f.correlation[k]),\(sx),\(sy)\n"
        }
        pair += 1
    }
    if let tp = opt["timing"] {
        try! (times.map { String($0) }.joined(separator: "\n") + "\ndevice,\(engine.lastDevice)\n").write(toFile: tp, atomically: true, encoding: .utf8)
    }
case "detect":
    var dp = DetectorParameters()
    dp.backgroundSubtraction = (opt["bg"] ?? "0") == "1"
    if let s = opt["k"] { dp.thresholdK = Float(s)! }
    if let s = opt["minthr"] { dp.minimumThreshold = Float(s)! }
    text = "frame,x,y,peak,mass,area\n"
    for (k, img) in frames.enumerated() {
        let det = ParticleDetector(parameters: dp)
        for q in det.detect(img) { text += "\(k),\(q.x),\(q.y),\(q.peak),\(q.mass),\(q.area)\n" }
    }
case "ptv":
    var dp = DetectorParameters()
    dp.backgroundSubtraction = (opt["bg"] ?? "1") == "1"
    var tp = TrackerParameters()
    if let s = opt["maxdisp"] { tp.maxDisplacement = Double(s)! }
    if let s = opt["predrad"] { tp.predictionRadius = Double(s)! }
    let det = ParticleDetector(parameters: dp), tracker = ParticleTracker(parameters: tp)
    text = "frame,track,x,y,dx,dy,outlier\n"
    var dtext = "frame,track,x,y\n"
    for (k, img) in frames.enumerated() {
        let ps = det.detect(img)
        let step = tracker.update(particles: ps, time: Double(k), frameIndex: k)
        for (i, q) in ps.enumerated() { dtext += "\(k),\(step.trackIDs[i]),\(q.x),\(q.y)\n" }
        for s in step.samples { text += "\(k),\(s.trackID),\(s.x),\(s.y),\(s.dx),\(s.dy),\(s.outlier ? 1 : 0)\n" }
    }
    try! dtext.write(toFile: output + ".det.csv", atomically: true, encoding: .utf8)
case "timeptv":
    // detector + tracker time per frame (ms, median over frames 2...), defaults; prints "median_ms,particles_per_frame"
    let det = ParticleDetector(parameters: DetectorParameters()), tracker = ParticleTracker(parameters: TrackerParameters())
    var times: [Double] = [], counts: [Int] = []
    let clock = ContinuousClock()
    for (k, img) in frames.enumerated() {
        var n = 0
        let t = clock.measure {
            let ps = det.detect(img)
            n = ps.count
            _ = tracker.update(particles: ps, time: Double(k) / 30, frameIndex: k)
        }
        if k >= 2 { times.append(Double(t.components.attoseconds) / 1e15 + Double(t.components.seconds) * 1e3); counts.append(n) }
    }
    times.sort()
    text = "median_ms,particles_per_frame\n\(times[times.count / 2]),\(counts.reduce(0, +) / max(1, counts.count))\n"
case "track":
    // tracking only: positions from a CSV (frame,x,y), to separate tracking from detection
    var tp = TrackerParameters()
    if let s = opt["maxdisp"] { tp.maxDisplacement = Double(s)! }
    if let s = opt["predrad"] { tp.predictionRadius = Double(s)! }
    let tracker = ParticleTracker(parameters: tp)
    let rows = try! String(contentsOfFile: input, encoding: .utf8).split(separator: "\n").dropFirst()
    var byFrame: [Int: [(Double, Double)]] = [:]
    for r in rows { let c = r.split(separator: ","); byFrame[Int(c[0])!, default: []].append((Double(c[1])!, Double(c[2])!)) }
    text = "frame,index,track\n"
    for k in (byFrame.keys.min() ?? 0)...(byFrame.keys.max() ?? -1) {
        let pts = byFrame[k] ?? []
        let ps = pts.map { Particle(x: $0.0, y: $0.1, peak: 100, mass: 100, area: 5) }
        let step = tracker.update(particles: ps, time: Double(k), frameIndex: k)
        for i in ps.indices { text += "\(k),\(i),\(step.trackIDs[i])\n" }
    }
default:
    fatalError("unknown mode \(mode)")
}
try! text.write(toFile: output, atomically: true, encoding: .utf8)
