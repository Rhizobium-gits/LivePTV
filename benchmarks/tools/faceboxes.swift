// Face boxes (Apple Vision) for blurring faces in published figures: faceboxes IMAGE... → one line per image,
// "path,x,y,w,h;x,y,w,h" in image pixels, origin top-left. Build: swiftc -O faceboxes.swift -o faceboxes
import AppKit
import Vision

for path in CommandLine.arguments.dropFirst() {
    guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("\(path),"); continue
    }
    let w = Double(cg.width), h = Double(cg.height)
    let request = VNDetectFaceRectanglesRequest()
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    let boxes = (request.results ?? []).map { o -> String in
        let b = o.boundingBox
        return String(format: "%.0f,%.0f,%.0f,%.0f", b.minX * w, (1 - b.maxY) * h, b.width * w, b.height * h)
    }
    print("\(path),\(boxes.joined(separator: ";"))")
}
