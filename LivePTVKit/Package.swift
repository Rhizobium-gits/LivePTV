// swift-tools-version:5.10
// 🐱 LivePTV: real-time particle tracking velocimetry on iPad, fed directly by a camera over Wi-Fi.
// 🐱 Every library target builds for iPadOS 17 and macOS 14, so the protocol, decoder and analysis code
// 🐱 can be unit-tested (and run against real hardware through `ace-probe`) on a Mac without Xcode.
import PackageDescription

let package = Package(
    name: "LivePTVKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LivePTVKit", targets: ["CameraKit", "PTVCore", "Pipeline", "LivePTVUI"]),
        .executable(name: "ace-probe", targets: ["ace-probe"]),
    ],
    targets: [
        // 🐱 Camera transports, protocol clients and hardware video decoding. No analysis code here.
        .target(name: "CameraKit"),
        // 🐱 Pure particle detection / tracking / velocity-field algorithms. No Apple media frameworks.
        .target(name: "PTVCore"),
        // 🐱 Glue: frame buffer → ROI → detection → tracking → field → recording, plus metrics.
        .target(name: "Pipeline", dependencies: ["CameraKit", "PTVCore"]),
        // 🐱 SwiftUI screens. The Xcode app target only contains the @main entry point.
        .target(name: "LivePTVUI", dependencies: ["CameraKit", "PTVCore", "Pipeline"]),
        // 🐱 macOS command-line probe that runs the exact same Insta360 client against a real camera.
        .executableTarget(name: "ace-probe", dependencies: ["CameraKit", "PTVCore", "Pipeline"]),

        .testTarget(name: "CameraKitTests", dependencies: ["CameraKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PTVCoreTests", dependencies: ["PTVCore"]),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline", "CameraKit", "PTVCore"],
                    resources: [.copy("Fixtures/testsrc_160x120_30f.h264")]),
        .testTarget(name: "LivePTVUITests", dependencies: ["LivePTVUI"]),
    ]
)
