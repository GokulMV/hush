// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OverAndOut",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OverAndOut", path: "Sources/OverAndOut"),
        .testTarget(name: "OverAndOutTests", dependencies: ["OverAndOut"], path: "Tests/OverAndOutTests"),
    ]
)
