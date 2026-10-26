// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "askenv",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "askenv")
    ]
)
