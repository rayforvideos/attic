// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Attic",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AtticCore"),
        .executableTarget(
            name: "AtticApp",
            dependencies: ["AtticCore"]
        ),
        .testTarget(
            name: "AtticCoreTests",
            dependencies: ["AtticCore"]
        ),
    ]
)
