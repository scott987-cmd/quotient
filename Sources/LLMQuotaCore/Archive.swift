import Foundation

/// 把干完的活归档到外部存储（NAS），本地只留还用得着的。
///
/// ## 什么值得备份，什么该直接删
///
/// 实测本地占用：worktrees 974M、日志 3.5M、任务记录 2.1M。
/// 但那 974M 里 **97% 是 `.build` 编译产物**（单个 worktree 228M，
/// 源码只占 1.6M）—— 而源码本来就在 git 分支里躺着。
/// 把它们备份到 NAS 是在备份垃圾：占满网盘、拖慢备份、恢复时还得重编。
///
/// 所以分两类处理：
/// - **归档**（有复盘价值、本地不必留）：agent 执行日志、老的任务记录
/// - **直接删**（可从 git 重建）：终态任务的 worktree
///
/// ## 为什么任务记录不能一删了之
///
/// `tasks.jsonl` 是查重（DuplicateGuard）和「这活是不是刚做过」的唯一依据。
/// 全删掉的后果不是省空间，是**系统开始重复干已经干过的活** —— 而这个项目
/// 存在的全部理由就是「一分额度不浪费」。所以是**轮转**不是删除：
/// 老条目搬去归档，本地保留最近 N 天，两边都完整。
public enum Archive {

    public struct Report: Sendable {
        public var archivedLogs = 0
        public var archivedTaskLines = 0
        public var removedWorktrees = 0
        public var freedBytes: Int64 = 0
        public var notes: [String] = []
    }

    /// 终态：这些任务不会再动了，它们的 worktree 是纯垃圾。
    /// blocked 不算 —— 它可能被回答之后接着跑，工作区里有半成品。
    static func isTerminal(_ s: WorkTask.State) -> Bool {
        s == .done || s == .failed
    }

