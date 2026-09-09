// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Overnight",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "OvernightCore"),
        .executableTarget(
            name: "Overnight",
            dependencies: ["OvernightCore"]
        ),
        .testTarget(
            name: "OvernightCoreTests",
            dependencies: ["OvernightCore"]
        ),
    ]
)
