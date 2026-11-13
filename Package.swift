// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muster",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Muster", targets: ["Muster"]),
    ],
    targets: [
        .target(name: "MusterCore"),
        .executableTarget(
            name: "Muster",
            dependencies: ["MusterCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MusterCoreTests", dependencies: ["MusterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
