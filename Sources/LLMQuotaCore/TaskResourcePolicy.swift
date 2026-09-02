import Foundation

/// 从任务文本提取必须在目标机器上成立的工具能力，以及同机不能并发占用的资源。
/// 这是确定性安全层，不依赖分诊模型是否成功，也不会每轮额外消耗 token。
public enum TaskResourcePolicy {
    public struct Requirements: Equatable, Sendable {
        public var capabilities: [String]
        public var claims: [String]

        public init(capabilities: [String] = [], claims: [String] = []) {
            self.capabilities = capabilities
            self.claims = claims
        }
    }

    public static func infer(prompt: String) -> Requirements {
        let text = prompt.lowercased()
        var capabilities = Set<String>()
        var claims = Set<String>()

        if containsAny(text, ["unreal", "ue5", "unrealeditor", "虚幻引擎"])
            || containsStandalone(text, token: "ue") {
            capabilities.insert("tool:unreal")
            claims.insert("tool:unreal-editor")
        }
        if containsAny(text, ["blender", "bpy", "搅拌机建模"]) {
            capabilities.insert("tool:blender")
            claims.insert("tool:blender")
        }
        if containsAny(text, ["xcode", "testflight", "ios 构建", "ios发布", "ipa",
                              "模拟器", "真机测试"]) {
            capabilities.insert("tool:xcode")
            claims.insert("tool:xcode")
        }
        if containsAny(text, ["ios simulator", "模拟器"]) {
            claims.insert("device:ios-simulator")
        }
        if containsAny(text, ["testflight", "签名", "provisioning profile", "真机测试"]) {
            claims.insert("device:apple-signing")
        }
        return Requirements(capabilities: capabilities.sorted(), claims: claims.sorted())
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func containsStandalone(_ text: String, token: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        let pattern = "(?:^|[^a-z0-9])\(escaped)(?:$|[^a-z0-9])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// 目标机器只发布经过本机检查的能力；没发布就失败关闭，不能按机器型号猜。
public enum MachineCapabilities {
    public static func detect() -> [String] {
        var result = Set<String>()
        let arch = Proc.run("/usr/bin/uname", ["-m"], cwd: "/", env: [:], timeout: 3)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !arch.isEmpty { result.insert("arch:" + arch) }

        if Proc.run("/usr/bin/xcodebuild", ["-version"], cwd: "/", env: [:], timeout: 5)
            .exitCode == 0 {
            result.insert("tool:xcode")
        }
        let fm = FileManager.default
        let blenderCandidates = [
            "/Applications/Blender.app/Contents/MacOS/Blender",
            "/opt/homebrew/bin/blender", "/usr/local/bin/blender",
        ]
        if blenderCandidates.contains(where: { fm.isExecutableFile(atPath: $0) }) {
            result.insert("tool:blender")
        }
        let epic = URL(fileURLWithPath: "/Users/Shared/Epic Games", isDirectory: true)
        let installs = (try? fm.contentsOfDirectory(
            at: epic, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        if installs.contains(where: {
            fm.isExecutableFile(atPath: $0.appendingPathComponent(
                "Engine/Binaries/Mac/UnrealEditor").path)
        }) {
            result.insert("tool:unreal")
        }
        return result.sorted()
    }
}
