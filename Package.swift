// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UniqueAV",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UniqueAV", targets: ["UniqueAV"]),
    ],
    targets: [
        // Pure logic: protocols, parsers, frequency coordination, licence files. No UI, unit-tested.
        .target(name: "UniqueAVCore", path: "Sources/UniqueAVCore"),
        // The native macOS SwiftUI app "Unique AV RF Scan Co-ord".
        .executableTarget(name: "UniqueAV", dependencies: ["UniqueAVCore"], path: "Sources/UniqueAV"),
        .testTarget(name: "UniqueAVCoreTests", dependencies: ["UniqueAVCore"], path: "Tests/UniqueAVCoreTests"),
    ]
)
