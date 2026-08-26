import Foundation

/// Context Pack manifest 的追加式台账（设计 9.1）。
///
/// 只存 ID 和计数，不存重复正文。它回答「这次派发到底注入了多少、
/// 带了哪些事实、为什么删了那些」，是后续统计 Pack 开销 P95、
/// Full RepoMap 使用率和建立基线的数据来源。
///
/// 台账坏了不能影响派发 —— 写不进去就静默放弃计数，
/// 诊断价值不能建立在拖垮主流程的代价上。
public enum ContextTelemetry {
    /// 测试注入口。
    public static var fileOverride: URL?

    public static var file: URL {
        fileOverride ?? Paths.appSupport.appendingPathComponent("context-packs.jsonl")
    }

    private static let lock = NSLock()

    public static func record(_ manifest: ContextPackManifest) {
        guard let data = try? SnapshotCoding.encoder().encode(manifest) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        lock.lock(); defer { lock.unlock() }
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        var offset = 0
        while offset < line.count {
            let count = line.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return write(fd, base.advanced(by: offset), line.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            offset += count
        }
        flock(fd, LOCK_UN)
    }

    public static func all() -> [ContextPackManifest] {
        guard let data = ICloudSafe.read(file) else { return [] }
        let decoder = SnapshotCoding.decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(ContextPackManifest.self, from: Data($0))
        }
    }

    public static func recent(limit: Int = 50) -> [ContextPackManifest] {
        Array(all().suffix(max(1, limit)))
    }
}
