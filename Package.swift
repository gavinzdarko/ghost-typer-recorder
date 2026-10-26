// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GhostRecorder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GhostRecorder", targets: ["GhostRecorder"]),
        .library(name: "RecorderCore", targets: ["RecorderCore"])
    ],
    targets: [
        .target(name: "RecorderCore"),
        .executableTarget(name: "GhostRecorder", dependencies: ["RecorderCore"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"])
    ]
)
