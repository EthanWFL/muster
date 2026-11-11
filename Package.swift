// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Muster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Muster", targets: ["Muster"]),
        .executable(name: "muster-hook", targets: ["muster-hook"]),
    ],
    targets: [
        // 协议与 JSONValue：hook 和 Core 共用，保持极小、零依赖
        .target(name: "MusterProtocol"),
        // 纯逻辑库，无 UI
        .target(name: "MusterCore", dependencies: ["MusterProtocol"]),
        // SwiftUI app，仅 UI + 装配
        .executableTarget(name: "Muster", dependencies: ["MusterCore", "MusterProtocol"]),
        // hook 客户端：只依赖 Protocol，冷启动要快
        .executableTarget(name: "muster-hook", dependencies: ["MusterProtocol"]),
        .testTarget(name: "MusterProtocolTests", dependencies: ["MusterProtocol"]),
        .testTarget(name: "MusterCoreTests", dependencies: ["MusterCore", "MusterProtocol"]),
        .testTarget(name: "MusterTests", dependencies: ["MusterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
