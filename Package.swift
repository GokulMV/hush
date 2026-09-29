// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Hush", path: "Sources/Hush"),
        .testTarget(name: "HushTests", dependencies: ["Hush"], path: "Tests/HushTests"),
    ]
)
