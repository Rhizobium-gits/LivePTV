// swift-tools-version:5.10
// 🐱 Root manifest so the repository can be added as a Swift package by URL. The sources live in LivePTVKit/
// 🐱 (next to the Xcode app project, which uses LivePTVKit/Package.swift as a local package).
import PackageDescription

let package = Package(
    name: "LivePTV",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LivePTVKit", targets: ["CameraKit", "PTVCore", "Pipeline", "LivePTVUI"]),
        .library(name: "PTVCore", targets: ["PTVCore"]),
        .executable(name: "ace-probe", targets: ["ace-probe"]),
    ],
    targets: [
        .target(name: "CameraKit", path: "LivePTVKit/Sources/CameraKit"),
        .target(name: "PTVCore", path: "LivePTVKit/Sources/PTVCore"),
        .target(name: "Pipeline", dependencies: ["CameraKit", "PTVCore"], path: "LivePTVKit/Sources/Pipeline"),
        .target(name: "LivePTVUI", dependencies: ["CameraKit", "PTVCore", "Pipeline"], path: "LivePTVKit/Sources/LivePTVUI"),
        .executableTarget(name: "ace-probe", dependencies: ["CameraKit", "PTVCore", "Pipeline"], path: "LivePTVKit/Sources/ace-probe"),
    ]
)
