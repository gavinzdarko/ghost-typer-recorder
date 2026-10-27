// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GhostRecorder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GhostRecorder", targets: ["GhostRecorder"]),
        .executable(name: "RecorderStorageProbe", targets: ["RecorderStorageProbe"]),
        .library(name: "RecorderCore", targets: ["RecorderCore"])
    ],
    targets: [
        .target(name: "RecorderCore"),
        .executableTarget(name: "RecorderStorageProbe", dependencies: ["RecorderCore"]),
        .executableTarget(name: "GhostRecorder", dependencies: ["RecorderCore"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"])
    ]
)
