// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WaveDesk",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WaveDesk", targets: ["WaveDesk"]),
    ],
    targets: [
        // Pure logic: protocols, parsers, frequency coordination. No UI, unit-tested.
        .target(name: "WaveDeskCore", path: "Sources/WaveDeskCore"),
        // The native macOS SwiftUI app.
        .executableTarget(name: "WaveDesk", dependencies: ["WaveDeskCore"], path: "Sources/WaveDesk"),
        .testTarget(name: "WaveDeskCoreTests", dependencies: ["WaveDeskCore"], path: "Tests/WaveDeskCoreTests"),
    ]
)