    /// - Parameters:
    ///   - target: 归档根目录（NAS 挂载点下的某个目录）。nil 表示只清理不归档。
    ///   - keepDays: 任务记录本地保留天数。默认 14 —— 查重看的是「最近做过
    ///     没有」，两周足够；再长只是让每次读盘更慢。
    ///   - dryRun: 只报告不动手。
    public static func run(target: URL?, keepDays: Int = 14,
                           dryRun: Bool = false,
                           now: Date = Date()) throws -> Report {
        var r = Report()
        let fm = FileManager.default

        if let target {
            guard fm.fileExists(atPath: target.path) else {
                throw NSError(domain: "Archive", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "归档目录不存在：\(target.path)\n"
                        + "NAS 没挂载的话先在访达里连一次（⌘K → smb://…），"
                        + "挂载点通常在 /Volumes/ 下"])
            }
            // 网络卷写不进去要立刻发现，别等归档完才报错。
            let probe = target.appendingPathComponent(".llmq-write-probe")
            guard (try? Data("ok".utf8).write(to: probe)) != nil else {
                throw NSError(domain: "Archive", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "归档目录不可写：\(target.path)"])
            }
            try? fm.removeItem(at: probe)
        }

        // ── 1. agent 执行日志：整体搬走 ────────────────────────────
        let logsDir = Paths.appSupport.appendingPathComponent("logs")
        if let target, let logs = try? fm.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) {
            let stamp = Format.fileStamp(now)
            let dest = target.appendingPathComponent("logs/\(stamp)", isDirectory: true)
            if !dryRun { try? fm.createDirectory(at: dest, withIntermediateDirectories: true) }
            var failed = 0
            var firstError = ""
            for f in logs where f.pathExtension == "log" {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if !dryRun {
                    let to = dest.appendingPathComponent(f.lastPathComponent)
                    try? fm.removeItem(at: to)
                    // **不能用 moveItem 往 SMB 上搬。**
                    //
                    // macOS 的扩展属性（com.apple.provenance 等）在 SMB 上写不了，
                    // Foundation 的 moveItem/copyItem 会因此整体失败 ——
                    // 而 `mv` 命令只是打个警告照样搬完，两者严格程度不同。
                    // 所以：读字节 → 写过去 → 删本地，绕开属性复制。
                    // 校验写成功再删本地，别把「搬走了」和「弄丢了」混为一谈。
                    do {
                        let data = try Data(contentsOf: f)
                        try data.write(to: to)
                        let written = (try? to.resourceValues(
                            forKeys: [.fileSizeKey]).fileSize) ?? 0
                        guard written == data.count else {
                            failed += 1
                            if firstError.isEmpty { firstError = "写入不完整：\(f.lastPathComponent)" }
                            continue
                        }
                        try fm.removeItem(at: f)
                    } catch {
                        failed += 1
                        if firstError.isEmpty {
                            firstError = f.lastPathComponent + " → " + error.localizedDescription
                        }
                        continue
                    }
                }
                r.archivedLogs += 1
                r.freedBytes += Int64(size)
            }
            // 失败要说出来。静默跳过会让「归档 0 个」看起来像「本来就没有」。
            if failed > 0 {
                r.notes.append("有 \(failed) 个日志没搬成：" + firstError)
            }
        }

        // ── 2. 任务记录轮转：老的搬走，近的留下 ─────────────────────
        let tasksFile = Paths.appSupport.appendingPathComponent("tasks.jsonl")
        if let raw = try? String(contentsOf: tasksFile, encoding: .utf8) {
            let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
            var keep: [String] = []
            var old: [String] = []
            let dec = SnapshotCoding.decoder()
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                let s = String(line)
                guard let d = s.data(using: .utf8),
                      let t = try? dec.decode(WorkTask.self, from: d) else {
                    keep.append(s)   // 解不出来的坏行原样留着，别在归档时丢证据
                    continue
                }
                // 判据用「最后一次动过的时间」，不是创建时间 ——
                // 一个上周创建、昨天才跑完的任务，昨天才算数。
                let touched = t.endedAt ?? t.startedAt ?? t.createdAt
                if touched < cutoff, isTerminal(t.state) { old.append(s) } else { keep.append(s) }
            }
            if !old.isEmpty {
                if let target {
                    let dest = target.appendingPathComponent(
                        "tasks/tasks-\(Format.fileStamp(now)).jsonl")
                    if !dryRun {
                        try? fm.createDirectory(
                            at: dest.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        try? (old.joined(separator: "\n") + "\n")
                            .write(to: dest, atomically: true, encoding: .utf8)
                    }
                }
                if !dryRun {
                    try (keep.joined(separator: "\n") + "\n")
                        .write(to: tasksFile, atomically: true, encoding: .utf8)
                }
                r.archivedTaskLines = old.count
                r.notes.append("任务记录：归档 \(old.count) 条、本地留 \(keep.count) 条"
                               + "（保留最近 \(keepDays) 天，查重要用）")
            }
        }

        // ── 3. 终态任务的 worktree：直接删，不备份 ──────────────────
        let wtRoot = Paths.appSupport.appendingPathComponent("worktrees")
        let byID = Dictionary(TaskStore.all().map { ($0.id, $0) },
                              uniquingKeysWith: { _, b in b })
        if let dirs = try? fm.contentsOfDirectory(
            at: wtRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for d in dirs {
                let id = d.lastPathComponent
                // 图的 worktree 用图 id 命名，任务是 <图id>sN —— 前缀匹配。
                let related = byID.values.filter { $0.id == id || $0.graphID == id }
                guard !related.isEmpty else { continue }          // 认不出来的不碰
                guard related.allSatisfy({ isTerminal($0.state) }) else { continue }

                // **未提交的改动一律不删。**
                //
                // 验收失败的任务会**故意保留工作区**（「改动可能完全正确，
                // 只是需要你看一眼」）—— 那是留给人的证据，不是垃圾。
                // 判据是 git 说了算，不是任务状态说了算：状态是 failed
                // 但工作区里躺着二十分钟的产出，这时候删掉就是毁证据。
                let dirty = GitWorkspace.git(["status", "--porcelain"], in: d.path)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !dirty.isEmpty {
                    r.notes.append("留着 \(id)：工作区有 "
                        + "\(dirty.split(separator: "\n").count) 个未提交改动，"
                        + "看过再说（llmq work review 或直接进目录看）")
                    continue
                }
                let size = dirSize(d)
                if !dryRun {
                    // 先让 git 收回登记，再删目录 —— 反过来会留下悬空的
                    // worktree 记录，下次同名任务复用时 git 会拒绝。
                    if let repo = related.first?.repo {
                        _ = GitWorkspace.git(["worktree", "remove", "--force", d.path], in: repo)
                        _ = GitWorkspace.git(["worktree", "prune"], in: repo)
                    }
                    try? fm.removeItem(at: d)
                }
                r.removedWorktrees += 1
                r.freedBytes += size
            }
        }
        if r.removedWorktrees > 0 {
            r.notes.append("worktree 直接删不备份：里面 97% 是 .build 编译产物，"
                           + "源码在 git 分支里")
        }
        return r
    }

    static func dirSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
