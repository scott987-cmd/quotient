import Foundation

/// 计划清单：你**打算**让 agent 做、但还没放进执行队列的任务。
///
/// # 和执行队列、储备池的分工
///
/// - **执行队列**（tasks.jsonl 里的 queued）：worker 看见就会拿走跑，
///   进去 = 马上开始烧额度。
/// - **储备池**（`llmq work reserve`）：机器自己扫出来的维护活，
///   额度快作废时垫底用的。
/// - **计划清单（这个）**：人排的。有明确的先后顺序，放着不动就永远不跑 ——
///   什么时候放行、放行哪个，都是人的决定。
///
/// 没有它之前，「我想好了但还不想跑」的任务只能记在脑子里或者聊天记录里，
/// 而这两个地方的东西都会丢。
///
/// # 为什么单独一个文件、不进 tasks.jsonl
///
/// tasks.jsonl 的每一行都会被调度、看板、对账、手机端读到 ——
/// 给 `State` 加一个 `planned` 值，老版本二进制解不出那些行，
/// 会把它们当损坏记录报出来（skippedLines）。单独存，零兼容风险。
public struct PlannedTask: Codable, Sendable, Identifiable {
    public var id: String
    public var prompt: String
    /// 仓库**别名**，不是路径 —— 别名在每台机器上解析成各自的本地路径。
    public var repoAlias: String?
    public var createdAt: Date
    public var note: String?

    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(),
                prompt: String, repoAlias: String? = nil,
                createdAt: Date = Date(), note: String? = nil) {
        self.id = id
        self.prompt = prompt
        self.repoAlias = repoAlias
        self.createdAt = createdAt
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? String(UUID().uuidString.prefix(8)).lowercased()
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        repoAlias = try c.decodeIfPresent(String.self, forKey: .repoAlias)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

public enum PlannedStore {
    /// 测试用。
    public static var fileOverride: URL?

    /// 本机文件。计划是「这台机器上排的」——
    /// 跨机派活有自己的通道（cluster dispatch），计划不跟着 iCloud 跑。
    static var file: URL {
        fileOverride ?? Paths.appSupport.appendingPathComponent("planned.json")
    }

    /// 数组顺序就是执行顺序。
    public static func all() -> [PlannedTask] {
        guard let data = try? Data(contentsOf: file),
              let list = try? SnapshotCoding.decoder().decode([PlannedTask].self, from: data)
        else { return [] }
        return list.filter { !$0.prompt.isEmpty }
    }

    public static func save(_ list: [PlannedTask]) throws {
        try Paths.ensureDirectories()
        let data = try SnapshotCoding.prettyEncoder().encode(list)
        // 守卫测试抓过这里的裸原子写 —— 规矩是一律走收口函数，
        // 「判断这个文件碰不碰 iCloud」这件事交给它（本地路径零开销直通）。
        guard ICloudSafe.write(data, to: file) else {
            throw NSError(domain: "PlannedStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "计划清单写不进去"])
        }
    }

    @discardableResult
    public static func add(prompt: String, repoAlias: String?,
                           first: Bool = false) throws -> PlannedTask {
        let t = PlannedTask(prompt: prompt, repoAlias: repoAlias)
        var list = all()
        if first { list.insert(t, at: 0) } else { list.append(t) }
        try save(list)
        return t
    }

    /// 按序号（1 起）删。返回删掉的那条；序号不对返回 nil 且什么都不动。
    @discardableResult
    public static func remove(at position: Int) throws -> PlannedTask? {
        var list = all()
        guard position >= 1, position <= list.count else { return nil }
        let t = list.remove(at: position - 1)
        try save(list)
        return t
    }

    /// 上移/下移一位。越界就原地不动 —— 第 1 条再上移不是错误，是没事可做。
    public static func move(position: Int, up: Bool) throws {
        var list = all()
        let i = position - 1
        guard i >= 0, i < list.count else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < list.count else { return }
        list.swapAt(i, j)
        try save(list)
    }
}
