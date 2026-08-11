// swift-tools-version: 6.0
//
// **别往上抬。** 这个版本号取的是集群里**最旧那台机器**的工具链下限，
// 不是开发机的。抬到 6.1 之后开发机照样能编，而另一台 Swift 6.0.3 的机器
// 上所有验证直接失败（package is using Swift tools version 6.1.0 but the
// installed version is 6.0.3），跨机派活的产出全部卡在验证闸门上。
// 要抬之前先确认每台机器的 `swift --version`。
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
