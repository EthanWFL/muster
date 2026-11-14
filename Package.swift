// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muster",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Muster", targets: ["Muster"]),
    ],
    dependencies: [
        .package(path: "Vendor/Yams"),
    ],
    targets: [
        .target(name: "MusterCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .executableTarget(
            name: "Muster",
            dependencies: ["MusterCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MusterCoreTests", dependencies: ["MusterCore"]),
        .testTarget(name: "MusterTests", dependencies: ["Muster", "MusterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
