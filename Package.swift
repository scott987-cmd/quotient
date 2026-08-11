// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LLMQuotaCore", targets: ["LLMQuotaCore"]),
        .executable(name: "llmq", targets: ["llmq"]),
        .executable(name: "LLMQuotaBarApp", targets: ["LLMQuotaBarApp"]),
    ],
    targets: [
        .target(
            name: "LLMQuotaCore",
            // three.js 和 3D 场景代码放资源里而不是塞进 Swift 字符串：
            // 518KB 的库直接内联进源码会让文件没法看、也没法单独更新。
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "llmq",
            dependencies: ["LLMQuotaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LLMQuotaBarApp",
            dependencies: ["LLMQuotaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LLMQuotaCoreTests",
            dependencies: ["LLMQuotaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
