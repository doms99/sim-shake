// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimShake",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SimShake", path: "Sources/SimShake"),
        .testTarget(name: "SimShakeTests", dependencies: ["SimShake"]),
    ]
)
