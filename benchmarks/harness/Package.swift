// swift-tools-version:5.10
// Thin command-line wrapper that runs LivePTV's analysis core (PTVCore) on synthetic frames, so its output can be
// compared with OpenPIV / trackpy on identical images. Depends on ../../LivePTVKit by path.
import PackageDescription

let package = Package(
    name: "liveptv-harness",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../LivePTVKit")],
    targets: [
        .executableTarget(name: "liveptv-harness",
                          dependencies: [.product(name: "LivePTVKit", package: "LivePTVKit")]),
    ]
)
